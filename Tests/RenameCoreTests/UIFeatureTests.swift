#if DIRECT_UI_TESTS
import XCTest
import AppKit
import Foundation
import RenameCore

/// Model-level behavior for the app layer: state, validation, drops, presets, filters, edits, tokens, and history.
final class UIFeatureTests: ScratchTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: Bug 3: cancel

    @MainActor func testCancelReportsProgressAndOnlyShowsWhileApplying() async throws {
        let paths = try (0..<10).map { try file(String(format: "clip%02d.txt", $0)) }
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add(paths.map(url)); try await waitForIdle(model)
        XCTAssertFalse(model.canCancel)
        var moves = 0
        model.beforeMoveForTesting = { _ in
            moves += 1
            if moves == 4 { DispatchQueue.main.sync { MainActor.assumeIsolated { XCTAssertTrue(model.canCancel); model.cancel() } } }
        }
        model.apply()
        XCTAssertEqual(model.state, .applying)
        try await waitForIdle(model)
        XCTAssertFalse(model.canCancel)
        XCTAssertEqual(model.message, "Cancelled after 4 of 10. Undo is available.")
        XCTAssertEqual(model.pendingCount, 6)
    }

    @MainActor func testCancelBeforeAnythingRenamedDoesNotMentionUndo() async throws {
        let a = try file("a.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a)]); try await waitForIdle(model)
        model.beforeMoveForTesting = { _ in DispatchQueue.main.sync { MainActor.assumeIsolated { model.cancel() } }; throw RenameError("Cancelled by test") }
        model.apply(); try await waitForIdle(model)
        XCTAssertFalse(model.message.localizedCaseInsensitiveContains("undo"), model.message)
        XCTAssertTrue(exists(a))
    }

    // MARK: Bug 5: progress wording

    func testProgressWordingGroupsThousands() {
        XCTAssertEqual(ModelText.progress(undoing: false, done: 412, total: 1000), "Renaming 412 of 1,000")
        XCTAssertEqual(ModelText.progress(undoing: true, done: 12, total: 40), "Undoing 12 of 40")
    }

    // MARK: Bug 6: explicit state and quitting

    @MainActor func testOperationStateAndQuitDecisions() async throws {
        let paths = try (0..<3).map { try file("q\($0).txt") }
        let model = makeModel(journalURL)
        XCTAssertEqual(model.state, .idle); XCTAssertFalse(model.busy)
        model.operation.text = "X"
        model.add(paths.map(url))
        XCTAssertEqual(model.state, .scanning); XCTAssertTrue(model.busy)
        XCTAssertEqual(model.requestQuit {}, .now)
        try await waitForIdle(model)
        var ready = 0
        model.beforeMoveForTesting = { item in
            if item.entry.name == "q0.txt" {
                DispatchQueue.main.sync { MainActor.assumeIsolated {
                    XCTAssertEqual(model.requestQuit { ready += 1 }, .later)
                    XCTAssertFalse(model.message.isEmpty)
                } }
            }
        }
        model.apply(); try await waitForIdle(model)
        XCTAssertEqual(ready, 1)
        XCTAssertTrue(model.message.hasPrefix("Cancelled after"), model.message)
        XCTAssertTrue(model.beginInstallation())
        XCTAssertEqual(model.state, .installing); XCTAssertFalse(model.busy)
        XCTAssertEqual(model.requestQuit {}, .now)
        model.endInstallation()
        XCTAssertEqual(model.state, .idle)
    }

    // MARK: Bug 7: validation off the main thread

    @MainActor func testValidationIsAsynchronousAndDiscardsStaleGenerations() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        try file("aY.txt")
        let model = makeModel(journalURL)
        var threads: [Bool] = []
        model.beforeValidationForTesting = { threads.append(Thread.isMainThread) }
        model.operation.text = "X"
        model.add([url(a), url(b)]); try await waitForIdle(model)
        XCTAssertTrue(model.canRename)
        model.operation.text = "Q"
        XCTAssertFalse(model.canRename, "Rename waits for the current generation to validate")
        XCTAssertFalse(model.isIdle)
        model.operation.text = "Y"
        try await waitForIdle(model)
        XCTAssertTrue(model.canRename)
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(model.rows.first { $0.original == "a.txt" }?.status, "An item named “aY.txt” already exists.")
        XCTAssertFalse(threads.isEmpty); XCTAssertFalse(threads.contains(true))
        // Debounce: the intermediate "Q" generation was never validated.
        XCTAssertEqual(threads.count, 2)
    }

    // MARK: Bug 8: cold-launch opens

    @MainActor func testOpenRequestsBufferUntilModelExists() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        var requests = OpenRequests()
        requests.receive([url(a)], model: nil)
        requests.receive([url(b)], model: nil)
        XCTAssertEqual(requests.pending.map(\.path), [a, b])
        let model = makeModel(journalURL)
        requests.attach(model)
        XCTAssertTrue(requests.pending.isEmpty)
        try await waitForIdle(model)
        XCTAssertEqual(Set(model.rows.map(\.original)), ["a.txt", "b.txt"])
        requests.receive([url(a)], model: model)
        XCTAssertTrue(requests.pending.isEmpty)
    }

    // MARK: Bug 9: drops

    @MainActor func testDropsCountItemsThatAreNotFilesAndSkipEmptyRescans() async throws {
        let a = try file("a.txt")
        let model = makeModel(journalURL)
        model.receiveDrop([nil, URL(string: "https://example.com/photo.jpg")!])
        XCTAssertEqual(model.state, .idle, "An empty drop must not start a rescan")
        XCTAssertEqual(model.message, "2 dropped items were skipped because they aren't files on disk.")
        model.receiveDrop([url(a), nil])
        XCTAssertEqual(model.state, .scanning)
        try await waitForIdle(model)
        XCTAssertEqual(model.rows.map(\.original), ["a.txt"])
        XCTAssertTrue(model.message.hasPrefix("1 dropped item was skipped because it isn't a file on disk."), model.message)
    }

    // MARK: Bug 15: plural titles and display labels

    @MainActor func testRenameTitleAndDisplayLabels() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a)]); try await waitForIdle(model)
        XCTAssertEqual(model.renameTitle, "Rename 1 Item")
        model.add([url(b)]); try await waitForIdle(model)
        XCTAssertEqual(model.renameTitle, "Rename 2 Items")
        XCTAssertEqual(Action.append.label, "Add text to end")
        XCTAssertEqual(Occurrences.first.label, "First occurrence")
        XCTAssertEqual(ModelText.renamed(files: 1, folders: 0), "Renamed 1 file.")
        XCTAssertEqual(ModelText.renamed(files: 2, folders: 1), "Renamed 2 files and 1 folder.")
    }

    // MARK: Feature 1: recent text and presets

    @MainActor func testRecentTextsArePersistedDistinctAndCapped() async throws {
        let defaults = scratchDefaults()
        var model = makeModel(journalURL, defaults: defaults)
        for i in 0..<12 {
            let path = try file("r\(i).txt")
            model.clear(); model.operation.text = " t\(i % 11)"
            model.add([url(path)]); try await waitForIdle(model)
            model.apply(); try await waitForIdle(model)
        }
        XCTAssertEqual(model.recentTexts.count, 10)
        XCTAssertEqual(model.recentTexts.first, " t0")
        XCTAssertEqual(Set(model.recentTexts).count, 10)
        model = makeModel(journalURL.deletingLastPathComponent().appendingPathComponent("other/undo.json"), defaults: defaults)
        XCTAssertEqual(model.recentTexts.first, " t0")
        model.useRecent(" t5")
        XCTAssertEqual(model.operation.text, " t5")
    }

    @MainActor func testPresetsSaveApplyAndDelete() async throws {
        let defaults = scratchDefaults()
        var model = makeModel(journalURL, defaults: defaults)
        model.operation.action = .replace; model.operation.scope = .full
        model.operation.search = "F"; model.operation.text = "R"
        model.operation.ignoreCase = true; model.operation.occurrences = .first
        model.operation.skipExistingSuffix = false; model.operation.sequenceStart = 7
        let saved = model.operation
        model.savePreset(named: "Swap")
        model.operation = RenameOperation()
        model = makeModel(journalURL.deletingLastPathComponent().appendingPathComponent("other/undo.json"), defaults: defaults)
        XCTAssertEqual(model.presets.map(\.name), ["Swap"])
        model.applyPreset(model.presets[0])
        XCTAssertEqual(model.operation, saved)
        model.savePreset(named: "Swap") // Same name replaces.
        XCTAssertEqual(model.presets.count, 1)
        model.deletePreset(named: "Swap")
        XCTAssertTrue(model.presets.isEmpty)
        XCTAssertTrue(makeModel(journalURL.deletingLastPathComponent().appendingPathComponent("third/undo.json"), defaults: defaults).presets.isEmpty)
    }

    // MARK: Feature 2: companion files

    @MainActor func testCompanionToggleIsPersistedAndAddsSidecars() async throws {
        let defaults = scratchDefaults()
        let front = try file("2026_1024_222430_004409F.MP4")
        try file("2026_1024_222430_004409R.MP4"); try file("2026_1024_222430_004409F.LRV"); try file("other.MP4")
        var model = makeModel(journalURL, defaults: defaults)
        XCTAssertFalse(model.companions)
        model.add([url(front)]); try await waitForIdle(model)
        XCTAssertEqual(model.rows.count, 1)
        model.companions = true; try await waitForIdle(model)
        XCTAssertEqual(Set(model.rows.map(\.original)), ["2026_1024_222430_004409F.MP4", "2026_1024_222430_004409R.MP4", "2026_1024_222430_004409F.LRV"])
        model = makeModel(journalURL.deletingLastPathComponent().appendingPathComponent("other/undo.json"), defaults: defaults)
        XCTAssertTrue(model.companions)
    }

    // MARK: Feature 3: type filter

    @MainActor func testTypeFilterHidesFilesKeepsFoldersAndCompanions() async throws {
        let folder = root.appendingPathComponent("clips")
        let sub = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let paths = try ["2026_1024_222430_004409F.MP4", "2026_1024_222430_004409F.LRV", "2026_1024_222500_004410F.LRV", "notes.txt"].map { try file($0, in: folder) }
        let model = makeModel(journalURL)
        model.folders = true; try await waitForIdle(model)
        model.operation.text = "X"
        model.add(paths.map(url) + [sub]); try await waitForIdle(model)
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertEqual(model.typeCounts.map(\.type), ["lrv", "mp4", "txt"])
        XCTAssertEqual(model.typeCounts.map(\.count), [2, 1, 1])
        XCTAssertEqual(model.headerSummary, "5 items")
        model.setType("lrv", enabled: false); try await waitForIdle(model)
        XCTAssertEqual(Set(model.visibleRows.map(\.original)), ["2026_1024_222430_004409F.MP4", "notes.txt", "sub"])
        XCTAssertEqual(model.headerSummary, "Showing 3 of 5 items")
        XCTAssertEqual(model.pendingCount, 3)
        model.companions = true; try await waitForIdle(model)
        XCTAssertEqual(Set(model.visibleRows.map(\.original)), ["2026_1024_222430_004409F.MP4", "2026_1024_222430_004409F.LRV", "notes.txt", "sub"])
        model.setType("mp4", enabled: false); model.setType("txt", enabled: false); try await waitForIdle(model)
        XCTAssertEqual(model.visibleRows.map(\.original), ["sub"])
        model.apply(); try await waitForIdle(model)
        XCTAssertTrue(exists(paths[3]), "Filtered-out rows are not renamed")
        XCTAssertTrue(exists(folder.appendingPathComponent("subX").path))
        model.clear()
        XCTAssertTrue(model.disabledTypes.isEmpty)
        model.setType("txt", enabled: false); model.showAllTypes()
        XCTAssertTrue(model.disabledTypes.isEmpty)
    }

    // MARK: Feature 5: per-row edits

    @MainActor func testOverrideSurvivesChangesValidatesAndClearsAfterRename() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        try file("taken.txt")
        let model = makeModel(journalURL)
        model.operation.text = "X"
        model.add([url(a), url(b)]); try await waitForIdle(model)
        let id = model.rows.first { $0.original == "a.txt" }!.id
        model.setOverride(id, to: "a described.txt"); try await waitForIdle(model)
        var row = model.rows.first { $0.id == id }!
        XCTAssertEqual(row.proposed, "a described.txt"); XCTAssertTrue(row.manual)
        XCTAssertEqual(row.status, "Edited")
        XCTAssertEqual(row.preview?.replacements, [NSRange(location: 1, length: 10)])
        XCTAssertEqual(row.preview?.sourceMatches, [NSRange(location: 1, length: 0)])
        model.operation.text = "Z"; model.rebuild(); try await waitForIdle(model)
        XCTAssertEqual(model.rows.first { $0.id == id }?.proposed, "a described.txt")
        // Empty or equal to automatic reverts.
        model.setOverride(id, to: ""); try await waitForIdle(model)
        XCTAssertEqual(model.rows.first { $0.id == id }?.proposed, "aZ.txt")
        model.setOverride(id, to: "aZ.txt"); try await waitForIdle(model)
        XCTAssertFalse(model.rows.first { $0.id == id }!.manual)
        // Overrides are validated like any proposal.
        model.setOverride(id, to: "taken.txt"); try await waitForIdle(model)
        XCTAssertEqual(model.rows.first { $0.id == id }?.status, "An item named “taken.txt” already exists.")
        model.useAutomaticName([id]); try await waitForIdle(model)
        XCTAssertEqual(model.rows.first { $0.id == id }?.proposed, "aZ.txt")
        model.setOverride(id, to: "a final.txt"); try await waitForIdle(model)
        model.apply(); try await waitForIdle(model)
        XCTAssertTrue(exists(root.appendingPathComponent("a final.txt").path))
        XCTAssertTrue(exists(root.appendingPathComponent("bZ.txt").path))
        row = model.rows.first { $0.id == id }!
        XCTAssertTrue(row.done)
        XCTAssertTrue(model.overrides.isEmpty, "Overrides clear once the row is renamed")
        model.clear()
        XCTAssertTrue(model.overrides.isEmpty)
    }

    @MainActor func testEditPropagatesToCompanionClips() async throws {
        let front = try file("2026_1024_222430_004409F.MP4")
        try file("2026_1024_222430_004409R.MP4"); try file("2026_1024_222430_004409F.LRV")
        try file("2026_1024_222430_004409I.MP4")
        let model = makeModel(journalURL)
        model.companions = true; try await waitForIdle(model)
        model.operation.text = ", T340"
        model.add([url(front)]); try await waitForIdle(model)
        XCTAssertEqual(model.rows.count, 4)
        let interior = model.rows.first { $0.original.hasSuffix("I.MP4") }!.id
        model.setOverride(interior, to: "2026_1024_222430_004409I cabin, T340.MP4")
        let id = model.rows.first { $0.original == "2026_1024_222430_004409F.MP4" }!.id
        model.setOverride(id, to: "2026_1024_222430_004409F Pedestrians crossing at night in Seattle, T340.MP4")
        XCTAssertEqual(model.message, "Also applied to 2 companion files.")
        try await waitForIdle(model)
        let names = Set(model.rows.map(\.proposed))
        XCTAssertTrue(names.contains("2026_1024_222430_004409R Pedestrians crossing at night in Seattle, T340.MP4"))
        XCTAssertTrue(names.contains("2026_1024_222430_004409F Pedestrians crossing at night in Seattle, T340.LRV"))
        XCTAssertTrue(names.contains("2026_1024_222430_004409I cabin, T340.MP4"), "A companion with its own edit keeps it")
        // A changed extension does not propagate.
        model.setOverride(id, to: "2026_1024_222430_004409F other.mov"); try await waitForIdle(model)
        XCTAssertNotEqual(model.message, "Also applied to 2 companion files.")
        XCTAssertEqual(CompanionEdit.propagate(automatic: "a.MP4", edited: "b.mov", companion: "c.LRV"), nil)
        XCTAssertEqual(CompanionEdit.propagate(automatic: "abcF, T.MP4", edited: "abcF go, T.MP4", companion: "abcR, T.MP4"), "abcR go, T.MP4")
        XCTAssertEqual(CompanionEdit.propagate(automatic: "abcF, T.MP4", edited: "abcF go, T.MP4", companion: "abcRR, T.MP4"), nil)
    }

    @MainActor func testCompanionEditsFollowToggleAndSourceChanges() async throws {
        let front = try file("2026_1024_222430_004409F.MP4")
        try file("2026_1024_222430_004409R.MP4")
        let model = makeModel(journalURL)
        model.operation.text = ", T340"
        model.folders = false
        model.add([url((front as NSString).deletingLastPathComponent)]); try await waitForIdle(model)
        XCTAssertEqual(model.rows.count, 2)
        let id = model.rows.first { $0.original.hasSuffix("F.MP4") }!.id
        let rear = { model.rows.first { $0.original.hasSuffix("R.MP4") }!.proposed }
        // Companion files off: an edit stays on its own row.
        XCTAssertFalse(model.companions)
        model.setOverride(id, to: "2026_1024_222430_004409F night, T340.MP4"); try await waitForIdle(model)
        XCTAssertEqual(rear(), "2026_1024_222430_004409R, T340.MP4")
        // Turning companion files on makes the rear clip follow the front edit.
        model.companions = true; try await waitForIdle(model)
        XCTAssertEqual(rear(), "2026_1024_222430_004409R night, T340.MP4")
        // Changing the front edit carries over; reverting it reverts the rear clip too.
        model.setOverride(id, to: "2026_1024_222430_004409F rain, T340.MP4"); try await waitForIdle(model)
        XCTAssertEqual(rear(), "2026_1024_222430_004409R rain, T340.MP4")
        model.useAutomaticName([id]); try await waitForIdle(model)
        XCTAssertEqual(rear(), "2026_1024_222430_004409R, T340.MP4")
        // Setting a following companion back to automatic detaches it from later edits.
        model.setOverride(id, to: "2026_1024_222430_004409F snow, T340.MP4"); try await waitForIdle(model)
        let rearID = model.rows.first { $0.original.hasSuffix("R.MP4") }!.id
        model.useAutomaticName([rearID]); try await waitForIdle(model)
        XCTAssertEqual(rear(), "2026_1024_222430_004409R, T340.MP4")
        model.setOverride(id, to: "2026_1024_222430_004409F hail, T340.MP4"); try await waitForIdle(model)
        XCTAssertEqual(rear(), "2026_1024_222430_004409R, T340.MP4")
    }

    // MARK: Feature 6: tokens

    @MainActor func testSequenceFollowsDisplayedPendingOrderAndStartAt() async throws {
        let paths = try ["c.txt", "a.txt", "b.txt"].map { try file($0) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: paths[1])
        let model = makeModel(journalURL)
        model.add(paths.map(url)); try await waitForIdle(model)
        XCTAssertFalse(model.hasSequenceToken)
        model.operation.text = " {##}"
        XCTAssertTrue(model.hasSequenceToken)
        model.operation.sequenceStart = 9; try await waitForIdle(model)
        XCTAssertEqual(model.visibleRows.map(\.proposed), ["c 09.txt", "a 10.txt", "b 11.txt"])
        model.operation.text = " {date}"; try await waitForIdle(model)
        let expected = RenameOperation.dated(" {date}", Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(model.rows.first { $0.original == "a.txt" }?.proposed, "a" + expected + ".txt")
    }

    // MARK: Feature 7: shortcuts

    func testUndoRouting() {
        XCTAssertEqual(UndoRouting.undo(editingText: true, batchAvailable: true, locked: false), .text)
        XCTAssertEqual(UndoRouting.undo(editingText: true, batchAvailable: false, locked: true), .text)
        XCTAssertEqual(UndoRouting.undo(editingText: false, batchAvailable: true, locked: false), .batch)
        XCTAssertEqual(UndoRouting.undo(editingText: false, batchAvailable: true, locked: true), .none)
        XCTAssertEqual(UndoRouting.undo(editingText: false, batchAvailable: false, locked: false), .none)
        XCTAssertEqual(UndoRouting.redo(editingText: true), .text)
        XCTAssertEqual(UndoRouting.redo(editingText: false), .none)
    }

    // MARK: Feature 8: history

    @MainActor func testUndoHelpHistoryAndUndoThrough() async throws {
        let a = try file("a.txt"), b = try file("b.txt"), c = try file("c.txt")
        let model = makeModel(journalURL)
        XCTAssertEqual(model.undoHelp, "Nothing to undo")
        model.operation.text = "1"; model.add([url(a)]); try await waitForIdle(model)
        model.apply(); try await waitForIdle(model)
        model.operation.text = "2"; model.add([url(b), url(c)]); try await waitForIdle(model)
        model.apply(); try await waitForIdle(model)
        XCTAssertEqual(model.history.count, 2)
        let time = try XCTUnwrap(model.history[0].date).formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(model.undoHelp, "Undo renaming 2 items from \(time)")
        XCTAssertEqual(model.history[0].count, 2); XCTAssertTrue(model.history[0].applied)
        XCTAssertEqual(ModelText.historyDate(nil), "Earlier")
        let oldest = model.history[1].id
        XCTAssertEqual(model.undoThroughPrompt(oldest), "Undo 2 batches, 3 items?")
        XCTAssertEqual(model.undoThroughPrompt(model.history[0].id), "Undo 1 batch, 2 items?")
        model.add([url(try file("d.txt"))]); try await waitForIdle(model)
        model.undoThrough(oldest); try await waitForIdle(model)
        XCTAssertTrue(exists(a)); XCTAssertTrue(exists(b)); XCTAssertTrue(exists(c))
        XCTAssertEqual(Set(model.rows.map(\.entry.name)), ["a.txt", "b.txt", "c.txt", "d.txt"])
        XCTAssertFalse(model.undoAvailable)
        XCTAssertTrue(model.history.allSatisfy { !$0.applied })
    }
}

extension RenameOperation {
    static func dated(_ text: String, _ date: Date) -> String {
        var op = RenameOperation(); op.text = text
        return op.expandedText(TokenContext(index: 1, modified: date))
    }
}
#endif
