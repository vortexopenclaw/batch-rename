import Foundation
import AppKit
@preconcurrency import RenameCore

final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Lets through at most one worker progress update per interval, plus the final one.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    init(interval: TimeInterval = 0.05) { self.interval = interval }
    func shouldPost(done: Int, total: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard done >= total || now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

enum OperationState: Equatable { case idle, scanning, applying, undoing, installing }
enum QuitDecision: Equatable { case now, later }

struct TypeCount: Equatable {
    /// Lowercased extension without the dot; empty for files without one.
    var type: String
    var count: Int
    var label: String { type.isEmpty ? String(localized: "No Extension") : type.uppercased() }
}

struct Row: Identifiable {
    var id = UUID()
    var entry: Entry
    var original: String
    var proposed: String
    /// The name the current operation produces, ignoring any manual edit.
    var automatic = ""
    var done = false
    /// Name-level problem from the operation (for example missing find text).
    var error: String?
    /// Filesystem problem from the planner, valid while `proposed == problemName`.
    var problem: String?
    var problemName: String?
    /// The new name was typed by hand, or follows a companion edit.
    var manual = false
    var preview: NamePreview?
    var issue: String? { error ?? problem }
    var changes: Bool { !proposed.utf8.elementsEqual(original.utf8) }
    var status: String {
        if done { return String(localized: "Completed") }
        if let issue { return issue }
        if manual { return String(localized: "Edited") }
        if preview?.skipped == true { return String(localized: "Already ends with this text") }
        return changes ? String(localized: "Pending") : String(localized: "Unchanged")
    }
}

@MainActor final class Model: ObservableObject {
    // MARK: Rows and filtering

    @Published var rows: [Row] = [] { didSet { refreshVisible() } }
    /// Rows after the type filter, in display order.
    @Published private(set) var visibleRows: [Row] = []
    @Published private(set) var typeCounts: [TypeCount] = []
    /// Changes whenever `visibleRows` is republished; the table reloads only on change.
    private(set) var rowsVersion = 0
    @Published var selection = Set<UUID>()
    @Published private(set) var disabledTypes = Set<String>()
    /// Hand-typed names keyed by directory entry (path plus identity).
    @Published private(set) var overrides: [String: String] = [:]
    /// Order of hand edits; a companion group's other rows follow its newest edit.
    private var editOrder: [String: Int] = [:]
    private var editCounter = 0
    /// Companion rows the user set back to automatic, so they stop following the group's edit.
    private var keepAutomatic = Set<String>()
    private var excluded = Set<String>()

    // MARK: Settings

    @Published var operation = RenameOperation() {
        didSet { guard operation != oldValue else { return }; resetNotes(); preview() }
    }
    @Published var files = true { didSet { if files != oldValue { resetNotes(); rebuild() } } }
    @Published var folders = false { didSet { if folders != oldValue { resetNotes(); rebuild() } } }
    @Published var recursive = false { didSet { if recursive != oldValue { resetNotes(); rebuild() } } }
    /// Also adds rear or interior clips and sidecar files that share a clip's name.
    @Published var companions: Bool {
        didSet {
            guard companions != oldValue else { return }
            store.companions = companions
            resetNotes(); refreshVisible(); rebuild()
        }
    }
    @Published private(set) var recentTexts: [String]
    @Published private(set) var presets: [Preset]
    private let store: SettingsStore

    // MARK: Operation state

    @Published private(set) var state: OperationState = .idle
    /// A file operation (scan, rename, or undo) is running. Installation is separate.
    var busy: Bool { state == .scanning || state == .applying || state == .undoing }
    var installing: Bool { state == .installing }
    var controlsLocked: Bool { state != .idle }
    var canCancel: Bool { state == .applying }
    @Published var message = ModelText.dropToBegin
    /// Paths and errors behind the last scan's summary, for the message tooltip.
    @Published private(set) var scanIssues: [String] = []
    @Published var undoAvailable = false
    @Published private(set) var history: [BatchSummary] = []
    /// Outcome of the last operation (rename, undo, clear). Replaces the ready summary.
    private var outcome: String?
    /// Short notes (drops, companion edits) shown before the ready summary.
    private var notes: [String] = []
    /// Summary of the last scan's skipped items, replaced by every scan.
    private var scanNotes: [String] = []

    // MARK: Validation

    private var generation = 0
    @Published private(set) var validatedGeneration = 0
    private var plan: [PlanItem] = []
    private var proposalCount = 0
    private var previewPending = false
    /// No file operation is running and the current preview has been validated.
    var isIdle: Bool { state == .idle && (engine == nil || validatedGeneration == generation) }
    var canRename: Bool { state == .idle && engine != nil && validatedGeneration == generation && !plan.isEmpty }
    /// Valid renames once validated; until then, the proposed changes.
    var pendingCount: Int { validatedGeneration == generation ? plan.count : proposalCount }
    var renameTitle: String { ModelText.renameTitle(pendingCount) }
    var headerSummary: String { ModelText.header(visible: visibleRows.count, total: rows.count) }
    var hasSequenceToken: Bool { operation.text.range(of: #"\{#{1,4}\}"#, options: .regularExpression) != nil }

    // Internal deterministic test seams. Both run on the worker queue.
    var beforeMoveForTesting: ((PlanItem) throws -> Void)?
    var beforeValidationForTesting: (() -> Void)?

    private var inventory = Inventory()
    private var frozen = Set<String>()
    /// Entries renamed in this session, like `Engine.completedPaths`, but kept after the
    /// engine prunes their batch so a rescan never makes them pending again.
    private var sessionCompleted: [String: Identity] = [:]
    var startupHealthy: Bool { engine != nil }
    private var engine: Engine?
    private var engineFailure: String?
    private let cancellation = Cancellation()
    private var quitHandler: (() -> Void)?
    private let worker = DispatchQueue(label: "BatchRename.filesystem")
    private var pendingURLs: [URL] = []
    private var rebuildPending = false

    init(journalURL: URL? = nil, defaults: UserDefaults = .standard) {
        store = SettingsStore(defaults: defaults)
        companions = store.companions
        recentTexts = store.recentTexts
        presets = store.presets
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Batch Rename")
            engine = try Engine(journalURL: journalURL ?? AppUpdater.fixtureJournal ?? root.appendingPathComponent("undo.json"))
            refreshHistory()
            refreshFrozen()
        } catch { engineFailure = "Rename unavailable: " + error.localizedDescription; message = engineFailure! }
    }

    // MARK: Installation and quitting

    func beginInstallation() -> Bool {
        guard startupHealthy, state == .idle else { return false }
        state = .installing
        return true
    }
    func endInstallation() {
        guard state == .installing else { return }
        state = .idle
        drainPending()
        if state == .idle && (previewPending || validatedGeneration != generation) { preview() }
    }
    func cancel() { cancellation.set(true) }
    /// Scans and installation may quit at once. A rename is cancelled after the current
    /// item and an undo runs to completion; `onReady` fires when it is safe to quit.
    func requestQuit(onReady: @escaping () -> Void) -> QuitDecision {
        switch state {
        case .idle, .scanning, .installing: return .now
        case .applying, .undoing:
            quitHandler = onReady
            if state == .applying { cancel() }
            message = ModelText.quitting(undo: state == .undoing)
            return .later
        }
    }
    private func finishQuitIfRequested() {
        guard let handler = quitHandler else { return }
        quitHandler = nil
        handler()
    }

    // MARK: Adding and removing

    func add(_ urls: [URL]) { add(urls, notes: []) }
    private func add(_ urls: [URL], notes: [String]) {
        outcome = nil; self.notes = notes
        pendingURLs.append(contentsOf: urls)
        rebuild()
    }
    /// `nil` stands for a dropped item that could not be loaded as a file URL.
    func receiveDrop(_ items: [URL?]) {
        let valid = items.compactMap { $0 }.filter { url in
            var s = stat()
            return url.isFileURL && lstat(url.path, &s) == 0
        }
        let skipped = items.count - valid.count
        let dropNotes = skipped > 0 ? [ModelText.droppedSkipped(skipped)] : []
        guard !valid.isEmpty else {
            if skipped > 0 { outcome = nil; notes = dropNotes; message = dropNotes.joined(separator: " ") }
            return
        }
        add(valid, notes: dropNotes)
    }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK { self?.add(panel.urls) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }
    func removeSelected() {
        guard state == .idle else { return }
        let entries = rows.filter { selection.contains($0.id) }.map(\.entry)
        excluded.formUnion(entries.map(\.path))
        inventory.removeRoots(matching: entries)
        rows.removeAll { selection.contains($0.id) }
        selection = []
        preview()
    }
    func clear() {
        guard state == .idle else { return }
        rows = []; selection = []; excluded = []; inventory.roots = []
        overrides = [:]; editOrder = [:]; keepAutomatic = []; disabledTypes = []; scanIssues = []; scanNotes = []
        plan = []; proposalCount = 0
        generation += 1; validatedGeneration = generation
        notes = []; outcome = ModelText.clearedList
        message = engineFailure ?? ModelText.clearedList
    }
    private func resetNotes() { notes = []; outcome = nil }

    // MARK: Type filter

    func setType(_ type: String, enabled: Bool) {
        var types = disabledTypes
        if enabled { types.remove(type) } else { types.insert(type) }
        guard types != disabledTypes else { return }
        disabledTypes = types
        resetNotes(); refreshVisible(); preview()
    }
    func showAllTypes() {
        guard !disabledTypes.isEmpty else { return }
        disabledTypes = []
        resetNotes(); refreshVisible(); preview()
    }
    private static func type(of entry: Entry) -> String { (entry.name as NSString).pathExtension.lowercased() }
    private static func group(of entry: Entry) -> String {
        (entry.path as NSString).deletingLastPathComponent + "/" + companionGroupKey(for: entry.name)
    }
    private func filtered(_ rows: [Row]) -> [Row] {
        guard !disabledTypes.isEmpty else { return rows }
        let shown = { (row: Row) in !row.entry.identity.folder && !self.disabledTypes.contains(Self.type(of: row.entry)) }
        let groups = companions ? Set(rows.filter(shown).map { Self.group(of: $0.entry) }) : []
        return rows.filter { $0.entry.identity.folder || shown($0) || (!groups.isEmpty && groups.contains(Self.group(of: $0.entry))) }
    }
    private func refreshVisible() {
        visibleRows = filtered(rows)
        var counts: [String: Int] = [:]
        for row in rows where !row.entry.identity.folder { counts[Self.type(of: row.entry), default: 0] += 1 }
        let types = counts.sorted { $0.key < $1.key }.map { TypeCount(type: $0.key, count: $0.value) }
        if types != typeCounts { typeCounts = types }
        rowsVersion &+= 1
        let ids = Set(visibleRows.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
    }

    // MARK: Manual names

    private func key(_ e: Entry) -> String { "\(e.path)|\(e.identity.device)|\(e.identity.inode)|\(e.identity.birth)|\(e.identity.nanos)" }
    /// Sets a hand-typed new name. Empty or automatic names revert to automatic.
    /// With companion files on, the group's other rows follow the newest edit. Their
    /// names are derived during preview, so later changes or reverts carry over.
    func setOverride(_ id: UUID, to name: String) {
        guard state == .idle, let row = rows.first(where: { $0.id == id }), !row.done else { return }
        let k = key(row.entry)
        resetNotes()
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.elementsEqual(row.automatic.utf8) {
            if overrides[k] != nil { overrides[k] = nil; editOrder[k] = nil } else { keepAutomatic.insert(k) }
        } else {
            editCounter += 1
            overrides[k] = name; editOrder[k] = editCounter; keepAutomatic.remove(k)
            let applied = companionNames(rows, eligible: Set(visibleRows.map(\.id))).values.filter { $0.source == k }.count
            if applied > 0 { notes = [ModelText.companions(applied)] }
        }
        preview()
        if !notes.isEmpty { message = notes.joined(separator: " ") }
    }
    func useAutomaticName(_ ids: Set<UUID>) {
        guard state == .idle else { return }
        var changed = false
        for row in rows where ids.contains(row.id) && row.manual {
            let k = key(row.entry)
            if overrides[k] != nil { overrides[k] = nil; editOrder[k] = nil } else { keepAutomatic.insert(k) }
            changed = true
        }
        guard changed else { return }
        resetNotes(); preview()
    }
    /// Names companions derive from the newest hand edit in their group. Rows with their
    /// own edit, rows set back to automatic, folders, and mismatched names are left alone.
    private func companionNames(_ rows: [Row], eligible: Set<UUID>) -> [String: (name: String, source: String)] {
        guard companions else { return [:] }
        var sources: [String: (order: Int, key: String, automatic: String, name: String)] = [:]
        for row in rows where eligible.contains(row.id) && !row.done && !row.entry.identity.folder {
            let k = key(row.entry)
            guard let name = overrides[k], let order = editOrder[k] else { continue }
            let group = Self.group(of: row.entry)
            if (sources[group]?.order ?? Int.min) < order { sources[group] = (order, k, row.automatic, name) }
        }
        guard !sources.isEmpty else { return [:] }
        var result: [String: (name: String, source: String)] = [:]
        for row in rows where eligible.contains(row.id) && !row.done && !row.entry.identity.folder {
            let k = key(row.entry)
            guard overrides[k] == nil, !keepAutomatic.contains(k), let source = sources[Self.group(of: row.entry)], source.key != k,
                  let name = CompanionEdit.propagate(automatic: source.automatic, edited: source.name, companion: row.automatic) else { continue }
            result[k] = (name, source.key)
        }
        return result
    }

    // MARK: Recent text and presets

    func useRecent(_ text: String) { operation.text = text }
    private func recordRecent(_ text: String) {
        guard !text.isEmpty else { return }
        var list = recentTexts
        list.removeAll { $0 == text }
        list.insert(text, at: 0)
        recentTexts = Array(list.prefix(SettingsStore.recentLimit))
        store.recentTexts = recentTexts
    }
    func savePreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = Preset(name: name, operation: operation)
        if let i = presets.firstIndex(where: { $0.name == name }) { presets[i] = preset } else { presets.append(preset) }
        store.presets = presets
    }
    func applyPreset(_ preset: Preset) { operation = preset.operation }
    func deletePreset(named name: String) {
        presets.removeAll { $0.name == name }
        store.presets = presets
    }
    func insertToken(_ token: String) { operation.text += token }

    // MARK: History

    private func refreshHistory() {
        history = engine?.history ?? []
        undoAvailable = engine?.canUndo ?? false
    }
    var undoHelp: String {
        guard let target = history.first(where: \.applied) else { return ModelText.nothingToUndo }
        return ModelText.undoHelp(count: target.count, date: target.date)
    }
    func undoThroughPrompt(_ id: UUID) -> String {
        let applied = history.filter(\.applied)
        guard let position = applied.firstIndex(where: { $0.id == id }) else { return ModelText.nothingToUndo }
        return ModelText.undoThroughPrompt(batches: position + 1, items: applied[...position].reduce(0) { $0 + $1.count })
    }

    // MARK: Scanning

    private func refreshFrozen() {
        frozen = []
        let completed = (engine?.completedPaths ?? [:]).merging(sessionCompleted) { recorded, _ in recorded }
        for (path, id) in completed {
            // Content edits must not make a previously completed directory entry pending.
            // Move and undo validation still use the complete recorded identity.
            if let entry = try? Entry(path),
               entry.identity.device == id.device, entry.identity.inode == id.inode,
               entry.identity.birth == id.birth, entry.identity.nanos == id.nanos,
               entry.identity.kind == id.kind { frozen.insert(key(entry)) }
        }
    }
    /// Moves a completed path, and anything inside a completed folder, from one path to another.
    private func moveCompleted(from source: String, to destination: String, identity: Identity?) {
        if identity?.folder ?? sessionCompleted[source]?.folder ?? false {
            for (path, id) in sessionCompleted where path.hasPrefix(source + "/") {
                sessionCompleted[path] = nil
                sessionCompleted[destination + path.dropFirst(source.count)] = id
            }
        }
        sessionCompleted[source] = nil
        sessionCompleted[destination] = identity
    }
    private func drainPending() {
        if rebuildPending || !pendingURLs.isEmpty { rebuild() }
    }
    func rebuild() {
        guard state == .idle else { rebuildPending = true; return }
        rebuildPending = false
        // Only an explicit drop restores exclusions (including descendants of a dropped folder).
        for url in pendingURLs {
            let path = url.standardizedFileURL.path
            excluded = excluded.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
        inventory.append(pendingURLs.map(\.path))
        pendingURLs = []
        inventory.files = files; inventory.folders = folders; inventory.recursive = recursive
        inventory.includeCompanions = companions
        state = .scanning
        generation += 1
        let inventory = inventory
        worker.async {
            let report = inventory.scanReport()
            DispatchQueue.main.async { self.finishScan(report) }
        }
    }
    private func finishScan(_ report: ScanReport) {
        state = .idle
        if rebuildPending || !pendingURLs.isEmpty { rebuild(); return }
        // Missing roots must not fail every later scan.
        let missing = Set(report.missingRoots)
        inventory.roots.removeAll { missing.contains($0) }
        refreshFrozen()
        var seen = Set<String>()
        let completed = rows.filter { $0.done && frozen.contains(key($0.entry)) && seen.insert(key($0.entry)).inserted }
        // Rows can share a key (for example after a remap); keep the first id instead of trapping.
        let previous = Dictionary(rows.map { (key($0.entry), $0.id) }, uniquingKeysWith: { first, _ in first })
        rows = completed + report.entries.filter { !seen.contains(key($0)) && !excluded.contains($0.path) }.map {
            Row(id: previous[key($0)] ?? UUID(), entry: $0, original: $0.name, proposed: $0.name, automatic: $0.name, done: frozen.contains(key($0)))
        }
        selection.formIntersection(Set(rows.map(\.id)))
        scanIssues = report.missingRoots.map { String(localized: "No longer exists: \($0)") } + report.issues
        scanNotes = []
        if !report.missingRoots.isEmpty { scanNotes.append(ModelText.missingRoots(report.missingRoots.count)) }
        if !report.issues.isEmpty { scanNotes.append(ModelText.unreadable(report.issues.count)) }
        preview()
    }

    // MARK: Preview and validation

    /// Names are previewed synchronously; filesystem validation runs on the worker,
    /// debounced, and only the newest generation is accepted.
    func preview() {
        guard state == .idle else { previewPending = true; return }
        previewPending = false
        generation += 1
        guard engine != nil else {
            plan = []; proposalCount = 0; validatedGeneration = generation
            message = engineFailure ?? "Rename unavailable: undo engine is not initialized."
            return
        }
        let visible = Set(visibleRows.map(\.id))
        var updated = rows, proposals: [Proposal] = [], index = 0
        var automatics: [Int: NamePreview] = [:]
        for i in updated.indices where !updated[i].done && visible.contains(updated[i].id) {
            index += 1
            let entry = updated[i].entry
            let context = TokenContext(index: index, modified: entry.modified)
            do { automatics[i] = try operation.preview(updated[i].original, folder: entry.identity.folder, context: context); updated[i].error = nil }
            catch { updated[i].error = error.localizedDescription }
            updated[i].automatic = automatics[i]?.name ?? updated[i].original
        }
        let derived = companionNames(updated, eligible: visible)
        for i in updated.indices where !updated[i].done && visible.contains(updated[i].id) {
            let k = key(updated[i].entry), automatic = automatics[i]
            if let name = overrides[k] ?? derived[k]?.name {
                updated[i].manual = true; updated[i].error = nil
                updated[i].proposed = name
                updated[i].preview = Self.editedPreview(original: updated[i].original, edited: name, base: automatic)
            } else {
                updated[i].manual = false
                updated[i].proposed = updated[i].automatic
                updated[i].preview = automatic
            }
            if updated[i].problemName != updated[i].proposed { updated[i].problem = nil; updated[i].problemName = nil }
            if updated[i].error == nil && updated[i].changes { proposals.append(Proposal(entry: updated[i].entry, name: updated[i].proposed)) }
        }
        rows = updated
        plan = []
        proposalCount = proposals.count
        let current = generation, proposed = Set(proposals.map(\.entry.path))
        guard !proposals.isEmpty else { finishValidation(PlanResult(items: [], problems: [:]), proposed: proposed, generation: current); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, current == self.generation, self.state == .idle else { return }
            let hook = self.beforeValidationForTesting
            self.worker.async {
                hook?()
                let result = Planner.plan(proposals: proposals)
                DispatchQueue.main.async {
                    guard current == self.generation, self.state == .idle else { return }
                    self.finishValidation(result, proposed: proposed, generation: current)
                }
            }
        }
    }
    /// `NamePreview` has no public initializer; derive one from a no-op preview.
    private static func editedPreview(original: String, edited: String, base: NamePreview?) -> NamePreview? {
        guard var preview = base ?? (try? RenameOperation().preview(original)) else { return nil }
        let ranges = CompanionEdit.highlight(original: original, edited: edited)
        preview.name = edited; preview.skipped = false
        preview.sourceMatches = [ranges.source]; preview.replacements = [ranges.replacement]
        preview.deletion = ranges.replacement.length == 0 && ranges.source.length > 0
        return preview
    }
    /// Every proposed row takes this result's problem, so a resolved problem clears.
    private func finishValidation(_ result: PlanResult, proposed: Set<String>, generation current: Int) {
        plan = result.items
        var updated = rows, changed = false
        for i in updated.indices where !updated[i].done && proposed.contains(updated[i].entry.path) {
            let problem = result.problems[updated[i].entry.path]
            guard updated[i].problem != problem || (problem != nil && updated[i].problemName != updated[i].proposed) else { continue }
            updated[i].problem = problem; updated[i].problemName = problem == nil ? nil : updated[i].proposed
            changed = true
        }
        if changed { rows = updated }
        validatedGeneration = current
        composeMessage()
    }
    private func composeMessage() {
        guard engine != nil else { message = engineFailure ?? message; return }
        var parts = outcome.map { [$0] } ?? []
        parts += notes + scanNotes
        let problems = visibleRows.filter { !$0.done && $0.issue != nil }.count
        if outcome == nil && !rows.isEmpty && (plan.count > 0 || problems > 0 || parts.isEmpty) {
            parts.append(ModelText.ready(changes: plan.count, problems: problems))
        }
        message = parts.isEmpty ? ModelText.dropToBegin : parts.joined(separator: " ")
    }

    // MARK: Renaming and undo

    private func remapPaths(_ steps: [Step], reverse: Bool) -> (rows: [Row], changed: Set<UUID>, oldKeys: [String]) {
        func map(_ path: String) -> (String, Bool) {
            var path = path, changed = false
            for step in steps {
                let (from, to) = reverse ? (step.destination, step.source) : (step.source, step.destination)
                if path == from { path = to; changed = true }
                else if path.hasPrefix(from + "/") { path = to + path.dropFirst(from.count) }
            }
            return (path, changed)
        }
        var updated = rows, changed = Set<UUID>(), oldKeys: [String] = []
        for i in updated.indices {
            let (path, renamed) = map(updated[i].entry.path)
            guard path != updated[i].entry.path || renamed, let entry = try? Entry(path) else { continue }
            if renamed { changed.insert(updated[i].id); oldKeys.append(key(updated[i].entry)) }
            updated[i].entry = entry
        }
        // Keep root selections and exclusions in sync when folders themselves move.
        excluded = Set(excluded.map { map($0).0 })
        inventory.roots = inventory.roots.map { map($0).0 }
        return (updated, changed, oldKeys)
    }
    func apply() {
        guard canRename, let engine else { return }
        state = .applying
        generation += 1
        cancellation.set(false)
        let token = cancellation, plan = plan, before = Set(engine.steps.map(\.id)), hook = beforeMoveForTesting
        let throttle = ProgressThrottle()
        message = ModelText.progress(undoing: false, done: 0, total: plan.count)
        worker.async {
            let result = Result {
                try engine.apply(plan, cancelled: { token.requested }, beforeMove: hook, progress: { done, total in
                    guard throttle.shouldPost(done: done, total: total) else { return }
                    DispatchQueue.main.async { if self.state == .applying && self.quitHandler == nil { self.message = ModelText.progress(undoing: false, done: done, total: total) } }
                })
            }
            // Compaction can prune old batches, so identify this batch by step id.
            let steps = engine.steps.filter { !before.contains($0.id) && $0.done && !$0.undone }
            let destinations = Set(steps.map(\.destination))
            let completed = plan.filter { destinations.contains($0.destination) }
            let completedFolders = completed.filter { $0.entry.identity.folder }.count
            DispatchQueue.main.async {
                self.finishApply(result, steps: steps, files: completed.count - completedFolders, folders: completedFolders, total: plan.count)
            }
        }
    }
    private func finishApply(_ result: Result<ApplyOutcome, Error>, steps: [Step], files: Int, folders: Int, total: Int) {
        let remapped = remapPaths(steps, reverse: false)
        var updated = remapped.rows
        let changed = remapped.changed, oldKeys = remapped.oldKeys
        for i in updated.indices where changed.contains(updated[i].id) {
            updated[i].done = true; updated[i].proposed = updated[i].entry.name; updated[i].manual = false
            updated[i].problem = nil; updated[i].problemName = nil
        }
        rows = updated
        for k in oldKeys { overrides[k] = nil; editOrder[k] = nil; keepAutomatic.remove(k) }
        for step in steps { moveCompleted(from: step.source, to: step.destination, identity: step.identity) }
        refreshFrozen()
        state = .idle
        refreshHistory()
        let renamed = files + folders
        let canUndo = undoAvailable && renamed > 0
        notes = []
        switch result {
        case .success(let outcome) where outcome.cancelled:
            self.outcome = ModelText.cancelled(renamed: outcome.renamed, total: outcome.total, undo: canUndo)
        case .success:
            outcome = ModelText.renamed(files: files, folders: folders)
        case .failure(let error):
            outcome = ModelText.stopped(error.localizedDescription, renamed: renamed > 0 ? ModelText.renamed(files: files, folders: folders) : nil, undo: canUndo)
        }
        if renamed > 0 { recordRecent(operation.text) }
        preview()
        finishQuitIfRequested()
        drainPending()
    }
    func undo() { startUndo(through: nil) }
    func undoThrough(_ batch: UUID) { startUndo(through: batch) }
    private func startUndo(through batch: UUID?) {
        guard state == .idle, let engine, engine.canUndo else { return }
        state = .undoing
        generation += 1
        let throttle = ProgressThrottle(), restored = Counter()
        worker.async {
            let before = engine.steps.filter { $0.done && !$0.undone }
            let progress: (Int, Int) -> Void = { done, total in
                restored.value = done
                guard throttle.shouldPost(done: done, total: total) else { return }
                DispatchQueue.main.async { if self.state == .undoing && self.quitHandler == nil { self.message = ModelText.progress(undoing: true, done: done, total: total) } }
            }
            let result = Result { try batch.map { try engine.undo(through: $0, progress: progress) } ?? engine.undo(progress: progress) }
            // Fully undone batches are pruned from the journal; a missing step was undone.
            let after = Dictionary(engine.steps.map { ($0.id, $0.undone) }, uniquingKeysWith: { first, _ in first })
            let undone = before.filter { after[$0.id] ?? true }
            DispatchQueue.main.async { self.finishUndo(result, undone: undone, restored: restored.value) }
        }
    }
    private func finishUndo(_ result: Result<ApplyOutcome, Error>, undone: [Step], restored: Int) {
        // Undo runs newest step first; replay that order to map rows back.
        let (updated, _, _) = remapPaths(undone.reversed(), reverse: true)
        rows = updated
        for step in undone.reversed() { moveCompleted(from: step.destination, to: step.source, identity: nil) }
        refreshFrozen()
        state = .idle
        refreshHistory()
        notes = []
        switch result {
        case .success(let outcome): self.outcome = ModelText.restored(outcome.renamed)
        case .failure(let error):
            // An ancestor may already have been restored before a child was rejected.
            outcome = ModelText.undoStopped(error.localizedDescription) + (restored > 0 ? " " + ModelText.restored(restored) : "")
        }
        // Rescan from the remapped roots; rows added after the batch stay.
        rebuild()
        finishQuitIfRequested()
    }
}
