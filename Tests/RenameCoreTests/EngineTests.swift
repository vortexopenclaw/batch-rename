import XCTest
@testable import RenameCore

/// Shapes decoded by the previously shipped app (0.1.3). Snapshots must remain readable by it.
private struct LegacyIdentity: Codable { var device: Int32; var inode: UInt64; var birth: Int64; var nanos: Int64; var kind: UInt16; var size: Int64; var modified: Int64; var modifiedNanos: Int64 }
private struct LegacyStep: Codable { var source: String, destination: String; var identity: LegacyIdentity, parent: LegacyIdentity; var batch = UUID(); var done = false; var undone = false }
private struct LegacyJournal: Codable { var version = 1; var steps: [LegacyStep] = []; var undoing = false; var recoveryRequired: String? = nil }

/// Regression tests for the undo engine (audit fixes 1, 8 renames, 9, 10, 12).
final class EngineRegressionTests: ScratchTestCase {
    // Fix 8
    func testFATFamilyRenameUndoAndNeverOverwrite() throws {
        for fs in ["ExFAT", "MS-DOS"] {
            let volume = try diskImage(fs)
            let clip = try file("2026_1024_222430_004409F.MP4", in: volume, contents: "front")
            var e: Engine? = try Engine(journalURL: root.appendingPathComponent("j-\(fs)/undo.json"))
            try e!.apply(Planner.plan([Entry(clip)], operation: operation(", T340")))
            let renamed = volume.appendingPathComponent("2026_1024_222430_004409F, T340.MP4").path
            XCTAssertEqual(try String(contentsOfFile: renamed, encoding: .utf8), "front", fs)
            XCTAssertFalse(exists(clip), fs)
            e = nil
            e = try Engine(journalURL: root.appendingPathComponent("j-\(fs)/undo.json"))
            try e!.undo()
            XCTAssertEqual(try String(contentsOfFile: clip, encoding: .utf8), "front", fs)
            XCTAssertFalse(e!.canUndo, fs)
            // Folder rename and undo use an empty directory reservation.
            try FileManager.default.createDirectory(at: volume.appendingPathComponent("Trip"), withIntermediateDirectories: false)
            try file("Trip/inside.MP4", in: volume)
            try e!.apply(Planner.plan([Entry(volume.appendingPathComponent("Trip").path)], operation: operation(" 2026")))
            XCTAssertTrue(exists(volume.appendingPathComponent("Trip 2026/inside.MP4").path), fs)
            try e!.undo()
            XCTAssertTrue(exists(volume.appendingPathComponent("Trip/inside.MP4").path), fs)
            // Collision: planner refuses, and a racing destination is never overwritten.
            let a = try file("a.txt", in: volume), _ = try file("aX.txt", in: volume, contents: "existing")
            XCTAssertThrowsError(try Planner.plan([Entry(a)], operation: operation("X")))
            let b = try file("b.txt", in: volume)
            let plan = try Planner.plan([Entry(b)], operation: operation("X"))
            XCTAssertThrowsError(try e!.apply(plan, beforeMove: { item in try Data("intruder".utf8).write(to: URL(fileURLWithPath: item.destination)) }), fs)
            XCTAssertEqual(try String(contentsOfFile: volume.appendingPathComponent("bX.txt").path, encoding: .utf8), "intruder", fs)
            XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "b.txt", fs)
            XCTAssertEqual(try String(contentsOfFile: volume.appendingPathComponent("aX.txt").path, encoding: .utf8), "existing", fs)
            // Case-only rename and undo through the reservation path.
            let c = try file("case.txt", in: volume)
            var op = operation("CASE"); op.action = .replace; op.search = "case"
            try e!.apply(Planner.plan([Entry(c)], operation: op))
            XCTAssertTrue(try names(volume).contains("CASE.txt"), fs)
            XCTAssertFalse(try names(volume).contains { $0.hasPrefix(".batch-rename-") }, fs)
            try e!.undo()
            XCTAssertTrue(try names(volume).contains("case.txt"), fs)
            e = nil
        }
    }
    // Fix 9
    func testHardlinkAliasIsNotACaseHop() throws {
        let a = try file("a")
        let upper = root.appendingPathComponent("B").path
        try FileManager.default.linkItem(atPath: a, toPath: upper)
        guard (try? Identity.read(root.appendingPathComponent("b").path)) != nil else { throw XCTSkip("Requires a case-insensitive scratch filesystem") }
        var op = operation("b"); op.action = .replace; op.search = "a"
        XCTAssertThrowsError(try Planner.plan([Entry(a)], operation: op)) { XCTAssertTrue($0.localizedDescription.contains("exists")) }
        let e = try engine()
        XCTAssertThrowsError(try e.apply([PlanItem(entry: Entry(a), destination: root.appendingPathComponent("b").path)]))
        XCTAssertTrue(exists(a)); XCTAssertTrue(try names().contains("B"))
        XCTAssertFalse(try names().contains { $0.hasPrefix(".batch-rename-") })
        XCTAssertFalse(e.canUndo)
    }
    func testFailedSecondHopRollsBackFirstHop() throws {
        let a = try file("clip.txt")
        var op = operation("CLIP"); op.action = .replace; op.search = "clip"
        let plan = try Planner.plan([Entry(a)], operation: op)
        var e: Engine? = try engine()
        var calls = 0
        e!.beforeRename = { calls += 1; if calls == 2 { throw RenameError("injected hop 2 failure") } }
        XCTAssertThrowsError(try e!.apply(plan))
        XCTAssertTrue(try names().contains("clip.txt"))
        XCTAssertFalse(try names().contains { $0.hasPrefix(".batch-rename-") })
        XCTAssertFalse(e!.canUndo)
        e = nil
        XCTAssertFalse(try engine().canUndo)
    }
    func testReconcileRollsBackStrandedTemporaryHop() throws {
        let a = try file("clip.txt"), entry = try Entry(a)
        let temporary = root.appendingPathComponent(".batch-rename-" + UUID().uuidString).path
        try FileManager.default.moveItem(atPath: a, toPath: temporary)
        let batch = UUID()
        try writeJournal(Journal(steps: [
            Step(source: a, destination: temporary, identity: entry.identity, parent: entry.parent, batch: batch, done: true),
            Step(source: temporary, destination: root.appendingPathComponent("CLIP.txt").path, identity: entry.identity, parent: entry.parent, batch: batch, done: false, undone: true),
        ]))
        let e = try engine()
        XCTAssertTrue(try names().contains("clip.txt"))
        XCTAssertFalse(exists(temporary))
        XCTAssertFalse(e.canUndo)
    }
    // Fix 10
    func testInterruptedRenameThenContentEditReconciles() throws {
        let a = try file("a"), entry = try Entry(a)
        try writeJournal(Journal(steps: [Step(source: a, destination: a + "X", identity: entry.identity, parent: entry.parent)]))
        try FileManager.default.moveItem(atPath: a, toPath: a + "X")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: a + "X"))
        try handle.write(contentsOf: Data("edited after crash".utf8)); try handle.close()
        let e = try engine()
        XCTAssertTrue(e.canUndo)
        XCTAssertThrowsError(try e.undo()) // Full identity still guards undo.
        XCTAssertTrue(exists(a + "X")); XCTAssertFalse(exists(a))
    }
    func testInterruptedUndoThenContentEditReconciles() throws {
        let a = try file("a"), entry = try Entry(a)
        try FileManager.default.moveItem(atPath: a, toPath: a + "X")
        try writeJournal(Journal(steps: [Step(source: a, destination: a + "X", identity: entry.identity, parent: entry.parent, done: true)], undoing: true))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: a + "X"))
        try handle.write(contentsOf: Data("edited".utf8)); try handle.close()
        let e = try engine()
        XCTAssertTrue(e.canUndo)
    }
    func testCompletedPathsScales() throws {
        let seed = try Entry(try file("seed"))
        let batch = UUID()
        try writeJournal(Journal(steps: (0..<20_000).map { Step(source: "/nonexistent/\($0)", destination: "/nonexistent/\($0)X", identity: seed.identity, parent: seed.parent, batch: batch, done: true) }))
        let e = try engine()
        let start = Date()
        let paths = e.completedPaths
        let elapsed = Date().timeIntervalSince(start)
        print("COMPLETED PATHS 20,000 steps: \(elapsed) seconds")
        XCTAssertEqual(paths.count, 20_000)
        XCTAssertLessThan(elapsed, 3)
    }
    // Fix 1
    func testJournalScalesWithFiftyBatchHistory() throws {
        let seed = try Entry(try file("seed"))
        var history: [Step] = []
        for b in 0..<50 {
            let batch = UUID()
            for i in 0..<200 { history.append(Step(source: "/nonexistent/\(b)/\(i)", destination: "/nonexistent/\(b)/\(i)X", identity: seed.identity, parent: seed.parent, batch: batch, done: true)) }
        }
        try writeJournal(Journal(steps: history))
        let dir = root.appendingPathComponent("scale")
        let entries = try (0..<1000).map { try Entry(try file("clip-\($0).mp4", in: dir)) }
        let plan = try Planner.plan(entries, operation: operation(", T340"))
        let e = try engine()
        let start = Date()
        try e.apply(plan)
        let elapsed = Date().timeIntervalSince(start)
        print("JOURNAL apply 1,000 renames with 50-batch (10,000-step) history: \(elapsed) seconds")
        XCTAssertLessThan(elapsed, 60)
        guard elapsed < 60 else { return }
        let undoStart = Date()
        try e.undo()
        print("JOURNAL undo 1,000 renames: \(Date().timeIntervalSince(undoStart)) seconds")
        XCTAssertTrue(exists(entries[999].path))
    }
}

/// Review findings C1, C2, C5 (engine) against real volumes.
final class EngineReviewFindingTests: ScratchTestCase {
    // C1: FAT/exFAT re-derive an empty file's inode from its directory entry on every rename.
    func testEmptyFilesOnFATFamilyAreRefusedWithoutMutation() throws {
        for fs in ["ExFAT", "MS-DOS"] {
            let volume = try diskImage(fs)
            let empty = volume.appendingPathComponent("empty.txt").path
            XCTAssertTrue(FileManager.default.createFile(atPath: empty, contents: Data()), fs)
            let full = try file("full.txt", in: volume)
            let entry = try Entry(empty)
            for name in ["emptyX.txt", "EMPTY.txt"] {
                let result = Planner.plan(proposals: [Proposal(entry: entry, name: name), Proposal(entry: try Entry(full), name: "fullX.txt")])
                XCTAssertEqual(result.problems[empty], "Empty files can't be renamed safely on this disk.", fs)
                XCTAssertEqual(result.items.map(\.entry.path), [full], fs)
            }
            let journal = root.appendingPathComponent("j-empty-\(fs)/undo.json")
            var e: Engine? = try Engine(journalURL: journal)
            for name in ["emptyX.txt", "EMPTY.txt"] {
                // Caller-built plan: the whole call is rejected before any mutation.
                let plan = [PlanItem(entry: try Entry(full), destination: volume.appendingPathComponent("fullX.txt").path),
                            PlanItem(entry: entry, destination: volume.appendingPathComponent(name).path)]
                XCTAssertThrowsError(try e!.apply(plan), fs)
                let listing = try names(volume)
                XCTAssertTrue(listing.contains("empty.txt") && listing.contains("full.txt"), "\(fs) \(listing)")
                XCTAssertFalse(listing.contains { $0 == "emptyX.txt" || $0 == "EMPTY.txt" || $0 == "fullX.txt" || $0.hasPrefix(".batch-rename-") }, "\(fs) \(listing)")
            }
            XCTAssertFalse(e!.canUndo, fs)
            e = nil
            // No recovery classification was journaled.
            e = try Engine(journalURL: journal)
            XCTAssertFalse(e!.canUndo, fs)
            e = nil
        }
    }
    // C2: a stranded case hop whose rollback keeps failing must stay in history.
    func testPruningKeepsStrandedCaseHop() throws {
        let a = try file("clip.txt"), entry = try Entry(a)
        let temporary = root.appendingPathComponent(".batch-rename-" + UUID().uuidString).path
        try FileManager.default.moveItem(atPath: a, toPath: temporary)
        try file("clip.txt", contents: "occupant") // Rollback refuses to overwrite.
        let stranded = UUID()
        var steps = [Step(source: a, destination: temporary, identity: entry.identity, parent: entry.parent, batch: stranded, done: true)]
        for b in 0..<Engine.maxBatches {
            steps.append(Step(source: "/nonexistent/\(b)", destination: "/nonexistent/\(b)X", identity: entry.identity, parent: entry.parent, batch: UUID(), done: true))
        }
        try writeJournal(Journal(steps: steps))
        var e: Engine? = try engine()
        XCTAssertTrue(exists(temporary))
        XCTAssertTrue(e!.steps.contains { $0.batch == stranded && $0.destination == temporary })
        e = nil
        let saved = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        XCTAssertTrue(saved.steps.contains { $0.batch == stranded && $0.destination == temporary })
        XCTAssertEqual(Set(saved.steps.map(\.batch)).count, Engine.maxBatches + 1)
    }
}

final class EngineProgressHistoryTests: ScratchTestCase {
    func testApplyOutcomeProgressAndCancellation() throws {
        let paths = try ["a", "b", "c"].map { try file($0 + ".mp4") }
        let e = try engine()
        var seen: [[Int]] = []
        let outcome = try e.apply(Planner.plan(paths.map { try Entry($0) }, operation: operation("X")), progress: { seen.append([$0, $1]) })
        XCTAssertEqual(outcome, ApplyOutcome(renamed: 3, total: 3, cancelled: false))
        XCTAssertEqual(seen.last, [3, 3]); XCTAssertEqual(seen.filter { $0[0] > 0 }.count, 3)
        var undoSeen: [[Int]] = []
        XCTAssertEqual(try e.undo(progress: { undoSeen.append([$0, $1]) }), ApplyOutcome(renamed: 3, total: 3, cancelled: false))
        XCTAssertEqual(undoSeen.last, [3, 3])
        var done = 0
        let cancelled = try e.apply(Planner.plan(paths.map { try Entry($0) }, operation: operation("X")), cancelled: { done >= 1 }, progress: { n, _ in done = n })
        XCTAssertEqual(cancelled, ApplyOutcome(renamed: 1, total: 3, cancelled: true))
        // A case-only rename is one user item even though it takes two journaled hops.
        let c = try file("case.txt")
        var op = operation("CASE"); op.action = .replace; op.search = "case"
        var hop: [[Int]] = []
        XCTAssertEqual(try e.apply(Planner.plan([Entry(c)], operation: op), progress: { hop.append([$0, $1]) }).renamed, 1)
        XCTAssertEqual(hop.last, [1, 1])
        XCTAssertEqual(e.history.first?.count, 1)
        XCTAssertEqual(e.history.first?.examples.first?.from, "case.txt")
        XCTAssertEqual(e.history.first?.examples.first?.to, "CASE.txt")
    }
    func testHistoryAndUndoThrough() throws {
        let a = try file("a.txt"), b = try file("b.txt"), c = try file("c.txt"), d = try file("d.txt"), f = try file("f.txt")
        let e = try engine()
        try e.apply(Planner.plan([Entry(a)], operation: operation("1")))
        try e.apply(Planner.plan([Entry(b), Entry(c), Entry(d), Entry(f)], operation: operation("2")))
        try e.apply(Planner.plan([Entry(root.appendingPathComponent("a1.txt").path)], operation: operation("3")))
        let history = e.history
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.map(\.count), [1, 4, 1])
        XCTAssertTrue(history.allSatisfy { $0.applied && $0.date != nil })
        XCTAssertEqual(history.first?.examples.map(\.from), ["a1.txt"]); XCTAssertEqual(history.first?.examples.map(\.to), ["a13.txt"])
        guard history.count == 3 else { return }
        XCTAssertEqual(history[1].examples.count, 3)
        XCTAssertEqual(history[1].examples.map(\.to), ["b2.txt", "c2.txt", "d2.txt"])
        XCTAssertGreaterThanOrEqual(history[0].date ?? .distantPast, history[1].date ?? .distantFuture)
        // Reload keeps history.
        let ids = history.map(\.id)
        var undoSeen: [[Int]] = []
        let outcome = try e.undo(through: ids[1], progress: { undoSeen.append([$0, $1]) })
        XCTAssertEqual(outcome, ApplyOutcome(renamed: 5, total: 5, cancelled: false))
        XCTAssertEqual(undoSeen.last, [5, 5])
        XCTAssertTrue(exists(b) && exists(f)); XCTAssertTrue(exists(root.appendingPathComponent("a1.txt").path))
        XCTAssertEqual(e.history.map(\.id), [ids[2]])
        XCTAssertThrowsError(try e.undo(through: UUID()))
    }
    func testUndoThroughStopsAtFirstFailure() throws {
        let a = try file("a.txt"), b = try file("b.txt"), c = try file("c.txt")
        var e: Engine? = try engine()
        for path in [a, b, c] { try e!.apply(Planner.plan([Entry(path)], operation: operation("X"))) }
        let ids = e!.history.map(\.id)
        guard ids.count == 3 else { return XCTFail("history") }
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("bX.txt"))
        try handle.write(contentsOf: Data("edited".utf8)); try handle.close()
        XCTAssertThrowsError(try e!.undo(through: ids[2]))
        XCTAssertTrue(exists(c)); XCTAssertFalse(exists(b)); XCTAssertFalse(exists(a))
        XCTAssertEqual(e!.history.map(\.id), [ids[1], ids[2]])
        e = nil
        XCTAssertEqual(try engine().history.map(\.id), [ids[1], ids[2]])
    }
}

final class JournalLogTests: ScratchTestCase {
    var logURL: URL { URL(fileURLWithPath: journalURL.path + ".log") }
    func writeLog(_ records: [LogRecord], tail: String = "") throws {
        var data = Data()
        for record in [LogRecord.begin(UUID())] + records { data += try JSONEncoder().encode(record); data += Data("\n".utf8) }
        data += Data(tail.utf8)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: logURL)
    }
    func step(_ path: String, _ suffix: String = "X", done: Bool = false) throws -> Step {
        let entry = try Entry(path)
        return Step(source: path, destination: path + suffix, identity: entry.identity, parent: entry.parent, done: done)
    }
    func testCompactionRemovesLogAndStaysReadableByPreviousApp() throws {
        let a = try file("a"), e = try engine()
        try e.apply(Planner.plan([Entry(a)], operation: operation("X")))
        XCTAssertFalse(exists(logURL.path))
        let data = try Data(contentsOf: journalURL)
        let legacy = try JSONDecoder().decode(LegacyJournal.self, from: data)
        XCTAssertEqual(legacy.steps.count, 1); XCTAssertTrue(legacy.steps[0].done)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let step = try XCTUnwrap((raw["steps"] as? [[String: Any]])?.first)
        XCTAssertNotNil(step["id"]); XCTAssertNotNil(step["date"])
        XCTAssertEqual(raw["version"] as? Int, 1)
    }
    func testOldJournalStepsGetIdentifiersAtInit() throws {
        let a = try file("a"), entry = try Entry(a)
        try FileManager.default.moveItem(atPath: a, toPath: a + "X")
        let legacyIdentity = { (i: Identity) in LegacyIdentity(device: i.device, inode: i.inode, birth: i.birth, nanos: i.nanos, kind: i.kind, size: i.size, modified: i.modified, modifiedNanos: i.modifiedNanos) }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(LegacyJournal(steps: [LegacyStep(source: a, destination: a + "X", identity: legacyIdentity(entry.identity), parent: legacyIdentity(entry.parent), done: true)])).write(to: journalURL)
        let e = try engine()
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        XCTAssertNotNil((raw["steps"] as? [[String: Any]])?.first?["id"])
        XCTAssertEqual(e.history.count, 1); XCTAssertNil(e.history.first?.date)
        try e.undo(); XCTAssertTrue(exists(a))
    }
    func testPruningKeepsNewestFiftyAppliedBatches() throws {
        let seed = try Entry(try file("seed"))
        var steps: [Step] = [], batches: [UUID] = []
        for b in 0..<60 {
            let batch = UUID(); batches.append(batch)
            steps.append(Step(source: "/nonexistent/\(b)", destination: "/nonexistent/\(b)X", identity: seed.identity, parent: seed.parent, batch: batch, done: true, undone: b % 7 == 3))
        }
        try writeJournal(Journal(steps: steps))
        let e = try engine()
        XCTAssertEqual(Engine.maxBatches, 50)
        let kept = batches.enumerated().filter { $0.offset % 7 != 3 }.map(\.element).suffix(50)
        XCTAssertEqual(e.history.map(\.id), Array(kept.reversed()))
        XCTAssertEqual(try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)).steps.count, 50)
    }
    func testCrashWithIntentOnly() throws {
        let a = try file("a"), s = try step(a)
        try writeJournal(Journal()); try writeLog([.intent(s)])
        var e: Engine? = try engine()
        XCTAssertFalse(e!.canUndo); XCTAssertTrue(exists(a)); XCTAssertFalse(exists(logURL.path))
        e = nil
        // The rename itself happened before the crash.
        try writeLog([.intent(s)])
        try FileManager.default.moveItem(atPath: a, toPath: a + "X")
        e = try engine()
        XCTAssertTrue(e!.canUndo); try e!.undo(); XCTAssertTrue(exists(a))
    }
    func testCrashAfterDoneAndTornTail() throws {
        let a = try file("a"), s = try step(a)
        try FileManager.default.moveItem(atPath: a, toPath: a + "X")
        try writeJournal(Journal()); try writeLog([.intent(s), .done(s.id)], tail: "{\"undoing\":{\"_0\":tr")
        let e = try engine()
        XCTAssertTrue(e.canUndo); XCTAssertFalse(exists(logURL.path))
        XCTAssertEqual(e.steps.map(\.id), [s.id])
    }
    func testCorruptMiddleRecordFailsClosed() throws {
        let a = try file("a"), s = try step(a)
        try writeJournal(Journal())
        var data = Data()
        for record in [LogRecord.begin(UUID()), .intent(s)] { data += try JSONEncoder().encode(record) + Data("\n".utf8) }
        data += Data("garbage\n".utf8) + (try JSONEncoder().encode(LogRecord.done(s.id))) + Data("\n".utf8)
        try data.write(to: logURL)
        XCTAssertThrowsError(try engine())
        XCTAssertTrue(exists(logURL.path))
    }
    func testReplayIsIdempotentOverCompactedSnapshot() throws {
        let a = try file("a"), s = try step(a, done: true)
        try FileManager.default.moveItem(atPath: a, toPath: a + "X")
        try writeJournal(Journal(steps: [s]))
        var pending = s; pending.done = false
        try writeLog([.intent(pending), .done(s.id), .undoing(true), .undoing(false)])
        let e = try engine()
        XCTAssertEqual(e.steps.count, 1); XCTAssertTrue(e.canUndo)
    }
    // C3: crash after compaction, then 0.1.3 rewrote the snapshot without ids or `merged`.
    func testReplayAfterLegacyRewriteDoesNotDuplicateMergedStep() throws {
        let a = try file("a"), s = try step(a)
        let legacyIdentity = { (i: Identity) in LegacyIdentity(device: i.device, inode: i.inode, birth: i.birth, nanos: i.nanos, kind: i.kind, size: i.size, modified: i.modified, modifiedNanos: i.modifiedNanos) }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(LegacyJournal(steps: [LegacyStep(source: s.source, destination: s.destination, identity: legacyIdentity(s.identity), parent: legacyIdentity(s.parent), batch: s.batch, done: true, undone: true)])).write(to: journalURL)
        try writeLog([.intent(s), .done(s.id)])
        XCTAssertTrue(exists(a)); XCTAssertFalse(exists(a + "X"))
        let e = try engine()
        XCTAssertLessThanOrEqual(e.steps.filter { $0.source == a }.count, 1)
        XCTAssertFalse(e.canUndo)
        XCTAssertFalse(e.history.contains { $0.applied })
        XCTAssertEqual(try e.undo(), ApplyOutcome(renamed: 0, total: 0, cancelled: false))
        XCTAssertTrue(exists(a))
    }
    func testCrashWhileUndoing() throws {
        let a = try file("a"), s = try step(a, done: true)
        try FileManager.default.moveItem(atPath: a, toPath: a + "X")
        try writeJournal(Journal(steps: [s])); try writeLog([.undoing(true)])
        var e: Engine? = try engine()
        XCTAssertTrue(e!.canUndo) // Undo had not moved the file yet.
        e = nil
        try FileManager.default.moveItem(atPath: a + "X", toPath: a)
        try writeLog([.undoing(true)])
        e = try engine()
        XCTAssertFalse(e!.canUndo); XCTAssertTrue(exists(a))
    }
    func testCrashWithReservationRemovesOnlyExactPlaceholder() throws {
        try reservationCrash(base: root.appendingPathComponent("apfs"), label: "APFS")
    }
    func testCrashWithReservationOnFATFamilyVolumes() throws {
        for fs in ["ExFAT", "MS-DOS"] { try reservationCrash(base: try diskImage(fs), label: fs) }
    }
    private func reservationCrash(base: URL, label: String) throws {
        // Forward rename: source intact, destination is our empty placeholder.
        let a = try file("a-\(UUID().uuidString.prefix(4))", in: base), s = try step(a)
        FileManager.default.createFile(atPath: a + "X", contents: nil)
        try writeJournal(Journal()); try writeLog([.intent(s), .reserved(s.id, try Identity.read(a + "X"))])
        var e: Engine? = try engine()
        XCTAssertTrue(exists(a), label); XCTAssertFalse(exists(a + "X"), label); XCTAssertFalse(e!.canUndo, label)
        e = nil
        // Folder rename: empty directory placeholder.
        let folder = base.appendingPathComponent("Trip-\(UUID().uuidString.prefix(4))").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let fs = try step(folder)
        try FileManager.default.createDirectory(atPath: folder + "X", withIntermediateDirectories: false)
        try writeLog([.intent(fs), .reserved(fs.id, try Identity.read(folder + "X"))])
        e = try engine()
        XCTAssertTrue(exists(folder), label); XCTAssertFalse(exists(folder + "X"), label)
        e = nil
        // Undo direction: the item is still renamed; the placeholder sits at the original name.
        let b = try file("b-\(UUID().uuidString.prefix(4))", in: base), done = try step(b, done: true)
        try FileManager.default.moveItem(atPath: b, toPath: b + "X")
        FileManager.default.createFile(atPath: b, contents: nil)
        try writeJournal(Journal(steps: [done])); try writeLog([.undoing(true), .reserved(done.id, try Identity.read(b))])
        e = try engine()
        XCTAssertFalse(exists(b), label); XCTAssertTrue(exists(b + "X"), label); XCTAssertTrue(e!.canUndo, label)
        try e!.undo(); XCTAssertTrue(exists(b), label)
        e = nil
        // Anything other than the exact empty placeholder is ambiguous.
        let c = try file("c-\(UUID().uuidString.prefix(4))", in: base), cs = try step(c)
        FileManager.default.createFile(atPath: c + "X", contents: nil)
        let placeholder = try Identity.read(c + "X")
        try Data("someone else".utf8).write(to: URL(fileURLWithPath: c + "X"))
        try writeJournal(Journal()); try writeLog([.intent(cs), .reserved(cs.id, placeholder)])
        XCTAssertThrowsError(try engine(), label)
        XCTAssertEqual(try String(contentsOfFile: c + "X", encoding: .utf8), "someone else", label)
        // Init compacted the log into the snapshot before refusing; clear it for the next volume.
        XCTAssertFalse(exists(logURL.path), label)
        try writeJournal(Journal())
    }
    func testReservationRechecksPlaceholderBeforeRename() throws {
        let volume = try diskImage("ExFAT")
        let a = try file("a.txt", in: volume)
        let e = try engine()
        e.beforeRename = {
            try FileManager.default.removeItem(atPath: volume.appendingPathComponent("aX.txt").path)
            try Data("intruder".utf8).write(to: volume.appendingPathComponent("aX.txt"))
        }
        XCTAssertThrowsError(try e.apply(Planner.plan([Entry(a)], operation: operation("X"))))
        XCTAssertEqual(try String(contentsOfFile: volume.appendingPathComponent("aX.txt").path, encoding: .utf8), "intruder")
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "a.txt")
        XCTAssertFalse(e.canUndo)
    }
}
