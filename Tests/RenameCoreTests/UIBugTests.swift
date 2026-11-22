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
}
#endif
