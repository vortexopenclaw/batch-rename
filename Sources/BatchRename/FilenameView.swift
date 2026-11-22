import AppKit
import SwiftUI
import RenameCore

/// A single drawn line, never a text editor or scroll view. Windows are measured
/// at the actual cell width and end only at composed-character boundaries.
final class FilenameCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FilenameCell")
    enum Badge: Equatable {
        case none, completed, skipped, problem, edited
        var symbol: String? {
            switch self {
            case .none: return nil
            case .completed: return "checkmark.circle"
            case .skipped: return "equal.circle"
            case .problem: return "exclamationmark.triangle.fill"
            case .edited: return "pencil"
            }
        }
        var tint: NSColor {
            switch self {
            case .problem: return .systemOrange
            case .edited: return .controlAccentColor
            default: return .secondaryLabelColor
            }
        }
    }
    var value = NSAttributedString(string: "")
    var name = ""
    var changes: [NSRange] = []
    var action: Action = .append
    private var deletion = false
    private(set) var badge = Badge.none
    var manualStart: Int?
    private(set) var visibleRange = NSRange(location: 0, length: 0)
    private(set) var rendered = NSAttributedString(string: "")
    /// Instrumentation for tests: completed window measurements and text-size trials in the last one.
    private(set) var measurements = 0
    private(set) var lastTrials = 0
    private var measuredWidth: CGFloat = -1
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 25) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Set by the row view: `.emphasized` while the row is selected in a key window.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { restyle(); measuredWidth = -1; needsLayout = true; needsDisplay = true } }
    }
    private var selected: Bool { backgroundStyle == .emphasized }
    func configure(name: String, ranges: [NSRange], deletion: Bool, action: Action, column: String = "", status: String = "", badge: Badge = .none) {
        if self.name != name || changes != ranges || self.action != action { manualStart = nil }
        self.name = name; changes = ranges; self.action = action; self.deletion = deletion; self.badge = badge
        restyle()
        toolTip = status.isEmpty ? name : name + "\n" + status
        setAccessibilityValue(name)
        setAccessibilityLabel(column.isEmpty ? nil : column)
        setAccessibilityHelp(status.isEmpty ? nil : status)
        measuredWidth = -1
        needsLayout = true; needsDisplay = true
    }
    /// Selected rows are accent blue too, so changes invert to white with blue text there.
    private func restyle() {
        let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor])
        for range in changes where range.length > 0 && NSMaxRange(range) <= text.length {
            let whole = (name as NSString).rangeOfComposedCharacterSequences(for: range)
            text.addAttributes([.backgroundColor: selected ? NSColor.white : NSColor.systemBlue, .foregroundColor: selected ? NSColor.systemBlue : NSColor.white], range: whole)
            if deletion { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: whole) }
        }
        value = text
    }
    func measureWindow() {
        measurements += 1
        measuredWidth = bounds.width
        var offsets = [0]
        for char in name { offsets.append(offsets.last! + String(char).utf16.count) }
        let count = offsets.count - 1
        let width = max(0, bounds.width - 8 - (badge == .none ? 0 : 18))
        let ellipsis = NSAttributedString(string: "…", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor])
        func make(_ lo: Int, _ hi: Int) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            if lo > 0 { result.append(ellipsis) }
            result.append(value.attributedSubstring(from: NSRange(location: offsets[lo], length: offsets[hi] - offsets[lo])))
            if hi < count { result.append(ellipsis) }
            return result
        }
        var trials = 0
        func fits(_ lo: Int, _ hi: Int) -> Bool { trials += 1; return make(lo, hi).size().width <= width }
        /// First value in `range` where `predicate` holds, assuming false-then-true.
        func first(_ range: ClosedRange<Int>, _ predicate: (Int) -> Bool) -> Int? {
            var low = range.lowerBound, high = range.upperBound + 1
            while low < high { let mid = (low + high) / 2; if predicate(mid) { high = mid } else { low = mid + 1 } }
            return low <= range.upperBound ? low : nil
        }
        var lo = 0, hi = count
        if count > 0 && !fits(0, count) {
            let target = RenamePresentation.revealRange(in: name, changes: changes)
            lo = offsets.lastIndex(where: { $0 <= target.location }) ?? 0
            if action == .prepend { lo = 0 }
            if let manualStart { lo = min(max(0, manualStart), count - 1) }
            if action == .append && manualStart == nil {
                // Keep the end (the appended text); reveal as much of the start as fits.
                lo = first(0...count) { fits($0, count) } ?? count
            } else {
                // Keep the start of the change; extend right, then left, as far as fits.
                let start = lo
                hi = lo < count ? (first((start + 1)...count) { !fits(start, $0) }.map { $0 - 1 } ?? count) : count
                let end = hi
                lo = first(0...start) { fits($0, end) } ?? start
            }
        }
        lastTrials = trials
        visibleRange = NSRange(location: offsets[lo], length: offsets[hi] - offsets[lo])
        rendered = make(lo, hi)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() { super.layout(); measureWindow() }
    override func draw(_ dirtyRect: NSRect) {
        // Measured in layout; this only covers a draw that arrives before any layout pass.
        if measuredWidth != bounds.width { measureWindow() }
        if let symbol = badge.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            let tint = selected ? NSColor.alternateSelectedControlTextColor : badge.tint
            let size = image.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect); tint.set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: bounds.width - 9 - size.width / 2, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height))
        }
        rendered.draw(at: NSPoint(x: 4, y: floor((bounds.height - rendered.size().height) / 2)))
    }
    func moveWindow(_ delta: CGFloat) {
        let start = (name as NSString).substring(to: visibleRange.location).count
        manualStart = max(0, start + (delta > 0 ? 3 : -3)); measuredWidth = -1; needsLayout = true; needsDisplay = true
    }
}

final class PreviewNativeTable: NSTableView {
    var removeEntries: (() -> Void)?
    var editSelected: (() -> Void)?
    var locked = false
    /// Instrumentation for tests.
    private(set) var reloadCount = 0
    override func reloadData() { reloadCount += 1; super.reloadData() }
    // Responder-chain shortcuts are local to the table; text fields keep their editor commands.
    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil); return true
        }
        if [51, 117].contains(event.keyCode) {
            if !locked { removeEntries?() }
            return true
        }
        // Return edits the new name of a single selected row (Cmd+Return renames).
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, selectedRowIndexes.count == 1 {
            if !locked { editSelected?() }
            return true
        }
        return false
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 && !selectedRowIndexes.contains(index) {
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            let point = convert(event.locationInWindow, from: nil)
            let row = row(at: point), column = column(at: point)
            if row >= 0, column >= 0, let cell = view(atColumn: column, row: row, makeIfNecessary: false) as? FilenameCell {
                cell.moveWindow(event.scrollingDeltaX); return
            }
        }
        super.scrollWheel(with: event)
    }
}
struct PreviewTable: NSViewRepresentable {
    @ObservedObject var model: Model
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScroll(coordinator: context.coordinator)
    }
    static func makeScroll(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        let table = PreviewNativeTable(frame: scroll.contentView.bounds)
        table.autoresizingMask = [.width]
        table.rowHeight = 25; table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAutomaticRowHeights = false; table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for title in [String(localized: "Current Name"), String(localized: "New Name")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title; column.width = 320; column.minWidth = 40
            table.addTableColumn(column)
        }
        table.delegate = coordinator; table.dataSource = coordinator
        table.target = coordinator; table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.removeEntries = { [weak coordinator] in coordinator?.model.removeSelected() }
        table.editSelected = { [weak coordinator, weak table] in
            guard let coordinator, let table else { return }
            coordinator.beginEditing(row: table.selectedRow, in: table)
        }
        let menu = NSMenu()
        for (title, action) in [(String(localized: "Edit New Name"), #selector(Coordinator.editNewName)), (String(localized: "Use Automatic Name"), #selector(Coordinator.useAutomaticName))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = coordinator; menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [(String(localized: "Copy Current Name"), #selector(Coordinator.copyCurrent)), (String(localized: "Copy New Name"), #selector(Coordinator.copyNew)), (String(localized: "Remove from List"), #selector(Coordinator.remove))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = coordinator; menu.addItem(item)
        }
        table.menu = menu
        scroll.documentView = table
        return scroll
    }
    /// The list can empty while the editor is open; never leave Rename waiting on it.
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.endEditing(commit: false) }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        Self.sync(scroll.documentView as! PreviewNativeTable, coordinator: context.coordinator, model: model)
    }
    /// Reloads only when the displayed rows changed; selection-only changes just reselect.
    static func sync(_ table: PreviewNativeTable, coordinator: Coordinator, model: Model) {
        coordinator.model = model
        coordinator.updating = true
        defer { coordinator.updating = false }
        table.locked = model.controlsLocked
        // Undo and installation close an open editor; its edit would be refused.
        if coordinator.editor != nil && (!model.inlineEditing || !model.namesEditable || !coordinator.editingRowVisible(in: model)) {
            coordinator.endEditing(commit: false)
        }
        if coordinator.version != model.rowsVersion {
            coordinator.version = model.rowsVersion
            table.reloadData()
        }
        let rows = model.visibleRows
        let wanted = IndexSet(rows.indices.filter { model.selection.contains(rows[$0].id) })
        if table.selectedRowIndexes != wanted { table.selectRowIndexes(wanted, byExtendingSelection: false) }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSTextFieldDelegate {
        var model: Model
        var updating = false
        var version = -1
        private(set) var editor: NSTextField?
        private var editingID: UUID?
        /// The name shown when editing began; committing it unchanged is not an edit.
        private var editingStart = ""
        init(_ model: Model) { self.model = model }
        /// The row being edited is still shown (it may have been removed or filtered out).
        func editingRowVisible(in model: Model) -> Bool {
            guard let id = editingID else { return true }
            return model.visibleRows.contains { $0.id == id }
        }
        @objc func remove() { model.removeSelected() }
        @objc func copyCurrent() { copyNames(current: true) }
        @objc func copyNew() { copyNames(current: false) }
        @objc func useAutomaticName() { model.useAutomaticName(model.selection) }
        @objc func editNewName() {
            guard let table = editableTable, model.selection.count == 1,
                  let index = model.visibleRows.firstIndex(where: { model.selection.contains($0.id) }) else { return }
            beginEditing(row: index, in: table)
        }
        weak var editableTable: NSTableView?
        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, sender.clickedColumn == 1 else { return }
            beginEditing(row: sender.clickedRow, in: sender)
        }
        private func copyNames(current: Bool) {
            let names = model.visibleRows.filter { model.selection.contains($0.id) }.map { current ? $0.original : $0.proposed }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            let selected = model.visibleRows.filter { model.selection.contains($0.id) }
            switch menuItem.action {
            case #selector(editNewName): return !model.controlsLocked && selected.count == 1 && !selected[0].done
            case #selector(useAutomaticName): return !model.controlsLocked && selected.contains { $0.manual && !$0.done }
            case #selector(remove): return !selected.isEmpty && !model.controlsLocked
            default: return !selected.isEmpty
            }
        }

        // MARK: Inline editing

        /// Edits the New Name cell in place. Return commits, Escape cancels.
        func beginEditing(row index: Int, in table: NSTableView) {
            editableTable = table
            let rows = model.visibleRows
            guard !model.controlsLocked, index >= 0, index < rows.count, !rows[index].done else { return }
            endEditing(commit: false)
            let field = NSTextField(frame: table.frameOfCell(atColumn: 1, row: index))
            field.font = .systemFont(ofSize: 13)
            field.stringValue = rows[index].proposed
            field.isBordered = true; field.focusRingType = .exterior
            field.setAccessibilityLabel(String(localized: "New Name"))
            field.delegate = self
            editor = field; editingID = rows[index].id; editingStart = field.stringValue
            model.inlineEditing = true
            table.addSubview(field)
            table.scrollRowToVisible(index)
            if table.window?.makeFirstResponder(field) == true, let text = field.currentEditor() {
                // Select the stem, like Finder, so typing keeps the extension.
                let stem = CompanionEdit.split(field.stringValue).stem
                text.selectedRange = NSRange(location: 0, length: rows[index].entry.identity.folder ? (field.stringValue as NSString).length : (stem as NSString).length)
            }
        }
        func endEditing(commit: Bool) {
            guard let field = editor, let id = editingID else { return }
            editor = nil; editingID = nil
            if model.inlineEditing { model.inlineEditing = false }
            let text = field.stringValue
            let table = field.superview as? NSTableView
            field.removeFromSuperview()
            if commit && !text.utf8.elementsEqual(editingStart.utf8) { model.setOverride(id, to: text) }
            if let table { table.window?.makeFirstResponder(table) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { endEditing(commit: true); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { endEditing(commit: false); return true }
            return false
        }
        func controlTextDidEndEditing(_ obj: Notification) { endEditing(commit: true) }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { model.visibleRows.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let rows = model.visibleRows
            model.selection = Set(table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0].id })
        }
        static func badge(for row: Row, newName: Bool) -> FilenameCell.Badge {
            if row.done { return .completed }
            if row.issue != nil { return .problem }
            if row.manual { return newName ? .edited : .none }
            if row.preview?.skipped == true { return .skipped }
            return .none
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            let rows = model.visibleRows
            guard index < rows.count else { return nil }
            let row = rows[index]
            editableTable = tableView
            let current = tableColumn == tableView.tableColumns.first
            let cell = tableView.makeView(withIdentifier: FilenameCell.reuseIdentifier, owner: self) as? FilenameCell ?? {
                let cell = FilenameCell(frame: .zero); cell.identifier = FilenameCell.reuseIdentifier; return cell
            }()
            cell.configure(name: current ? row.original : row.proposed,
                           ranges: row.done ? [] : (current ? row.preview?.sourceMatches : row.preview?.replacements) ?? [],
                           deletion: current && !row.done && row.preview?.deletion == true, action: model.operation.action,
                           column: tableColumn?.title ?? "", status: row.status, badge: Self.badge(for: row, newName: !current))
            return cell
        }
    }
}
