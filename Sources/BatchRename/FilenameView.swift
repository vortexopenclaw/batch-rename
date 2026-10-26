import AppKit
import SwiftUI
import RenameCore

/// A single drawn line, never a text editor or scroll view. Windows are measured
/// at the actual cell width and end only at composed-character boundaries.
final class FilenameCell: NSView {
    var value = NSAttributedString(string: "")
    var name = ""
    var changes: [NSRange] = []
    var action: Action = .append
    var badge = ""
    var manualStart: Int?
    private(set) var visibleRange = NSRange(location: 0, length: 0)
    private(set) var rendered = NSAttributedString(string: "")
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 25) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(name: String, ranges: [NSRange], deletion: Bool, action: Action, note: String = "") {
        if self.name != name || changes != ranges || self.action != action { manualStart = nil }
        self.name = name; changes = ranges; self.action = action
        let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        for range in ranges where range.length > 0 && NSMaxRange(range) <= text.length {
            let whole = (name as NSString).rangeOfComposedCharacterSequences(for: range)
            text.addAttributes([.backgroundColor: NSColor.systemBlue, .foregroundColor: NSColor.white], range: whole)
            if deletion { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: whole) }
        }
        badge = note.isEmpty ? "" : (note == "\nCompleted" ? "✓" : "⚠")
        value = text; toolTip = name + note; setAccessibilityLabel(name + note)
        needsLayout = true; needsDisplay = true
    }
    func measureWindow() {
        var offsets = [0]
        for char in name { offsets.append(offsets.last! + String(char).utf16.count) }
        let count = offsets.count - 1
        let width = max(0, bounds.width - 8 - (badge.isEmpty ? 0 : 18))
        let ellipsis = NSAttributedString(string: "…", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        func make(_ lo: Int, _ hi: Int) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            if lo > 0 { result.append(ellipsis) }
            result.append(value.attributedSubstring(from: NSRange(location: offsets[lo], length: offsets[hi] - offsets[lo])))
            if hi < count { result.append(ellipsis) }
            return result
        }
        var lo = 0, hi = count
        if value.size().width > width && count > 0 {
            let target = RenamePresentation.revealRange(in: name, changes: changes)
            lo = offsets.lastIndex(where: { $0 <= target.location }) ?? 0
            hi = offsets.firstIndex(where: { $0 >= NSMaxRange(target) }) ?? count
            if action == .append { hi = count }
            if action == .prepend { lo = 0 }
            if let manualStart { lo = min(max(0, manualStart), count - 1); hi = lo + 1 }
            while hi > lo && make(lo, hi).size().width > width {
                if action == .append && manualStart == nil { lo += 1 } else { hi -= 1 }
            }
            while hi < count && make(lo, hi + 1).size().width <= width { hi += 1 }
            while lo > 0 && make(lo - 1, hi).size().width <= width { lo -= 1 }
        }
        visibleRange = NSRange(location: offsets[lo], length: offsets[hi] - offsets[lo])
        rendered = make(lo, hi)
    }
    override func layout() { super.layout(); measureWindow() }
    override func draw(_ dirtyRect: NSRect) {
        measureWindow()
        if !badge.isEmpty {
            (badge as NSString).draw(at: NSPoint(x: bounds.width - 18, y: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        }
        rendered.draw(at: NSPoint(x: 4, y: floor((bounds.height - rendered.size().height) / 2)))
    }
    func moveWindow(_ delta: CGFloat) {
        let start = (name as NSString).substring(to: visibleRange.location).count
        manualStart = max(0, start + (delta > 0 ? 3 : -3)); needsDisplay = true
    }
}

final class PreviewNativeTable: NSTableView {
    var removeEntries: (() -> Void)?
    var locked = false
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
        for title in ["Current Name", "New Name"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title; column.width = 320; column.minWidth = 40
            table.addTableColumn(column)
        }
        table.delegate = coordinator; table.dataSource = coordinator
        table.removeEntries = { [weak coordinator] in coordinator?.model.removeSelected() }
        let menu = NSMenu()
        for (title, action) in [("Copy Current Name", #selector(Coordinator.copyCurrent)), ("Copy New Name", #selector(Coordinator.copyNew)), ("Remove from List", #selector(Coordinator.remove))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = coordinator; menu.addItem(item)
        }
        table.menu = menu
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let table = scroll.documentView as! PreviewNativeTable
        context.coordinator.model = model
        context.coordinator.updating = true
        table.locked = model.controlsLocked
        table.reloadData()
        table.selectRowIndexes(IndexSet(model.rows.indices.filter { model.selection.contains(model.rows[$0].id) }), byExtendingSelection: false)
        context.coordinator.updating = false
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        var model: Model
        var updating = false
        init(_ model: Model) { self.model = model }
        @objc func remove() { model.removeSelected() }
        @objc func copyCurrent() { copyNames(current: true) }
        @objc func copyNew() { copyNames(current: false) }
        private func copyNames(current: Bool) {
            let names = model.rows.filter { model.selection.contains($0.id) }.map { current ? $0.original : $0.proposed }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            !model.selection.isEmpty && (menuItem.action != #selector(remove) || !model.controlsLocked)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            model.selection = Set(table.selectedRowIndexes.filter { $0 < model.rows.count }.map { model.rows[$0].id })
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            let row = model.rows[index]
            let current = tableColumn == tableView.tableColumns.first
            let cell = FilenameCell()
            cell.configure(name: current ? row.original : row.proposed,
                           ranges: row.done ? [] : (current ? row.preview?.sourceMatches : row.preview?.replacements) ?? [],
                           deletion: current && !row.done && row.preview?.deletion == true, action: model.operation.action,
                           note: row.done ? "\nCompleted" : row.error.map { "\n" + $0 } ?? (row.preview?.skipped == true ? "\nAlready ends with this text" : ""))
            return cell
        }
    }
}
