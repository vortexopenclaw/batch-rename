#if DIRECT_UI_TESTS
import XCTest
import Foundation

final class ModelTests: XCTestCase {
    @MainActor func testRapidAddsDuringScanAccumulateAndPreviewTiming() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("rapid-add-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<500).map { index -> URL in
            let url = root.appendingPathComponent("clip-\(index).txt")
            try Data("fixture".utf8).write(to: url)
            return url
        }
        let model = Model(journalURL: root.appendingPathComponent("journal/undo.json"))
        model.operation.text = " edited"
        model.add(Array(urls.prefix(200)))
        XCTAssertTrue(model.busy)
        // No actor yield: both subsequent batches arrive while the first scan is busy.
        model.add(Array(urls[200..<400]))
        model.add(Array(urls[400...]) + [urls[0]])
        for _ in 0..<1000 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(Set(model.rows.map { $0.entry.path }), Set(urls.map(\.path)))
        XCTAssertEqual(model.pendingCount, 500)
        let start = Date()
        for index in 0..<5 { model.operation.text = " edited \(index)" }
        print("PREVIEW 500 files, five edits: \(Date().timeIntervalSince(start)) seconds")
        XCTAssertEqual(model.pendingCount, 500)
    }
    @MainActor func testAddsDuringRenameAndUndoAreRetained() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("busy-add-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt"), c = root.appendingPathComponent("c.txt")
        for url in [a, b, c] { try Data("fixture".utf8).write(to: url) }
        let model = Model(journalURL: root.appendingPathComponent("journal/undo.json"))
        func wait() async throws {
            for _ in 0..<500 {
                if !model.busy { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Model did not finish")
        }
        model.operation.text = "X"
        model.add([a]); try await wait()
        model.apply(); XCTAssertTrue(model.busy); model.add([b]); try await wait()
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        model.undo(); XCTAssertTrue(model.busy); model.add([c]); try await wait()
        XCTAssertEqual(model.rows.map { $0.entry.path }, [c.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(model.operation.text, "X")
    }
    func testPackagedFixtureURLRetainsDirectoryIdentity() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("fixture-url-" + UUID().uuidString)
        let inferred = root.appendingPathComponent("Batch Rename.app")
        let explicit = root.appendingPathComponent("Batch Rename.app", isDirectory: true)
        try fm.createDirectory(at: explicit.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bundle = try XCTUnwrap(Bundle(url: explicit))
        XCTAssertEqual(inferred.path, bundle.bundleURL.path)
        XCTAssertNotEqual(inferred, bundle.bundleURL)
        XCTAssertEqual(explicit, bundle.bundleURL)
    }
    func testFixtureResourceRequiresPhysicalContainedJournal() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("fixture-validation-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        func makeBundle(_ name: String, journal: URL) throws -> Bundle {
            let app = root.appendingPathComponent(name + ".app")
            let resources = app.appendingPathComponent("Contents/Resources")
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": "test." + name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try JSONEncoder().encode(["journal": journal.path]).write(to: resources.appendingPathComponent("LifecycleFixture.json"))
            return try XCTUnwrap(Bundle(url: app))
        }
        let journal = root.appendingPathComponent("journal/undo.json")
        XCTAssertEqual(try AppUpdater.loadFixtureJournal(bundle: makeBundle("valid", journal: journal))?.path, journal.path)
        XCTAssertThrowsError(try AppUpdater.loadFixtureJournal(bundle: makeBundle("escape", journal: root.appendingPathComponent("../outside.json"))))
        let link = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try AppUpdater.loadFixtureJournal(bundle: makeBundle("symlink", journal: link.appendingPathComponent("undo.json"))))
    }
    @MainActor func testImportedExternalSuffixAndIncrementalDrops() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("batch-rename-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("external.MP4")
        let external = root.appendingPathComponent("external, T340.MP4")
        let fresh = root.appendingPathComponent("fresh.MP4")
        try Data("external".utf8).write(to: original)
        try FileManager.default.moveItem(at: original, to: external)
        try Data("fresh".utf8).write(to: fresh)
        var model: Model? = Model(journalURL: root.appendingPathComponent("journal/undo.json"))
        func wait() async throws {
            for _ in 0..<500 {
                if model?.busy == false { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Model did not finish")
        }
        model!.operation.text = ", T340"
        model!.add([external]); try await wait()
        XCTAssertEqual(model!.pendingCount, 0)
        XCTAssertEqual(model!.rows[0].status, "Already ends with this text")
        XCTAssertTrue(model!.rows[0].preview!.skipped); XCTAssertFalse(model!.rows[0].done)
        model!.operation.skipExistingSuffix = false
        XCTAssertEqual(model!.pendingCount, 1)
        model!.operation.skipExistingSuffix = true
        model!.add([fresh]); try await wait()
        XCTAssertEqual(model!.rows.count, 2); XCTAssertEqual(model!.pendingCount, 1)
        model!.apply(); try await wait()
        XCTAssertTrue(model!.rows.contains { !$0.done && $0.preview?.skipped == true })
        model!.clear()
        XCTAssertEqual(model!.operation.text, ", T340"); XCTAssertTrue(model!.undoAvailable)
        model!.add([external]); try await wait()
        XCTAssertTrue(model!.rows[0].preview!.skipped)
        model = nil
        model = Model(journalURL: root.appendingPathComponent("journal/undo.json"))
        model!.operation.text = ", T340"; model!.add([external]); try await wait()
        XCTAssertEqual(model!.pendingCount, 0); XCTAssertTrue(model!.rows[0].preview!.skipped)
        model!.operation.text = ""
        XCTAssertEqual(model!.rows.count, 1); XCTAssertFalse(model!.rows[0].preview!.skipped)
        model!.undo(); try await wait()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }
    @MainActor func testClearDescriptionFrozenRowsAndNewDrops() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("batch-rename-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let model = Model(journalURL: root.appendingPathComponent("journal/undo.json"))
        func wait() async throws {
            for _ in 0..<500 {
                if !model.busy { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Model did not finish")
        }
        model.operation.text = " edited"
        model.add([a]); try await wait()
        XCTAssertEqual(model.pendingCount, 1)
        model.apply(); model.apply(); try await wait()
        XCTAssertEqual(model.pendingCount, 0); XCTAssertTrue(model.rows[0].done)
        model.operation.text = " NEW"
        XCTAssertEqual(model.pendingCount, 0)
        model.clear()
        XCTAssertEqual(model.operation.text, " NEW"); XCTAssertTrue(model.undoAvailable); XCTAssertTrue(model.rows.isEmpty)
        model.add([root.appendingPathComponent("a edited.txt"), b]); try await wait()
        XCTAssertEqual(model.rows.count, 2); XCTAssertEqual(model.pendingCount, 1)
        model.apply(); try await wait()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b NEW.txt").path))
        model.operation.text = ""
        XCTAssertTrue(model.undoAvailable)
        model.undo(); try await wait()
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a edited.txt").path))
    }
    @MainActor func testClearedDescendantAcrossParentRenameReloadAndUndo() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("batch-rename-model-" + UUID().uuidString)
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: parent.appendingPathComponent("a.txt"))
        let journal = root.appendingPathComponent("journal/undo.json")
        var model: Model? = Model(journalURL: journal)
        func wait() async throws {
            for _ in 0..<500 {
                if model?.busy == false { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Model did not finish")
        }
        model!.operation.text = "X"; model!.add([parent]); try await wait()
        model!.apply(); try await wait()
        model!.clear()
        XCTAssertTrue(model!.undoAvailable); XCTAssertEqual(model!.operation.text, "X")
        model!.files = false; try await wait()
        model!.folders = true; try await wait()
        model!.operation.text = "Y"; model!.add([parent]); try await wait()
        model!.apply(); try await wait()
        model!.files = true; try await wait()
        XCTAssertEqual(model!.pendingCount, 0)
        XCTAssertTrue(model!.rows.contains { $0.entry.name == "aX.txt" && $0.done })
        model = nil
        model = Model(journalURL: journal)
        model!.operation.text = "Y"
        model!.add([root.appendingPathComponent("parentY")]); try await wait()
        XCTAssertEqual(model!.pendingCount, 0)
        XCTAssertTrue(model!.rows.contains { $0.entry.name == "aX.txt" && $0.done })
        model!.undo(); try await wait()
        model!.add([parent]); try await wait()
        XCTAssertEqual(model!.pendingCount, 0)
        XCTAssertTrue(model!.rows.contains { $0.entry.name == "aX.txt" && $0.done })
        model!.undo(); try await wait()
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("a.txt").path))
    }
    @MainActor func testContentEditStaysFrozenButStrictUndoRejectsIt() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("freeze-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), renamed = root.appendingPathComponent("aX.txt")
        let journal = root.appendingPathComponent("journal/undo.json")
        try Data("a".utf8).write(to: a)
        var model: Model? = Model(journalURL: journal)
        func wait() async throws {
            for _ in 0..<500 {
                if !model!.busy { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Model did not finish")
        }
        model!.operation.text = "X"; model!.add([a]); try await wait()
        model!.apply(); try await wait()
        // In-place edit preserves the directory entry, unlike atomic replacement.
        let handle = try FileHandle(forWritingTo: renamed)
        try handle.write(contentsOf: Data("externally edited content".utf8)); try handle.close()
        model!.operation.text = "Y"
        model!.rebuild(); try await wait()
        XCTAssertEqual(model!.pendingCount, 0); XCTAssertTrue(model!.rows[0].done)
        model!.clear(); model!.add([renamed]); try await wait()
        XCTAssertEqual(model!.pendingCount, 0); XCTAssertTrue(model!.rows[0].done)
        model = nil
        model = Model(journalURL: journal)
        model!.operation.text = "Y"; model!.add([renamed]); try await wait()
        XCTAssertEqual(model!.pendingCount, 0); XCTAssertTrue(model!.rows[0].done)
        model!.apply(); try await wait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("aXY.txt").path))
        model!.undo(); try await wait()
        XCTAssertTrue(model!.message.hasPrefix("Undo stopped safely:"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }
    @MainActor func testEngineInitializationFailureCannotAdvertiseRename() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("batch-rename-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("invalid.json")
        try Data("invalid journal".utf8).write(to: journal)
        let file = root.appendingPathComponent("a.txt")
        try Data("fixture".utf8).write(to: file)
        let model = Model(journalURL: journal)
        model.operation.text = "X"; model.add([file])
        for _ in 0..<500 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertTrue(model.message.contains("Rename unavailable"))
        model.apply(); model.clear(); model.operation.text = "Y"
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertTrue(model.message.contains("Rename unavailable"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

}
#endif
