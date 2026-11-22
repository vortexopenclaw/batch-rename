import XCTest
@testable import RenameCore

class ScratchTestCase: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        guard let scratch = ProcessInfo.processInfo.environment["TMPDIR"], scratch == ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] else { throw RenameError("Tests require physical scratch TMPDIR") }
        root = URL(fileURLWithPath: scratch).appendingPathComponent("batch-rename-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        guard let root else { return }
        // Restore permissions changed by unreadable-folder tests before cleanup.
        if let items = FileManager.default.enumerator(atPath: root.path) { for case let item as String in items { chmod(root.appendingPathComponent(item).path, 0o755) } }
        try FileManager.default.removeItem(at: root)
    }
    @discardableResult func file(_ name: String, in base: URL? = nil, contents: String? = nil) throws -> String {
        let url = (base ?? root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((contents ?? name).utf8).write(to: url)
        return url.path
    }
    var journalURL: URL { root.appendingPathComponent("journal/undo.json") }
    func engine() throws -> Engine { try Engine(journalURL: journalURL) }
    func operation(_ text: String = " edited") -> RenameOperation { var o = RenameOperation(); o.text = text; return o }
    func writeJournal(_ journal: Journal) throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: journalURL)
    }
    func names(_ directory: URL? = nil) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: (directory ?? root).path) }
    func exists(_ path: String) -> Bool { var s = stat(); return lstat(path, &s) == 0 }

    /// A real FAT-family volume. Attach is skipped (not failed) where hdiutil is unavailable.
    func diskImage(_ fs: String) throws -> URL {
        let image = root.appendingPathComponent("\(fs).dmg"), mount = root.appendingPathComponent("mnt-\(fs)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        func hdiutil(_ arguments: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit(); return p.terminationStatus
        }
        guard hdiutil(["create", "-size", "40m", "-fs", fs, "-volname", "BRT", "-o", image.path, "-quiet"]) == 0,
              hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", mount.path, "-quiet"]) == 0 else {
            throw XCTSkip("Cannot create or attach a \(fs) disk image here")
        }
        addTeardownBlock { _ = hdiutil(["detach", mount.path, "-force", "-quiet"]) }
        return mount
    }
}
