import SwiftUI
import AppKit
import UniformTypeIdentifiers
@preconcurrency import RenameCore

final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
struct Row: Identifiable {
    var id = UUID()
    var entry: Entry
    var original: String
    var proposed: String
    var done = false
    var error: String?
    var preview: NamePreview?
    var status: String { error ?? (done ? "Completed" : (preview?.skipped == true ? "Already ends with this text" : (original == proposed ? "Unchanged" : "Pending"))) }
}
@MainActor final class Model: ObservableObject {
    @Published var rows: [Row] = []
    @Published var selection = Set<UUID>()
    private var excluded = Set<String>()
    @Published var operation = RenameOperation() { didSet { preview() } }
    @Published var files = true { didSet { rebuild() } }
    @Published var folders = false { didSet { rebuild() } }
    @Published var recursive = false { didSet { rebuild() } }
    @Published var busy = false
    @Published private(set) var installing = false
    var controlsLocked: Bool { busy || installing }
    func beginInstallation() -> Bool {
        guard startupHealthy, !controlsLocked else { return false }
        installing = true
        return true
    }
    func endInstallation() { installing = false; drainPending() }
    @Published var message = "Drop files or folders here to begin."
    @Published var undoAvailable = false
    private var inventory = Inventory()
    private var frozen = Set<String>()
    var startupHealthy: Bool { engine != nil }
    private var engine: Engine?
    private var engineFailure: String?
    private var plan: [PlanItem] = []
    private let cancellation = Cancellation()
    func cancel() { cancellation.set(true) }
    private let worker = DispatchQueue(label: "BatchRename.filesystem")
    init(journalURL: URL? = nil) {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Batch Rename")
            engine = try Engine(journalURL: journalURL ?? AppUpdater.fixtureJournal ?? root.appendingPathComponent("undo.json"))
            undoAvailable = engine!.canUndo
            refreshFrozen()
        } catch { engineFailure = "Rename unavailable: " + error.localizedDescription; message = engineFailure! }
    }
    var pendingCount: Int { plan.count }
    private var pendingURLs: [URL] = []
    private var rebuildPending = false
    func add(_ urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        rebuild()
    }
    private func drainPending() {
        if rebuildPending || !pendingURLs.isEmpty { rebuild() }
    }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func removeSelected() {
        guard !controlsLocked else { return }
        excluded.formUnion(rows.filter { selection.contains($0.id) }.map { $0.entry.path })
        rows.removeAll { selection.contains($0.id) }
        selection = []
        preview()
    }
    func clear() { guard !controlsLocked else { return }; rows = []; selection = []; excluded = []; inventory.roots = []; plan = []; message = engineFailure ?? "List cleared. Description and undo history preserved." }
    private func key(_ e: Entry) -> String { "\(e.path)|\(e.identity.device)|\(e.identity.inode)|\(e.identity.birth)|\(e.identity.nanos)" }
    private func refreshFrozen() {
        frozen = []
        for (path, id) in engine?.completedPaths ?? [:] {
            // Content edits must not make a previously completed directory entry pending.
            // Move and undo validation still use the complete recorded identity.
            if let entry = try? Entry(path),
               entry.identity.device == id.device, entry.identity.inode == id.inode,
               entry.identity.birth == id.birth, entry.identity.nanos == id.nanos,
               entry.identity.kind == id.kind { frozen.insert(key(entry)) }
        }
    }
    func rebuild() {
        guard !controlsLocked else { rebuildPending = true; return }
        rebuildPending = false
        // Only an explicit drop restores exclusions (including descendants of a dropped folder).
        for url in pendingURLs {
            let path = url.standardizedFileURL.path
            excluded = excluded.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
        inventory.append(pendingURLs.map(\.path))
        pendingURLs = []
        inventory.files = files; inventory.folders = folders; inventory.recursive = recursive
        busy = true
        let inventory = inventory
        worker.async {
            let result = Result { try inventory.scan() }
            DispatchQueue.main.async {
                self.busy = false
                if self.rebuildPending || !self.pendingURLs.isEmpty {
                    self.rebuild()
                    return
                }
                switch result {
                case .success(let entries):
                    self.refreshFrozen()
                    let completed = self.rows.filter { $0.done && self.frozen.contains(self.key($0.entry)) }
                    let visible = Set(completed.map { self.key($0.entry) })
                    let previous = Dictionary(uniqueKeysWithValues: self.rows.map { (self.key($0.entry), $0.id) })
                    self.rows = completed + entries.filter { !visible.contains(self.key($0)) && !self.excluded.contains($0.path) }.map {
                        Row(id: previous[self.key($0)] ?? UUID(), entry: $0, original: $0.name, proposed: $0.name, done: self.frozen.contains(self.key($0)))
                    }
                    self.selection.formIntersection(Set(self.rows.map(\.id)))
                    self.preview()
                case .failure(let error): self.plan = []; self.message = error.localizedDescription
                }
            }
        }
    }
    func preview() {
        guard !controlsLocked else { return }
        guard engine != nil else {
            plan = []; message = engineFailure ?? "Rename unavailable: undo engine is not initialized."
            return
        }
        // Publish once per edit instead of once for every changed row field.
        var updatedRows = rows
        for i in updatedRows.indices where !updatedRows[i].done {
            do {
                let preview = try operation.preview(updatedRows[i].original, folder: updatedRows[i].entry.identity.folder)
                updatedRows[i].preview = preview; updatedRows[i].proposed = preview.name; updatedRows[i].error = nil
            }
            catch { updatedRows[i].preview = nil; updatedRows[i].proposed = updatedRows[i].original; updatedRows[i].error = error.localizedDescription }
        }
        rows = updatedRows
        do { plan = try Planner.plan(rows.filter { !$0.done }.map(\.entry), operation: operation); message = "\(plan.count) changes ready • No files are overwritten." }
        catch { plan = []; message = error.localizedDescription }
    }
    func apply() {
        guard !controlsLocked, let engine, !plan.isEmpty else { return }
        busy = true
        cancellation.set(false)
        let token = cancellation
        let plan = plan, start = engine.steps.count
        worker.async {
            let result = Result { try engine.apply(plan, cancelled: { token.requested }) }
            let steps = Array(engine.steps.dropFirst(start)).filter { $0.done && !$0.undone }
            let completed = plan.filter { item in steps.contains { $0.destination == item.destination } }
            let completedFolders = completed.filter { $0.entry.identity.folder }.count
            let completion = RenamePresentation.completion(files: completed.count - completedFolders, folders: completedFolders)
            DispatchQueue.main.async {
                for i in self.rows.indices {
                    var path = self.rows[i].entry.path
                    var changed = false
                    for step in steps {
                        if path == step.source { path = step.destination; changed = true }
                        else if path.hasPrefix(step.source + "/") { path = step.destination + path.dropFirst(step.source.count) }
                    }
                    if let entry = try? Entry(path) {
                        self.rows[i].entry = entry
                        if changed { self.rows[i].done = true; self.rows[i].proposed = entry.name }

                    }
                }
                // Keep root selections in sync when folders themselves move.
                for step in steps {
                    self.excluded = Set(self.excluded.map { path in
                        path == step.source ? step.destination : (path.hasPrefix(step.source + "/") ? step.destination + path.dropFirst(step.source.count) : path)
                    })
                    self.inventory.roots = self.inventory.roots.map { path in
                        path == step.source ? step.destination : (path.hasPrefix(step.source + "/") ? step.destination + path.dropFirst(step.source.count) : path)
                    }
                }
                self.refreshFrozen()
                self.busy = false; self.undoAvailable = engine.canUndo; self.preview()
                switch result {
                case .success: self.message = completion
                case .failure(let error): self.message = "\(completion) Stopped: \(error.localizedDescription) Undo remains available."
                }
                self.drainPending()
            }
        }
    }
    func undo() {
        guard !controlsLocked, let engine else { return }; busy = true
        worker.async {
            let result = Result { try engine.undo() }
            DispatchQueue.main.async {
                self.refreshFrozen()
                self.busy = false; self.undoAvailable = engine.canUndo
                switch result {
                case .success: self.rows = []; self.selection = []; self.inventory.roots = []; self.plan = []; self.message = "Last batch undone. Drop files to start again."
                case .failure(let error): self.message = "Undo stopped safely: \(error.localizedDescription)"
                }
                self.drainPending()
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: Model?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppUpdater.fixtureJournal != nil {
            AppUpdater.reportFixture("ready")
            AppUpdater.acknowledge()
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Self.model?.add(filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.model?.busy == true ? .terminateCancel : .terminateNow
    }
}
struct ContentView: View {
    @ObservedObject var model: Model
    // Display copy stays separate from Codable raw values for compatibility.
    private func scopeLabel(_ scope: Scope) -> String {
        switch scope {
        case .base: return "The file name without the extension"
        case .full: return "The entire file name and extension"
        case .ext: return "The file extension"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Action", selection: $model.operation.action) { ForEach(Action.allCases, id: \.self) { Text($0.rawValue) } }
                    if model.operation.action == .replace {
                        TextField("Find", text: $model.operation.search)
                        Picker("Replace", selection: $model.operation.occurrences) {
                            ForEach(Occurrences.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        Toggle("Ignore case", isOn: $model.operation.ignoreCase)
                    }
                    if model.operation.action == .append {
                        Toggle("Skip if already ends with this text", isOn: $model.operation.skipExistingSuffix)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.operation.action == .replace ? "Replace with" : "Description / text").font(.headline)
                        HStack {
                            TextField("Enter text", text: $model.operation.text)
                            Button { model.operation.text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Clear description only").accessibilityLabel("Clear description")
                        }
                        Text("No separator is added. Include a leading space if you want one.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Change").font(.headline)
                        Picker("Change", selection: $model.operation.scope) {
                            ForEach([Scope.full, .base, .ext], id: \.self) { scope in
                                Text(scopeLabel(scope)).tag(scope)
                            }
                        }.pickerStyle(.radioGroup).labelsHidden()
                        .help("Final extension only. Folders use their whole name.")
                    }
                }
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Process:").fontWeight(.semibold)
                        Toggle("Files", isOn: $model.files)
                        Toggle("Folders", isOn: $model.folders)
                        Toggle("Subfolders and their contents", isOn: $model.recursive)
                    }.font(.system(size: 12)).fixedSize(horizontal: true, vertical: false)
                }
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                }.frame(width: 500).disabled(model.controlsLocked)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Preview").font(.title2.bold())
                        Text("\(model.rows.count) items").foregroundStyle(.secondary)
                        if !model.selection.isEmpty { Text("\(model.selection.count) selected").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Add Files or Folders…", action: model.choose).disabled(model.controlsLocked)
                        Button("Clear List", action: model.clear)
                            .disabled(model.controlsLocked || model.rows.isEmpty)
                            .help("Removes entries from this window only; preserves text and undo")
                    }.padding(20)
                    if model.rows.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 88, weight: .bold))
                                .frame(width: 180, height: 160)
                                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6])).foregroundStyle(.tertiary) }
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text("Drop files and folders here")
                                .font(.title2)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .contentShape(Rectangle())
                    } else {
                    PreviewTable(model: model)
                    }
                }
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small); Button("Cancel", action: model.cancel) }
                Text(model.message).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer()
                Button("Undo Last Batch", action: model.undo).fixedSize().disabled(model.controlsLocked || !model.undoAvailable)
                Button("Rename \(model.pendingCount) Items", action: model.apply).fixedSize().buttonStyle(.borderedProminent).disabled(model.controlsLocked || model.pendingCount == 0)
            }.padding(16)
        }.frame(minWidth: 1200, minHeight: 600)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            let group = DispatchGroup(), lock = NSLock()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.add(urls) }
            return true
        }
    }
}
struct BatchRenameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppDelegate.model ?? Model()
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup("Batch Rename") { ContentView(model: model).onAppear { AppDelegate.model = model; AppUpdater.acknowledge(); AppUpdater.showRecoveryNotice(); AppUpdater.reportFixture("view-appeared"); updater.checkAtStartup() } }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { updater.check() }.disabled(updater.busy || model.busy)
                }
            }
    }
}

@main enum Launcher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify") {
            do { try Verification.run(); print("BUNDLED VERIFICATION PASSED"); exit(0) }
            catch { fputs("Verification failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--update-install" {
            do { try AppUpdater.install(CommandLine.arguments[2]); exit(0) }
            catch { AppUpdater.installFailed(CommandLine.arguments[2], error: error); exit(1) }
        }
        do {
            let journal = try AppUpdater.loadFixtureJournal()
            if CommandLine.arguments.contains("--lifecycle-probe") {
                guard let journal else { throw RenameError("Fixture resource was not recognized") }
                print("FIXTURE PROBE app=\(Bundle.main.bundleURL.path) journal=\(journal.path)")
                return
            }
            if let journal {
                AppUpdater.reportFixture("entered-main")
                AppDelegate.model = Model(journalURL: journal)
                AppUpdater.reportFixture("model-initialized")
            }
        } catch {
            fputs("Fixture configuration rejected: \(error)\n", stderr); exit(1)
        }
        BatchRenameApp.main()
    }
}
