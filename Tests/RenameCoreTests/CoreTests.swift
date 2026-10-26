import XCTest
@testable import RenameCore

final class CoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        guard let scratch = ProcessInfo.processInfo.environment["TMPDIR"], scratch == ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] else { throw RenameError("Tests require physical scratch TMPDIR") }
        root = URL(fileURLWithPath: scratch).appendingPathComponent("batch-rename-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    func file(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: url)
        return url.path
    }
    func engine() throws -> Engine { try Engine(journalURL: root.appendingPathComponent("journal/undo.json")) }
    func operation(_ text: String = " edited") -> RenameOperation { var o = RenameOperation(); o.text = text; return o }
    func testNaming() throws {
        let op = operation()
        for (input, expected) in [("a.jpg", "a edited.jpg"), ("archive.tar.gz", "archive.tar edited.gz"), (".gitignore", ".gitignore edited"), ("plain", "plain edited"), ("🚘e\u{301}.mp4", "🚘e\u{301} edited.mp4"), ("a.", "a edited.")] {
            XCTAssertEqual(try op.name(input), expected)
        }
        XCTAssertEqual(try op.name("folder.name", folder: true), "folder.name edited")
        var p = operation("X"); p.action = .prepend
        XCTAssertEqual(try p.name("a.mp4"), "Xa.mp4")
        p.scope = .ext; XCTAssertEqual(try p.name("a.mp4"), "a.Xmp4")
        p.action = .replace; p.search = "a"; p.text = ""; p.scope = .full
        XCTAssertEqual(try p.name("aaba.txt"), "b.txt")
        p.search = ""; XCTAssertThrowsError(try p.name("a"))
        XCTAssertThrowsError(try operation("/").name("a"))
        XCTAssertThrowsError(try operation("\0").name("a"))
        XCTAssertEqual(try operation("").name("a.txt"), "a.txt")
    }
    func testExactT340RepairPreviewAndDurableUndo() throws {
        let original = "2026_1024_222430_004409F Pedestrians crossing at night in Seattle, T340, T340.MP4"
        let repaired = "2026_1024_222430_004409F Pedestrians crossing at night in Seattle, T340.MP4"
        let path = try file(original)
        var op = operation(", T340")
        for name in [original, repaired] {
            XCTAssertTrue(try op.preview(name).skipped)
            XCTAssertEqual(try op.name(name), name)
        }
        XCTAssertTrue(try Planner.plan([Entry(path)], operation: op).isEmpty)
        op.action = .replace; op.search = ", T340, T340"; op.ignoreCase = true
        let preview = try op.preview(original)
        XCTAssertEqual(preview.name, repaired)
        XCTAssertEqual(preview.sourceMatches.map { (original as NSString).substring(with: $0) }, [", T340, T340"])
        XCTAssertEqual(preview.replacements.map { (repaired as NSString).substring(with: $0) }, [", T340"])
        var e: Engine? = try engine()
        try e!.apply(Planner.plan([Entry(path)], operation: op)); e = nil
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(repaired)), Data(original.utf8))
        e = try engine(); try e!.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(repaired).path))
    }
    func testExactSuffixGuardScopeAndOptOut() throws {
        var op = operation(", T340")
        XCTAssertTrue(op.skipExistingSuffix)
        XCTAssertEqual(try op.name("T340, T340 crossing.MP4"), "T340, T340 crossing, T340.MP4")
        XCTAssertEqual(try op.name("clip, t340.MP4"), "clip, t340, T340.MP4")
        XCTAssertFalse(try op.preview("clip, T340 more.MP4").skipped)
        op.skipExistingSuffix = false
        XCTAssertEqual(try op.name("clip, T340.MP4"), "clip, T340, T340.MP4")
        op.skipExistingSuffix = true; op.scope = .full
        XCTAssertEqual(try op.name("clip, T340.MP4"), "clip, T340.MP4, T340")
        XCTAssertTrue(try op.preview("folder, T340", folder: true).skipped)
        op.scope = .ext; op.text = "MP4"
        XCTAssertTrue(try op.preview("clip.MP4").skipped)
        op.text = ""; XCTAssertFalse(try op.preview("clip.MP4").skipped)
    }
    func testUnicodeLiteralReplacementModesAndDeletionRanges() throws {
        var op = operation("🚘"); op.action = .replace; op.search = "école"
        let source = "ÉCOLE école École.MP4"
        XCTAssertEqual(try op.name(source), "ÉCOLE 🚘 École.MP4")
        op.ignoreCase = true
        XCTAssertEqual(try op.name(source), "🚘 🚘 🚘.MP4")
        let all = try op.preview(source)
        XCTAssertEqual(all.sourceMatches.count, 3)
        XCTAssertEqual(all.replacements.map { (all.name as NSString).substring(with: $0) }, ["🚘", "🚘", "🚘"])
        op.occurrences = .first
        XCTAssertEqual(try op.name(source), "🚘 école École.MP4")
        op.text = ""
        let deletion = try op.preview(source)
        XCTAssertTrue(deletion.deletion); XCTAssertEqual(deletion.sourceMatches.count, 1)
        XCTAssertEqual((source as NSString).substring(with: deletion.sourceMatches[0]), "ÉCOLE")
        XCTAssertEqual(deletion.name, " école École.MP4")
        op.search = ".*"; XCTAssertEqual(try op.name(source), source)
        op.scope = .ext; op.search = "mp4"; op.text = "MOV"
        XCTAssertEqual(try op.name(source), "ÉCOLE école École.MOV")
    }
    func testIncrementalDedupeHardlinksAndTraversal() throws {
        let a = try file("folder/a.txt"), b = try file("folder/sub/b.txt")
        _ = try file("folder/.hidden"); _ = try file("folder/Bundle.app/inside")
        let link = root.appendingPathComponent("folder/loop").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root.appendingPathComponent("folder").path)
        let hard = root.appendingPathComponent("folder/hard.txt").path
        try FileManager.default.linkItem(atPath: a, toPath: hard)
        var inv = Inventory(); inv.append([root.appendingPathComponent("folder").path]); inv.append([a, a])
        XCTAssertEqual(Set(try inv.scan().map(\.path)), Set([a, hard, link]))
        inv.recursive = true
        XCTAssertEqual(Set(try inv.scan().map(\.path)), Set([a, b, hard, link]))
        inv.folders = true; XCTAssertEqual(try inv.scan().count, 7)
        inv.files = false; XCTAssertEqual(try inv.scan().count, 3)
        inv.recursive = false; XCTAssertEqual(try inv.scan().count, 3)
        inv.files = true
        let c = try file("other/c"); inv.append([c]); XCTAssertTrue(try inv.scan().contains { $0.path == c })
    }
    func testRenameDurableUndoAndCollision() throws {
        let a = try file("a.mp4")
        var e: Engine? = try engine()
        let plan = try Planner.plan([Entry(a)], operation: operation())
        try e!.apply(plan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a edited.mp4").path))
        XCTAssertThrowsError(try e!.apply(plan))
        e = nil
        e = try engine(); XCTAssertTrue(e!.canUndo)
        try e!.undo(); XCTAssertTrue(FileManager.default.fileExists(atPath: a)); XCTAssertFalse(e!.canUndo)
        _ = try file("a edited.mp4")
        XCTAssertThrowsError(try Planner.plan([Entry(a)], operation: operation()))
    }
    func testRaceNeverOverwrites() throws {
        let a = try file("a")
        let plan = try Planner.plan([Entry(a)], operation: operation("X"))
        let e = try engine()
        XCTAssertThrowsError(try e.apply(plan, beforeMove: { item in try Data("intruder".utf8).write(to: URL(fileURLWithPath: item.destination)) }))
        XCTAssertEqual(try String(contentsOfFile: root.appendingPathComponent("aX").path, encoding: .utf8), "intruder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
    }
    func testSourceIdentityChanged() throws {
        let a = try file("a")
        let plan = try Planner.plan([Entry(a)], operation: operation("X"))
        let e = try engine()
        XCTAssertThrowsError(try e.apply(plan, beforeMove: { _ in
            try FileManager.default.moveItem(atPath: a, toPath: a + "-moved")
            try Data("other".utf8).write(to: URL(fileURLWithPath: a))
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a + "X"))
    }
    func testDescendantsBeforeParentsAndUndoAfterRelaunch() throws {
        let a = try file("parent/child/a.txt")
        var inventory = Inventory(); inventory.folders = true; inventory.recursive = true; inventory.append([root.appendingPathComponent("parent").path])
        let plan = try Planner.plan(inventory.scan(), operation: operation("X"))
        XCTAssertEqual(plan.first?.entry.path, a)
        var e: Engine? = try engine(); try e!.apply(plan); e = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("parentX/childX/aX.txt").path))
        e = try engine(); try e!.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
    }
    func testUndoOccupiedOriginalNeverOverwrites() throws {
        let a = try file("a"), e = try engine()
        try e.apply(Planner.plan([Entry(a)], operation: operation("X")))
        try Data("intruder".utf8).write(to: URL(fileURLWithPath: a))
        XCTAssertThrowsError(try e.undo())
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "intruder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a + "X"))
    }
    func testCaseOnlyRenameAndUndo() throws {
        let a = try file("case.txt")
        var op = operation("CASE"); op.action = .replace; op.search = "case"
        let e = try engine(); try e.apply(Planner.plan([Entry(a)], operation: op))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("CASE.txt"))
        try e.undo(); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("case.txt"))
    }
    func testLimitsAndDuplicatePlans() throws {
        let a = try file("a"), b = try file("b")
        XCTAssertThrowsError(try Planner.plan([Entry(a)], operation: operation(String(repeating: "x", count: 300))))
        var op = operation("b"); op.action = .replace; op.search = "a"
        XCTAssertThrowsError(try Planner.plan([Entry(a), Entry(b)], operation: op))
    }
    func testSymlinkAncestorAndVolumeRootRejected() throws {
        XCTAssertThrowsError(try Entry("/"))
        _ = try file("real/a")
        let alias = root.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: root.appendingPathComponent("real").path)
        let e = try engine()
        XCTAssertThrowsError(try e.apply(Planner.plan([Entry(alias + "/a")], operation: operation("X"))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("real/a").path))
    }
    func testInterruptedIntentBeforeAndAfterRename() throws {
        let a = try file("a"), entry = try Entry(a)
        let url = root.appendingPathComponent("journal/undo.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let step = Step(source: a, destination: a + "X", identity: entry.identity, parent: entry.parent)
        try JSONEncoder().encode(Journal(steps: [step])).write(to: url)
        var e: Engine? = try engine(); XCTAssertFalse(e!.canUndo); e = nil
        try JSONEncoder().encode(Journal(steps: [step])).write(to: url)
        try FileManager.default.moveItem(atPath: a, toPath: a + "X")
        e = try engine(); XCTAssertTrue(e!.canUndo); try e!.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
    }
    func testInterruptedUndoAfterRename() throws {
        let a = try file("a"), entry = try Entry(a)
        let url = root.appendingPathComponent("journal/undo.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let step = Step(source: a, destination: a + "X", identity: entry.identity, parent: entry.parent, done: true)
        try JSONEncoder().encode(Journal(steps: [step], undoing: true)).write(to: url)
        let e = try engine(); XCTAssertFalse(e.canUndo)
    }
    func testModifiedUndoTargetIsRejected() throws {
        let a = try file("a"), e = try engine()
        try e.apply(Planner.plan([Entry(a)], operation: operation("X")))
        try Data("changed content".utf8).write(to: URL(fileURLWithPath: a + "X"))
        XCTAssertThrowsError(try e.undo())
        XCTAssertFalse(FileManager.default.fileExists(atPath: a))
    }
    func testBatchesUndoSeparatelyAndLock() throws {
        let a = try file("a"), b = try file("b"), e = try engine()
        XCTAssertThrowsError(try engine())
        try e.apply(Planner.plan([Entry(a)], operation: operation("X")))
        try e.apply(Planner.plan([Entry(b)], operation: operation("X")))
        try e.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: b))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a))
        XCTAssertTrue(e.canUndo)
        try e.undo(); XCTAssertTrue(FileManager.default.fileExists(atPath: a))
    }
    func testPartialFailureUndoAndCancellation() throws {
        let a = try file("a"), b = try file("b"), e = try engine()
        let plan = try Planner.plan([Entry(a), Entry(b)], operation: operation("X"))
        try e.apply(plan, cancelled: { true }); XCTAssertFalse(e.canUndo)
        XCTAssertThrowsError(try e.apply(plan, beforeMove: { item in
            if item.entry.path == b { try Data("intruder".utf8).write(to: URL(fileURLWithPath: item.destination)) }
        }))
        try e.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
        XCTAssertEqual(try String(contentsOfFile: b + "X", encoding: .utf8), "intruder")
    }

    func testRejectedUndoReloadAndUnrelatedBatch() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        var e: Engine? = try engine()
        try e!.apply(Planner.plan([Entry(a)], operation: operation("X")))
        let changed = root.appendingPathComponent("aX.txt")
        try Data("externally changed".utf8).write(to: changed)
        XCTAssertThrowsError(try e!.undo())
        e = nil
        e = try engine()
        XCTAssertTrue(e!.canUndo)
        try e!.apply(Planner.plan([Entry(b)], operation: operation("Y")))
        try e!.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: b))
        XCTAssertEqual(try String(contentsOf: changed, encoding: .utf8), "externally changed")
        XCTAssertThrowsError(try e!.undo())
        e = nil
        e = try engine()
        XCTAssertTrue(e!.canUndo)
    }

    func testRejectedOccupiedUndoReloadThenRetry() throws {
        let a = try file("a")
        var e: Engine? = try engine()
        try e!.apply(Planner.plan([Entry(a)], operation: operation("X")))
        try Data("occupant".utf8).write(to: URL(fileURLWithPath: a))
        XCTAssertThrowsError(try e!.undo())
        e = nil
        e = try engine()
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "occupant")
        try FileManager.default.moveItem(atPath: a, toPath: a + "-occupant")
        try e!.undo()
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "a")
    }

    func testSourceSubstitutionAtSyscallBoundaryRequiresRecovery() throws {
        for undo in [false, true] {
            let a = try file(undo ? "undo" : "forward")
            var e: Engine? = try Engine(journalURL: root.appendingPathComponent(undo ? "u/undo.json" : "f/undo.json"))
            let plan = try Planner.plan([Entry(a)], operation: operation("X"))
            if undo { try e!.apply(plan) }
            let source = undo ? a + "X" : a
            let destination = undo ? a : a + "X"
            e!.beforeRename = {
                try FileManager.default.moveItem(atPath: source, toPath: source + "-original")
                try Data("substitute".utf8).write(to: URL(fileURLWithPath: source))
            }
            if undo { XCTAssertThrowsError(try e!.undo()) }
            else { XCTAssertThrowsError(try e!.apply(plan)) }
            XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "substitute")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source + "-original"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source))
            XCTAssertThrowsError(try e!.apply([]))
            e = nil
            XCTAssertThrowsError(try Engine(journalURL: root.appendingPathComponent(undo ? "u/undo.json" : "f/undo.json"))) {
                XCTAssertTrue($0.localizedDescription.contains("Identity changed during rename"))
            }
        }
    }

    func testParentSubstitutionAtSyscallBoundaryRequiresRecovery() throws {
        let a = try file("parent/a")
        let parent = root.appendingPathComponent("parent").path
        var e: Engine? = try engine()
        e!.beforeRename = {
            try FileManager.default.moveItem(atPath: parent, toPath: parent + "-moved")
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try e!.apply(Planner.plan([Entry(a)], operation: operation("X"))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent + "-moved/aX"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent + "/aX"))
        e = nil
        XCTAssertThrowsError(try engine())
    }

    func testPreMutationHookFailureDoesNotPoisonJournal() throws {
        let a = try file("a")
        var e: Engine? = try engine()
        e!.beforeRename = { throw RenameError("injected pre-mutation failure") }
        XCTAssertThrowsError(try e!.apply(Planner.plan([Entry(a)], operation: operation("X"))))
        e = nil
        e = try engine()
        XCTAssertFalse(e!.canUndo)
        try e!.apply(Planner.plan([Entry(a)], operation: operation("X")))
        e!.beforeRename = { throw RenameError("injected pre-mutation failure") }
        XCTAssertThrowsError(try e!.undo())
        e = nil
        e = try engine()
        try e!.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
    }

}
