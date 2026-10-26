#if DIRECT_UI_TESTS
import XCTest
import AppKit
import RenameCore

final class PreviewLayoutTests: XCTestCase {
    @MainActor func testMeasuredUnicodeWindowsAndBlueRanges() throws {
        let cell = FilenameCell(frame: NSRect(x: 0, y: 0, width: 230, height: 25))
        var op = RenameOperation(); op.text = " 👩🏽‍💻e\u{301} suffix"
        let source = String(repeating: "long filename ", count: 12) + ".MP4"
        let preview = try op.preview(source)
        cell.configure(name: preview.name, ranges: preview.replacements, deletion: false, action: .append)
        cell.measureWindow()
        XCTAssertTrue(cell.rendered.string.hasSuffix(op.text + ".MP4"))
        XCTAssertLessThanOrEqual(cell.rendered.size().width, 222)
        let range = preview.replacements[0]
        XCTAssertEqual(cell.value.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertEqual(cell.value.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .white)
        XCTAssertEqual(cell.frame.height, 25)
        XCTAssertFalse(cell.subviews.contains { $0 is NSScrollView || $0 is NSTextView })
        op.action = .replace; op.search = "TARGET"; op.text = "👩🏽‍💻e\u{301}"
        let middle = String(repeating: "a", count: 90) + "TARGET" + String(repeating: "z", count: 90)
        let replaced = try op.preview(middle)
        cell.configure(name: replaced.name, ranges: replaced.replacements, deletion: false, action: .replace)
        cell.measureWindow()
        XCTAssertTrue(cell.rendered.string.contains(op.text))
        XCTAssertEqual((replaced.name as NSString).rangeOfComposedCharacterSequences(for: cell.visibleRange), cell.visibleRange)
        cell.frame.size.width = 140; cell.measureWindow()
        XCTAssertTrue(cell.rendered.string.contains(op.text))
        cell.moveWindow(20); cell.measureWindow()
        XCTAssertLessThanOrEqual(cell.rendered.size().width, 132)
        let image = NSImage(size: cell.bounds.size)
        image.lockFocus(); cell.draw(cell.bounds); image.unlockFocus()
        XCTAssertNotNil(image.tiffRepresentation)
        cell.configure(name: source, ranges: preview.sourceMatches, deletion: false, action: .append)
        cell.measureWindow(); XCTAssertTrue(cell.rendered.string.hasSuffix(".MP4"))
        cell.configure(name: "prefix " + source, ranges: [NSRange(location: 0, length: 7)], deletion: false, action: .prepend)
        cell.measureWindow(); XCTAssertTrue(cell.rendered.string.hasPrefix("prefix "))
    }
    @MainActor func testNativeTableHeightAndLocalKeyboard() throws {
        let table = PreviewNativeTable()
        table.rowHeight = 25; table.usesAutomaticRowHeights = false
        var removed = 0
        table.removeEntries = { removed += 1 }
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        XCTAssertTrue(table.handleKey(delete)); XCTAssertEqual(removed, 1)
        table.locked = true; XCTAssertTrue(table.handleKey(delete)); XCTAssertEqual(removed, 1)
        let select = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        XCTAssertTrue(table.handleKey(select))
        // Field editing uses its own responder, with no global event monitor.
        let editor = NSTextView(); editor.string = "description"; editor.selectAll(nil)
        XCTAssertEqual(editor.selectedRange().length, 11)
        editor.deleteBackward(nil); XCTAssertEqual(editor.string, "")
        XCTAssertEqual(removed, 1); XCTAssertEqual(table.rowHeight, 25)
    }
    @MainActor func testRemovalExclusionReaddAndMixedHistory() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"]!).appendingPathComponent("preview-" + UUID().uuidString)
        let folder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = folder.appendingPathComponent("a.txt"), b = folder.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let model = Model(journalURL: root.appendingPathComponent("journal/undo.json"))
        func wait() async throws {
            for _ in 0..<500 { if !model.busy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            XCTFail("Timed out")
        }
        model.operation.text = "X"; model.add([folder]); try await wait()
        let coordinator = PreviewTable.Coordinator(model)
        let scroll = PreviewTable.makeScroll(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 660, height: 300)
        let table = scroll.documentView as! PreviewNativeTable
        table.reloadData(); scroll.layoutSubtreeIfNeeded()
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertNil(scroll.horizontalScroller)
        XCTAssertEqual(table.numberOfColumns, 2)
        XCTAssertEqual(table.rect(ofRow: 0).height, 25)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(model.selection.count, 1)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: true)
        XCTAssertEqual(model.selection.count, 2)
        let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        table.deselectAll(nil); table.keyDown(with: selectAll)
        XCTAssertEqual(model.selection.count, 2)
        let id = model.rows.first { $0.original == "a.txt" }!.id
        model.selection = [id]; model.operation.text = "Y"
        XCTAssertTrue(model.rows.contains { $0.id == id }); XCTAssertEqual(model.selection, [id])
        table.reloadData()
        XCTAssertEqual(table.rect(ofRow: 0).height, 25)
        let deleteRow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        table.keyDown(with: deleteRow); XCTAssertEqual(try Data(contentsOf: a), Data("a".utf8))
        model.recursive = true; try await wait(); model.rebuild(); try await wait()
        XCTAssertEqual(model.rows.map(\.original), ["b.txt"])
        model.apply(); try await wait(); XCTAssertTrue(model.undoAvailable)
        model.add([a, a]); try await wait(); XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows.filter(\.done).count, 1)
        model.selection = Set(model.rows.map(\.id)); model.removeSelected()
        XCTAssertTrue(model.rows.isEmpty); XCTAssertTrue(model.undoAvailable); XCTAssertEqual(model.operation.text, "Y")
        model.rebuild(); try await wait(); XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("bY.txt").path))
        model.add([folder]); try await wait(); XCTAssertEqual(model.rows.count, 2)
        XCTAssertTrue(model.beginInstallation()); model.selection = Set(model.rows.map(\.id)); model.removeSelected()
        XCTAssertEqual(model.rows.count, 2); model.endInstallation()
        model.undo(); try await wait(); XCTAssertEqual(try Data(contentsOf: b), Data("b".utf8))
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.rows.isEmpty)
    }
}
#endif
