#if DIRECT_UI_TESTS
import XCTest
import Combine
import Foundation
import AppKit
import RenameCore

/// Regressions for audited app-layer bugs, driven through the real `Model`.
final class UIBugTests: ScratchTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
    @MainActor private func pendingRows(_ model: Model) -> Int { model.rows.filter { $0.status == "Pending" }.count }

    // Bug 1: missing roots are dropped and reported in plain words.
    @MainActor func testMissingRootsAreDroppedAndReported() async throws {
        let a = try file("a.txt"), gone = root.appendingPathComponent("gone.txt").path
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a), url(gone)]); try await waitForIdle(model)
        XCTAssertEqual(model.rows.map(\.original), ["a.txt"])
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(pendingRows(model), model.pendingCount)
        XCTAssertTrue(model.message.hasPrefix("Skipped 1 item that no longer exists."), model.message)
        // The missing root is forgotten: creating it later does not add it back.
        try file("gone.txt"); model.rebuild(); try await waitForIdle(model)
        XCTAssertEqual(model.rows.map(\.original), ["a.txt"])
    }

    // Bug 1: unreadable folders are summarized and never leave rows looking pending.
    @MainActor func testUnreadableFoldersAreSummarized() async throws {
        let clips = root.appendingPathComponent("clips")
        try file("a.txt", in: clips); try file("b.txt", in: clips.appendingPathComponent("locked"))
        chmod(clips.appendingPathComponent("locked").path, 0)
        let model = makeModel(journalURL)
        model.recursive = true; model.operation.text = "X"
        model.add([clips]); try await waitForIdle(model)
        XCTAssertEqual(model.rows.map(\.original), ["a.txt"])
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(pendingRows(model), model.pendingCount)
        XCTAssertTrue(model.message.hasPrefix("1 item couldn't be read."), model.message)
    }

    // Bug 2: one bad row never blocks the rest, and shows its own problem.
    @MainActor func testOneBadRowDoesNotBlockTheRest() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        try file("aX.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a), url(b)]); try await waitForIdle(model)
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(model.rows.first { $0.original == "a.txt" }?.status, "An item named “aX.txt” already exists.")
        XCTAssertEqual(pendingRows(model), 1)
        XCTAssertEqual(model.message, "1 change ready. 1 has a problem.")
        model.apply(); try await waitForIdle(model)
        XCTAssertTrue(exists(root.appendingPathComponent("bX.txt").path))
        XCTAssertTrue(exists(a))
        XCTAssertEqual(try String(contentsOfFile: root.appendingPathComponent("aX.txt").path, encoding: .utf8), "aX.txt")
    }

    // Bug 3: a failure that renamed nothing never promises undo.
    @MainActor func testFailureThatRenamedNothingDoesNotPromiseUndo() async throws {
        let a = try file("a.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a)]); try await waitForIdle(model)
        XCTAssertEqual(model.pendingCount, 1)
        // Replace the entry after preview: the engine refuses it before renaming anything.
        try FileManager.default.removeItem(atPath: a); try file("a.txt", contents: "replacement")
        model.apply(); try await waitForIdle(model)
        XCTAssertTrue(model.message.hasPrefix("Stopped: "), model.message)
        XCTAssertFalse(model.message.localizedCaseInsensitiveContains("undo"), model.message)
        XCTAssertFalse(model.message.contains("Renamed 0"), model.message)
        XCTAssertFalse(model.undoAvailable)
    }

    // Bug 4: undo remaps rows, exclusions, and roots instead of clearing the list.
    @MainActor func testUndoKeepsUnrelatedRowsAndExclusions() async throws {
        let folder = root.appendingPathComponent("clips")
        try file("c.txt", in: folder); try file("d.txt", in: folder)
        let b = try file("b.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([folder]); try await waitForIdle(model)
        model.apply(); try await waitForIdle(model)
        XCTAssertEqual(Set(model.rows.map(\.entry.name)), ["cX.txt", "dX.txt"])
        model.selection = Set(model.rows.filter { $0.entry.name == "dX.txt" }.map(\.id)); model.removeSelected()
        model.add([url(b)]); try await waitForIdle(model)
        model.undo(); try await waitForIdle(model)
        XCTAssertTrue(exists(folder.appendingPathComponent("c.txt").path))
        XCTAssertEqual(Set(model.rows.map(\.entry.name)), ["c.txt", "b.txt"])
        XCTAssertTrue(model.rows.allSatisfy { !$0.done })
        XCTAssertEqual(model.pendingCount, 2)
    }

    // Bug 5: progress messages for rename and undo.
    @MainActor func testProgressMessagesForRenameAndUndo() async throws {
        let paths = try (0..<3).map { try file("clip\($0).txt") }
        let model = makeModel(journalURL)
        var seen: [String] = []
        let subscription = model.$message.sink { seen.append($0) }
        defer { subscription.cancel() }
        model.operation.text = "X"
        model.add(paths.map(url)); try await waitForIdle(model)
        model.apply(); try await waitForIdle(model)
        XCTAssertTrue(seen.contains { $0.hasPrefix("Renaming ") && $0.hasSuffix(" of 3") }, "\(seen)")
        model.undo(); try await waitForIdle(model)
        XCTAssertTrue(seen.contains { $0.hasPrefix("Undoing ") && $0.hasSuffix(" of 3") }, "\(seen)")
    }

    // Bug 14: duplicate row keys must not trap during rebuild.
    @MainActor func testRebuildToleratesDuplicateRowKeys() async throws {
        let a = try file("a.txt")
        let model = makeModel(journalURL)
        model.add([url(a)]); try await waitForIdle(model)
        model.rows.append(model.rows[0])
        model.rebuild(); try await waitForIdle(model)
        XCTAssertEqual(model.rows.count, 1)
    }

    // Bug 15: singular wording.
    @MainActor func testSingularMessages() async throws {
        let a = try file("a.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a)]); try await waitForIdle(model)
        XCTAssertEqual(model.message, "1 change ready. No files are overwritten.")
        model.apply(); try await waitForIdle(model)
        XCTAssertEqual(model.message, "Renamed 1 file.")
    }

    // MARK: Review findings

    // R3: completed rows stay done after the engine prunes their batch from history.
    @MainActor func testCompletedRowsStayDoneAfterHistoryIsPruned() async throws {
        let model = makeModel(journalURL)
        model.operation.text = "X"
        for i in 0...Engine.maxBatches {
            model.add([url(try file("f\(i).txt"))]); try await waitForIdle(model)
            model.apply(); try await waitForIdle(model)
        }
        XCTAssertEqual(model.history.count, Engine.maxBatches)
        model.operation.text = "Y"; model.rebuild(); try await waitForIdle(model)
        XCTAssertEqual(model.rows.first { $0.entry.name == "f0X.txt" }?.done, true)
        XCTAssertEqual(model.pendingCount, 0)
        model.apply(); try await waitForIdle(model)
        XCTAssertTrue(exists(root.appendingPathComponent("f0X.txt").path))
        XCTAssertFalse(exists(root.appendingPathComponent("f0XY.txt").path))
    }

    // R1: a resolved planner problem clears even when the proposed name is unchanged.
    @MainActor func testResolvedProblemClearsWhileProposalIsUnchanged() async throws {
        let a = try file("a.txt"), blocker = try file("aX.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a)]); try await waitForIdle(model)
        XCTAssertNotNil(model.rows[0].problem)
        try FileManager.default.removeItem(atPath: blocker)
        model.setType("zzz", enabled: false); try await waitForIdle(model)
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertNil(model.rows[0].problem)
        XCTAssertEqual(model.rows[0].status, "Pending")
    }

    // R2: committing the inline editor without changes never detaches or freezes a companion.
    @MainActor func testEditorClosesWhenItsRowIsRemoved() async throws {
        let a = try file("a.txt"); try file("b.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a), url((a as NSString).deletingLastPathComponent + "/b.txt")]); try await waitForIdle(model)
        let coordinator = PreviewTable.Coordinator(model)
        let table = PreviewTable.makeScroll(coordinator: coordinator).documentView as! PreviewNativeTable
        PreviewTable.sync(table, coordinator: coordinator, model: model)
        let index = model.visibleRows.firstIndex { $0.original == "a.txt" }!
        coordinator.beginEditing(row: index, in: table)
        XCTAssertTrue(model.inlineEditing)
        model.selection = [model.visibleRows[index].id]; model.removeSelected()
        PreviewTable.sync(table, coordinator: coordinator, model: model)
        XCTAssertNil(coordinator.editor, "The editor must close when its row leaves the list")
        XCTAssertFalse(model.inlineEditing, "Rename must not stay disabled by a closed editor")
        try await waitForIdle(model)
        XCTAssertTrue(model.canRename)
    }

    @MainActor func testUnchangedInlineCommitsKeepCompanionsFollowing() async throws {
        let front = try file("2026_1024_222430_004409F.MP4")
        try file("2026_1024_222430_004409R.MP4")
        let model = makeModel(journalURL)
        model.companions = true; try await waitForIdle(model)
        model.operation.text = ", T340"
        model.add([url(front)]); try await waitForIdle(model)
        let coordinator = PreviewTable.Coordinator(model)
        let table = PreviewTable.makeScroll(coordinator: coordinator).documentView as! PreviewNativeTable
        PreviewTable.sync(table, coordinator: coordinator, model: model)
        let rearIndex = { model.visibleRows.firstIndex { $0.original.hasSuffix("R.MP4") }! }
        let rear = { model.rows.first { $0.original.hasSuffix("R.MP4") }! }
        let frontID = model.rows.first { $0.original.hasSuffix("F.MP4") }!.id
        // An unchanged commit on the rear clip before the front clip is edited.
        coordinator.beginEditing(row: rearIndex(), in: table); coordinator.endEditing(commit: true)
        model.setOverride(frontID, to: "2026_1024_222430_004409F night, T340.MP4"); try await waitForIdle(model)
        XCTAssertEqual(rear().proposed, "2026_1024_222430_004409R night, T340.MP4")
        // An unchanged commit on the derived rear name keeps it derived, so a revert carries over.
        coordinator.beginEditing(row: rearIndex(), in: table); coordinator.endEditing(commit: true)
        model.useAutomaticName([frontID]); try await waitForIdle(model)
        XCTAssertEqual(rear().proposed, "2026_1024_222430_004409R, T340.MP4")
        XCTAssertFalse(rear().manual)
        // Setting a row that follows nothing to its automatic name does not detach it.
        model.setOverride(rear().id, to: rear().automatic); try await waitForIdle(model)
        model.setOverride(frontID, to: "2026_1024_222430_004409F rain, T340.MP4"); try await waitForIdle(model)
        XCTAssertEqual(rear().proposed, "2026_1024_222430_004409R rain, T340.MP4")
    }

    // Rename is unavailable (button and Cmd+Return) while the inline editor is open.
    @MainActor func testRenameIsUnavailableWhileInlineEditorIsOpen() async throws {
        let a = try file("a.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a)]); try await waitForIdle(model)
        XCTAssertTrue(model.canRename)
        let coordinator = PreviewTable.Coordinator(model)
        let table = PreviewTable.makeScroll(coordinator: coordinator).documentView as! PreviewNativeTable
        PreviewTable.sync(table, coordinator: coordinator, model: model)
        coordinator.beginEditing(row: 0, in: table)
        XCTAssertTrue(model.inlineEditing)
        XCTAssertFalse(model.canRename)
        model.apply()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(exists(a))
        coordinator.endEditing(commit: false)
        XCTAssertFalse(model.inlineEditing)
        XCTAssertTrue(model.canRename)
        // Clearing the list while the editor is open never leaves Rename waiting.
        coordinator.beginEditing(row: 0, in: table)
        model.clear()
        XCTAssertFalse(model.inlineEditing)
    }

    // R4: inline edits during a scan are kept; locked operations end the editor.
    @MainActor func testInlineEditDuringScanIsKept() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a)]); try await waitForIdle(model)
        let id = model.rows[0].id
        model.add([url(b)]); XCTAssertEqual(model.state, .scanning)
        model.setOverride(id, to: "a edited.txt"); try await waitForIdle(model)
        XCTAssertEqual(model.rows.first { $0.id == id }?.proposed, "a edited.txt")
        model.rebuild(); XCTAssertEqual(model.state, .scanning)
        model.useAutomaticName([id]); try await waitForIdle(model)
        XCTAssertEqual(model.rows.first { $0.id == id }?.proposed, "aX.txt")
        // Still refused while installing, and an open editor closes.
        let coordinator = PreviewTable.Coordinator(model)
        let table = PreviewTable.makeScroll(coordinator: coordinator).documentView as! PreviewNativeTable
        PreviewTable.sync(table, coordinator: coordinator, model: model)
        coordinator.beginEditing(row: 0, in: table)
        XCTAssertNotNil(coordinator.editor)
        XCTAssertTrue(model.beginInstallation())
        model.setOverride(id, to: "nope.txt")
        PreviewTable.sync(table, coordinator: coordinator, model: model)
        XCTAssertNil(coordinator.editor)
        XCTAssertFalse(model.inlineEditing)
        model.endInstallation(); try await waitForIdle(model)
        XCTAssertEqual(model.rows.first { $0.id == id }?.proposed, "aX.txt")
    }

    // Drop notes queued during a rename or undo survive the operation's outcome.
    @MainActor func testDropNotesDuringRenameAndUndoAreKept() async throws {
        let a = try file("a.txt"), b = try file("b.txt"), c = try file("c.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a)]); try await waitForIdle(model)
        model.apply(); XCTAssertEqual(model.state, .applying)
        model.receiveDrop([url(b), nil]); try await waitForIdle(model)
        XCTAssertTrue(model.message.contains("1 dropped item was skipped"), model.message)
        model.undo(); XCTAssertEqual(model.state, .undoing)
        model.receiveDrop([url(c), nil]); try await waitForIdle(model)
        XCTAssertTrue(model.message.contains("1 dropped item was skipped"), model.message)
        model.apply(); XCTAssertEqual(model.state, .applying)
        model.receiveDrop([nil]); try await waitForIdle(model)
        XCTAssertTrue(model.message.contains("1 dropped item was skipped"), model.message)
    }

    // One unreadable preset never drops the others, and unknown entries are kept.
    @MainActor func testOneUnreadablePresetKeepsTheRest() async throws {
        let defaults = scratchDefaults()
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preset(name: "Good", operation: operation(" ok"))))
        var bad = try XCTUnwrap(good as? [String: Any]); bad["name"] = "Future"; bad["action"] = "teleport"
        defaults.set(try JSONSerialization.data(withJSONObject: [good, bad]), forKey: "Presets")
        let model = makeModel(journalURL, defaults: defaults)
        XCTAssertEqual(model.presets.map(\.name), ["Good"])
        model.savePreset(named: "New")
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "Presets"))) as? [[String: Any]])
        XCTAssertEqual(stored.map { $0["name"] as? String }, ["Good", "New", "Future"])
        XCTAssertEqual(stored.last?["action"] as? String, "teleport")
        XCTAssertEqual(SettingsStore(defaults: defaults).presets.map(\.name), ["Good", "New"])
        // Stored data that is not a list at all is set aside, not overwritten.
        defaults.set(Data("not json".utf8), forKey: "Presets")
        let fresh = makeModel(journalURL.deletingLastPathComponent().appendingPathComponent("other/undo.json"), defaults: defaults)
        XCTAssertTrue(fresh.presets.isEmpty)
        fresh.savePreset(named: "Fresh")
        XCTAssertEqual(defaults.data(forKey: "PresetsUnreadable"), Data("not json".utf8))
        XCTAssertEqual(SettingsStore(defaults: defaults).presets.map(\.name), ["Fresh"])
    }

    // Cmd+Z never undoes a batch without confirmation while a sheet is open.
    func testUndoRoutingWithSheetOpen() {
        XCTAssertEqual(UndoRouting.undo(editingText: false, sheetOpen: true, batchAvailable: true, locked: false), .text)
        XCTAssertEqual(UndoRouting.undo(editingText: false, sheetOpen: false, batchAvailable: true, locked: false), .batch)
    }

    // Start at is clamped in the field and when presets are applied.
    @MainActor func testSequenceStartIsClamped() async throws {
        XCTAssertEqual(Preset.clampedStart(-5), 0)
        XCTAssertEqual(Preset.clampedStart(42), 42)
        XCTAssertEqual(Preset.clampedStart(5_000_000), 999_999)
        var preset = Preset(name: "Big", operation: operation(" {#}"))
        preset.sequenceStart = 5_000_000
        let model = makeModel(journalURL)
        model.applyPreset(preset)
        XCTAssertEqual(model.operation.sequenceStart, 999_999)
        preset.sequenceStart = -3
        model.applyPreset(preset)
        XCTAssertEqual(model.operation.sequenceStart, 0)
    }
}
#endif
