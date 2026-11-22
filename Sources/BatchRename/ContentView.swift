import SwiftUI
import AppKit
import UniformTypeIdentifiers
@preconcurrency import RenameCore

/// Window-local view state. (`@State` needs a macro plugin the direct `swiftc` build cannot load.)
final class ViewState: ObservableObject {
    @Published var dropTargeted = false
    @Published var showingHistory = false
    @Published var historySelection: UUID?
    @Published var confirmingUndo = false
}

struct ContentView: View {
    @ObservedObject var model: Model
    @StateObject private var ui = ViewState()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar(model: model).frame(width: 500).disabled(model.controlsLocked)
                Divider()
                PreviewPane(model: model)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                if model.canCancel { Button("Cancel", action: model.cancel) }
                Text(model.message).font(.callout).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .help(model.scanIssues.prefix(20).joined(separator: "\n"))
                Spacer()
                Button("History…") { ui.historySelection = nil; ui.showingHistory = true }
                    .fixedSize().disabled(model.controlsLocked || model.history.isEmpty)
                    .help("Shows recent batches and undoes several at once")
                Button("Undo Last Batch", action: model.undo).fixedSize()
                    .disabled(model.controlsLocked || !model.undoAvailable)
                    .help(model.undoHelp)
                Button(model.renameTitle, action: model.apply).fixedSize().buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canRename)
            }.padding(16)
        }
        .frame(minWidth: 1200, minHeight: 600)
        .overlay {
            if ui.dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // `.item` also accepts drops that are not files (for example Photos promises) so they can be reported.
        .onDrop(of: [UTType.fileURL, UTType.item], isTargeted: $ui.dropTargeted) { providers in
            DropLoader.load(providers) { model.receiveDrop($0) }
            return true
        }
        .sheet(isPresented: $ui.showingHistory) { HistorySheet(model: model, ui: ui) }
    }
}

enum DropLoader {
    /// One result per provider; `nil` when the provider has no readable file URL.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL?]) -> Void) {
        let group = DispatchGroup(), lock = NSLock()
        var results = [URL?](repeating: nil, count: providers.count)
        for (index, provider) in providers.enumerated() where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                lock.lock(); results[index] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(results) } }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Action", selection: $model.operation.action) { ForEach(Action.allCases, id: \.self) { Text($0.label).tag($0) } }
                    if model.operation.action == .replace {
                        TextField("Find", text: $model.operation.search)
                        Picker("Replace", selection: $model.operation.occurrences) {
                            ForEach(Occurrences.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Toggle("Ignore case", isOn: $model.operation.ignoreCase)
                    }
                    if model.operation.action == .append {
                        Toggle("Skip if already ends with this text", isOn: $model.operation.skipExistingSuffix)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.operation.action == .replace ? "Replace with" : "Description / text").font(.headline)
                        HStack(spacing: 6) {
                            TextField("Enter text", text: $model.operation.text)
                            Button { model.operation.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).help("Clear description only").accessibilityLabel("Clear description")
                            InsertMenu(model: model)
                            PresetsMenu(model: model)
                        }
                        if model.hasSequenceToken {
                            HStack(spacing: 6) {
                                Text("Start at")
                                TextField("Start at", value: Binding(get: { model.operation.sequenceStart },
                                                                     set: { model.operation.sequenceStart = Preset.clampedStart($0) }), format: .number)
                                    .labelsHidden().monospacedDigit().frame(width: 72)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Change").font(.headline)
                        Picker("Change", selection: $model.operation.scope) {
                            ForEach([Scope.full, .base, .ext], id: \.self) { scope in
                                Text(scope.label).tag(scope)
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
                Toggle("Companion files", isOn: $model.companions)
                    .font(.system(size: 12))
                    .help("Also adds rear or interior clips and sidecar files (.LRV, .THM, .SRT, .GPX) that share a clip's name.")
            }
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
        }
    }
}

private struct InsertMenu: View {
    @ObservedObject var model: Model
    var body: some View {
        Menu {
            Menu("Sequence Number") {
                ForEach(1...4, id: \.self) { digits in
                    Button(String(repeating: "0", count: digits - 1) + "1") { model.insertToken("{" + String(repeating: "#", count: digits) + "}") }
                }
            }
            Button("Date") { model.insertToken("{date}") }
            Button("Time") { model.insertToken("{time}") }
        } label: { Text("Insert") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Adds a sequence number, date, or time. Date and time come from each file's modified date.")
    }
}

private struct PresetsMenu: View {
    @ObservedObject var model: Model
    var body: some View {
        Menu {
            Section("Recent") {
                if model.recentTexts.isEmpty { Text("No Recent Text") }
                ForEach(model.recentTexts, id: \.self) { text in
                    Button { model.useRecent(text) } label: { Text(verbatim: text) }
                }
            }
            Section("Presets") {
                if model.presets.isEmpty { Text("No Presets") }
                ForEach(model.presets) { preset in
                    Button { model.applyPreset(preset) } label: { Text(verbatim: preset.name) }
                }
            }
            Divider()
            Button("Save Current Settings as Preset…") {
                PresetPrompt.ask(defaultName: model.operation.text) { model.savePreset(named: $0) }
            }
            Menu("Delete Preset") {
                ForEach(model.presets) { preset in
                    Button { model.deletePreset(named: preset.name) } label: { Text(verbatim: preset.name) }
                }
            }.disabled(model.presets.isEmpty)
        } label: { Image(systemName: "clock.arrow.circlepath") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Recent text and saved presets")
        .accessibilityLabel("Recent text and presets")
    }
}

@MainActor enum PresetPrompt {
    static func ask(defaultName: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Preset")
        alert.informativeText = String(localized: "Saves the action, text, find text, and options so you can apply them in one click.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        field.placeholderString = String(localized: "Preset name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn && !name.isEmpty { completion(name) }
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }
}

private struct PreviewPane: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview").font(.title2.bold())
                Text(model.headerSummary).foregroundStyle(.secondary).monospacedDigit()
                if !model.selection.isEmpty { Text("\(model.selection.count) selected").foregroundStyle(.secondary).monospacedDigit() }
                TypesMenu(model: model)
                Spacer()
                Button("Add Files or Folders…", action: model.choose).disabled(model.controlsLocked)
                Button("Clear List", action: model.clear)
                    .disabled(model.controlsLocked)
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
}

private struct TypesMenu: View {
    @ObservedObject var model: Model
    var body: some View {
        Menu {
            Toggle("All Types", isOn: Binding(get: { model.disabledTypes.isEmpty }, set: { if $0 { model.showAllTypes() } }))
            Divider()
            ForEach(model.typeCounts, id: \.type) { type in
                Toggle(isOn: Binding(get: { !model.disabledTypes.contains(type.type) }, set: { model.setType(type.type, enabled: $0) })) {
                    Text(verbatim: "\(type.label) (\(type.count.formatted()))")
                }
            }
        } label: { Text("Types") }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(model.typeCounts.isEmpty || model.controlsLocked)
        .help("Show or hide files by type. Hidden files are not renamed.")
    }
}

struct HistorySheet: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: ViewState
    private var selectedApplied: BatchSummary? {
        model.history.first { $0.id == ui.historySelection && $0.applied }
    }
    private func dismiss() { ui.showingHistory = false }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Undo History").font(.title2.bold())
            if model.history.isEmpty {
                Text("No renames yet.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.history, selection: $ui.historySelection) { batch in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(ModelText.historyDate(batch.date)).fontWeight(.semibold)
                            Text(ModelText.items(batch.count)).foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                            Text(batch.applied ? "Applied" : "Undone").foregroundStyle(batch.applied ? .primary : .secondary)
                        }
                        ForEach(Array(batch.examples.enumerated()), id: \.offset) { _, example in
                            Text(verbatim: "\(example.from) → \(example.to)")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(batch.id)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Undo Through This Batch") { ui.confirmingUndo = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedApplied == nil || model.controlsLocked)
                    .help("Undoes this batch and every newer batch that is still applied")
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .confirmationDialog(ui.historySelection.map { model.undoThroughPrompt($0) } ?? "", isPresented: $ui.confirmingUndo) {
            Button("Undo", role: .destructive) {
                if let id = selectedApplied?.id { model.undoThrough(id) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files return to the names they had before these batches.")
        }
    }
}
