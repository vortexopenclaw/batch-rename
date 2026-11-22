import XCTest
@testable import RenameCore

/// Regression tests for naming, planning, and scanning (audit fixes 2-7, 8 names, 11, 12).
final class PlannerRegressionTests: ScratchTestCase {
    // Fix 3
    func testColonOnlyRejectedWhenAdded() throws {
        XCTAssertEqual(try operation(" x").name("10:30 clip.mp4"), "10:30 clip x.mp4")
        XCTAssertThrowsError(try operation(":").name("a.txt"))
        var op = operation("-"); op.action = .replace; op.search = ":"
        XCTAssertEqual(try op.name("10:30.mp4"), "10-30.mp4")
        op.text = "::"; XCTAssertThrowsError(try op.name("10:30.mp4"))
        op.scope = .full; op.search = "a"; op.text = ""
        XCTAssertThrowsError(try op.name("a")); op.text = "."; XCTAssertThrowsError(try op.name("a")); op.text = ".."; XCTAssertThrowsError(try op.name("a"))
        let path = try file("10:30 clip.mp4")
        let plan = try Planner.plan([Entry(path)], operation: operation(", T340"))
        XCTAssertEqual(plan.map { URL(fileURLWithPath: $0.destination).lastPathComponent }, ["10:30 clip, T340.mp4"])
    }
    // Fix 4
    func testNewlyHiddenResultIsAPlannerProblem() throws {
        var op = operation(""); op.action = .replace; op.search = "a"
        XCTAssertEqual(try op.name("a.txt"), ".txt")
        let a = try file("a.txt")
        XCTAssertThrowsError(try Planner.plan([Entry(a)], operation: op)) {
            XCTAssertTrue($0.localizedDescription.contains("Would hide this item (name would start with a period)"))
        }
        let dotted = try file(".config")
        XCTAssertEqual(try Planner.plan([Entry(dotted)], operation: operation("X")).count, 1)
    }
    // Fix 5
    func testExtensionScopeLeavesFoldersUnchanged() throws {
        var op = operation("X"); op.scope = .ext
        XCTAssertEqual(try op.name("my.folder", folder: true), "my.folder")
        XCTAssertFalse(try op.preview("my.folder", folder: true).skipped)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("my.folder"), withIntermediateDirectories: false)
        XCTAssertTrue(try Planner.plan([Entry(root.appendingPathComponent("my.folder").path)], operation: op).isEmpty)
        XCTAssertEqual(try op.name("clip.mp4"), "clip.mp4X")
    }
    // Fix 6
    func testCanonicallyEquivalentMatchingAndSuffixGuard() throws {
        var op = operation("X"); op.action = .replace; op.search = "Caf\u{E9}"
        let nfd = "Cafe\u{301} clip.mp4"
        let p = try op.preview(nfd)
        XCTAssertEqual(Array(p.name.unicodeScalars), Array("X clip.mp4".unicodeScalars))
        XCTAssertEqual(p.sourceMatches.map { (nfd as NSString).substring(with: $0) }, ["Cafe\u{301}"])
        XCTAssertEqual(p.replacements.map { (p.name as NSString).substring(with: $0) }, ["X"])
        op.search = "CAFE\u{301}"; op.ignoreCase = true
        let nfc = "a caf\u{E9} b.mp4"
        let q = try op.preview(nfc)
        XCTAssertEqual(Array(q.name.unicodeScalars), Array("a X b.mp4".unicodeScalars))
        XCTAssertEqual(q.sourceMatches.map { (nfc as NSString).substring(with: $0) }, ["caf\u{E9}"])
        op.ignoreCase = false; XCTAssertEqual(try op.name(nfc), nfc)
        let guardOp = operation(", Caf\u{E9}")
        XCTAssertTrue(try guardOp.preview("clip, Cafe\u{301}.mp4").skipped)
        XCTAssertFalse(try guardOp.preview("clip, Cafe.mp4").skipped)
    }
    // Fix 7
    func testCJKNamesUpTo255CharactersAndLengthLimit() throws {
        let stem = String(repeating: "漢", count: 250)
        let path = try file(stem + ".a")
        let plan = try Planner.plan([Entry(path)], operation: operation("字字"))
        XCTAssertEqual(plan.count, 1)
        try engine().apply(plan)
        XCTAssertTrue(exists(root.appendingPathComponent(stem + "字字.a").path))
        let other = try file("b.a")
        XCTAssertThrowsError(try Planner.plan([Entry(other)], operation: operation(String(repeating: "漢", count: 254))))
    }
    func testFATFamilyRejectsNamesInvalidThere() throws {
        for fs in ["ExFAT", "MS-DOS"] {
            let volume = try diskImage(fs)
            let a = try file("a.txt", in: volume)
            for text in ["?", "*", "<", ">", "|", "\"", "\\", "\u{1}"] {
                XCTAssertThrowsError(try Planner.plan([Entry(a)], operation: operation(text)), "\(fs) \(text)")
            }
            var full = operation("."); full.scope = .full
            XCTAssertThrowsError(try Planner.plan([Entry(a)], operation: full), fs)
            full.text = " "; XCTAssertThrowsError(try Planner.plan([Entry(a)], operation: full), fs)
            XCTAssertEqual(try Planner.plan([Entry(a)], operation: operation(", T340")).count, 1, fs)
        }
        // The same characters remain legal on APFS.
        let apfs = try file("a.txt")
        XCTAssertEqual(try Planner.plan([Entry(apfs)], operation: operation("?")).count, 1)
    }
    // Fix 11
    func testUnreadableSubfolderIsSkippedWithRealError() throws {
        let a = try file("top/a.txt"); try file("top/locked/b.txt")
        let locked = root.appendingPathComponent("top/locked").path
        chmod(locked, 0)
        var inv = Inventory(); inv.recursive = true; inv.append([root.appendingPathComponent("top").path])
        XCTAssertEqual(try inv.scan().map(\.path), [a])
        XCTAssertThrowsError(try directoryFD(locked)) { XCTAssertTrue($0.localizedDescription.contains("Permission denied"), $0.localizedDescription) }
    }
    // Fix 12
    func testInventoryAppendScales() {
        var inv = Inventory()
        let paths = (0..<80_000).map { "/scale/clip-\($0).mp4" }
        let start = Date()
        inv.append(paths); inv.append(Array(paths.prefix(10)))
        let elapsed = Date().timeIntervalSince(start)
        print("INVENTORY append 80,000 roots: \(elapsed) seconds")
        XCTAssertEqual(inv.roots.count, 80_000)
        XCTAssertLessThan(elapsed, 5)
    }
    func testPlannerCaseOnlyScale() throws {
        let dir = root.appendingPathComponent("case")
        let entries = try (0..<3000).map { try Entry(try file("clip\($0).txt", in: dir)) }
        var op = operation("CLIP"); op.action = .replace; op.search = "clip"
        let start = Date()
        let plan = try Planner.plan(entries, operation: op)
        let elapsed = Date().timeIntervalSince(start)
        print("PLANNER 3,000 case-only renames: \(elapsed) seconds")
        XCTAssertEqual(plan.count, 3000)
        XCTAssertLessThan(elapsed, 5)
    }
}

final class PlannerProposalTests: ScratchTestCase {
    func testOneBadRowDoesNotFailThePlan() throws {
        let a = try Entry(try file("a.txt")), b = try Entry(try file("b.txt")), c = try Entry(try file("c.txt"))
        let d = try Entry(try file("d.txt")), f = try Entry(try file("f.txt")), g = try Entry(try file("g.txt"))
        try file("existing.txt")
        let result = Planner.plan(proposals: [
            Proposal(entry: a, name: "a/b.txt"),
            Proposal(entry: b, name: "dup.txt"),
            Proposal(entry: c, name: "DUP.txt"),
            Proposal(entry: d, name: "d2.txt"),
            Proposal(entry: f, name: "Existing.txt"),
            Proposal(entry: g, name: "g.txt"),
        ])
        XCTAssertEqual(result.items.map(\.destination), [root.appendingPathComponent("d2.txt").path])
        XCTAssertEqual(Set(result.problems.keys), Set([a.path, b.path, c.path, f.path]))
        XCTAssertTrue(result.problems[b.path]!.contains("same name"), result.problems[b.path]!)
        XCTAssertTrue(result.problems[f.path]!.contains("already exists"), result.problems[f.path]!)
        XCTAssertNil(result.problems[g.path])
        XCTAssertThrowsError(try Planner.plan([a, b], operation: { var o = operation("/"); o.scope = .full; return o }()))
    }
    func testFilesystemFoldedNamesCollide() throws {
        for (x, y) in [("σ", "ς"), ("s", "ſ"), ("β", "ϐ"), ("caf\u{E9}", "CAFE\u{301}")] {
            let dir = root.appendingPathComponent(UUID().uuidString)
            let one = try Entry(try file("one", in: dir)), two = try Entry(try file("two", in: dir))
            let result = Planner.plan(proposals: [Proposal(entry: one, name: "clip " + x), Proposal(entry: two, name: "clip " + y)])
            XCTAssertTrue(result.items.isEmpty, x)
            XCTAssertEqual(result.problems.count, 2, x)
        }
        XCTAssertEqual(filesystemNameKey("ς"), filesystemNameKey("Σ"))
        XCTAssertNotEqual(filesystemNameKey("a"), filesystemNameKey("b"))
    }
    func testHideAndInvalidNameMessages() throws {
        let a = try Entry(try file("a.txt")), dotted = try Entry(try file(".env"))
        let result = Planner.plan(proposals: [Proposal(entry: a, name: ".txt"), Proposal(entry: dotted, name: ".env2")])
        XCTAssertEqual(result.problems[a.path], "Would hide this item (name would start with a period)")
        XCTAssertEqual(result.items.count, 1)
        for bad in ["", ".", "..", "a\0b", "a:b"] {
            XCTAssertNotNil(Planner.plan(proposals: [Proposal(entry: a, name: bad)]).problems[a.path], bad)
        }
        XCTAssertNotNil(Planner.plan(proposals: [Proposal(entry: a, name: String(repeating: "x", count: 256))]).problems[a.path])
        XCTAssertEqual(Planner.plan(proposals: [Proposal(entry: a, name: String(repeating: "漢", count: 255))]).items.count, 1)
    }
}

final class TokenTests: ScratchTestCase {
    func testSequenceDateTimeAndLiteralTokens() throws {
        var op = RenameOperation(); op.text = " {###}"
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 7, modified: nil)), "clip 007.mp4")
        op.sequenceStart = 0; XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 1, modified: nil)), "clip 000.mp4")
        op.sequenceStart = 1; op.text = " {#}"
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 12, modified: nil)), "clip 12.mp4")
        op.text = " {####}"; op.sequenceStart = 98
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 3, modified: nil)), "clip 0100.mp4")
        op.sequenceStart = 1
        let date = try XCTUnwrap(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 10, day: 24, hour: 22, minute: 24, second: 30).date)
        op.text = " {date} {time}"
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 1, modified: date)), "clip 2026-10-24 22.24.30.mp4")
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 1, modified: nil)), "clip {date} {time}.mp4")
        op.text = " {foo} {# {#####}"
        XCTAssertEqual(try op.name("clip.mp4"), "clip {foo} {# {#####}.mp4")
        var replace = RenameOperation(); replace.action = .replace; replace.search = "{#}"; replace.text = "{##}"
        XCTAssertEqual(try replace.name("a{#}b", context: TokenContext(index: 3, modified: nil)), "a03b")
        XCTAssertEqual(try replace.name("a1b", context: TokenContext(index: 1, modified: nil)), "a1b")
        let replaced = try replace.preview("x{#}y{#}", context: TokenContext(index: 4, modified: nil))
        XCTAssertEqual(replaced.replacements.map { (replaced.name as NSString).substring(with: $0) }, ["04", "04"])
        var append = RenameOperation(); append.text = " {##}"
        let p = try append.preview("clip.mp4", context: TokenContext(index: 5, modified: nil))
        XCTAssertEqual(p.replacements.map { (p.name as NSString).substring(with: $0) }, [" 05"])
        append.text = ", {##}"
        XCTAssertTrue(try append.preview("clip, 02.mp4", context: TokenContext(index: 2, modified: nil)).skipped)
        XCTAssertFalse(try append.preview("clip, 02.mp4", context: TokenContext(index: 3, modified: nil)).skipped)
    }
    // C4
    func testSequenceOverflowLeavesTokenLiteral() throws {
        var op = RenameOperation(); op.text = " {#}"; op.sequenceStart = Int.max
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 1)), "clip \(Int.max).mp4")
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 2)), "clip {#}.mp4")
        op.sequenceStart = Int.min
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 1)), "clip \(Int.min).mp4")
        XCTAssertEqual(try op.name("clip.mp4", context: TokenContext(index: 0)), "clip {#}.mp4")
    }
    func testEntryModifiedAndLegacyPlanIndicesFollowEntryOrder() throws {
        let a = try file("a.mp4"), b = try file("b.mp4"), c = try file("c.mp4")
        let date = Date(timeIntervalSince1970: 1_761_369_870)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: a)
        XCTAssertEqual(try Entry(a).modified?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 0.001)
        let plan = try Planner.plan([Entry(c), Entry(a), Entry(b)], operation: operation(" {#}"))
        XCTAssertEqual(Set(plan.map { URL(fileURLWithPath: $0.destination).lastPathComponent }), ["c 1.mp4", "a 2.mp4", "b 3.mp4"])
    }
}

final class InventoryReportTests: ScratchTestCase {
    func testMissingRootsAndUnreadableDescendantsAreReported() throws {
        let a = try file("a.txt"), inner = try file("top/inner.txt"); try file("top/locked/b.txt")
        let locked = root.appendingPathComponent("top/locked").path
        chmod(locked, 0)
        let missing = root.appendingPathComponent("missing.txt").path
        var inv = Inventory(); inv.recursive = true
        inv.append([missing, a, root.appendingPathComponent("top").path])
        let report = inv.scanReport()
        XCTAssertEqual(report.entries.map(\.path), [a, inner])
        XCTAssertEqual(report.missingRoots, [missing])
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertTrue(report.issues.contains { $0.contains(locked) && $0.contains("Permission denied") }, report.issues.joined())
    }
    func testCompanionGroupKeys() {
        let cases: [(String, String)] = [
            ("2026_1024_222430_004409F.MP4", "2026_1024_222430_004409"),
            ("2026_1024_222430_004409R.MP4", "2026_1024_222430_004409"),
            ("2026_1024_222430_004409I.MP4", "2026_1024_222430_004409"),
            ("2026_1024_222430_004409F.LRV", "2026_1024_222430_004409"),
            ("20231015_123456_NF.mp4", "20231015_123456_n"),
            ("20231015_123456_NR.mp4", "20231015_123456_n"),
            ("20231015_123456_NF.gps", "20231015_123456_n"),
            ("REC_2023_10_15_12_34_56_F.MP4", "rec_2023_10_15_12_34_56_"),
            ("REC_2023_10_15_12_34_56_R.MP4", "rec_2023_10_15_12_34_56_"),
            ("Beef.mp4", "beef"), ("BEEF.mp4", "beef"), ("Chef.mov", "chef"), ("clip9f.mp4", "clip9f"),
            ("noext", "noext"), (".hidden", ".hidden"), ("a.tar.gz", "a.tar"),
        ]
        for (name, key) in cases { XCTAssertEqual(companionGroupKey(for: name), key, name) }
    }
    func testIncludeCompanionsAddsSiblingSidecars() throws {
        let dir = root.appendingPathComponent("DCIM")
        let front = try file("2026_1024_222430_004409F.MP4", in: dir)
        let expected = [front] + (try ["2026_1024_222430_004409R.MP4", "2026_1024_222430_004409F.SRT", "2026_1024_222430_004409F.THM", "2026_1024_222430_004409F.NMEA"].map { try file($0, in: dir) })
        for other in ["2026_1024_222440_004410F.MP4", "._2026_1024_222430_004409F.MP4", "Beef.mp4"] { try file(other, in: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("2026_1024_222430_004409R"), withIntermediateDirectories: false)
        var inv = Inventory(); inv.append([front])
        XCTAssertEqual(inv.scanReport().entries.map(\.path), [front])
        inv.includeCompanions = true
        XCTAssertEqual(Set(inv.scanReport().entries.map(\.path)), Set(expected))
        XCTAssertEqual(inv.scanReport().entries.count, expected.count)
        inv.roots = [dir.appendingPathComponent("Beef.mp4").path]
        try file("Beef.srt", in: dir)
        XCTAssertEqual(Set(inv.scanReport().entries.map(\.name)), ["Beef.mp4", "Beef.srt"])
    }
}
