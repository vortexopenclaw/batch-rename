import Foundation
import RenameCore

enum Verification {
    static func run() throws {
        guard let scratch = ProcessInfo.processInfo.environment["TMPDIR"], scratch == ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] else { throw RenameError("Verification requires physical scratch TMPDIR") }
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("batch-rename-verify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("clip.mp4")
        try Data("fixture".utf8).write(to: source)
        var op = RenameOperation(); op.text = " Dark backroads, front opp plates"
        guard try op.name("clip.mp4") == "clip Dark backroads, front opp plates.mp4" else { throw RenameError("Naming verification failed") }
        let duplicated = "2026_1024_222430_004409F Pedestrians crossing at night in Seattle, T340, T340.MP4"
        let repaired = "2026_1024_222430_004409F Pedestrians crossing at night in Seattle, T340.MP4"
        var guardOperation = RenameOperation(); guardOperation.text = ", T340"
        guard try guardOperation.preview(duplicated).skipped, try guardOperation.preview(repaired).skipped else { throw RenameError("Suffix guard verification failed") }
        let duplicateURL = root.appendingPathComponent(duplicated)
        try Data("duplicate fixture".utf8).write(to: duplicateURL)
        var repair = guardOperation; repair.action = .replace; repair.search = ", T340, T340"; repair.ignoreCase = true
        let repairPreview = try repair.preview(duplicated)
        guard repairPreview.name == repaired, repairPreview.sourceMatches.count == 1, repairPreview.replacements.count == 1 else { throw RenameError("Repair preview verification failed") }
        var engine: Engine? = try Engine(journalURL: root.appendingPathComponent("journal/undo.json"))
        try engine!.apply(Planner.plan([Entry(duplicateURL.path)], operation: repair))
        engine = nil
        engine = try Engine(journalURL: root.appendingPathComponent("journal/undo.json"))
        try engine!.undo()
        guard try Data(contentsOf: duplicateURL) == Data("duplicate fixture".utf8) else { throw RenameError("Repair undo verification failed") }
        try engine!.apply(Planner.plan([Entry(source.path)], operation: op))
        engine = nil
        engine = try Engine(journalURL: root.appendingPathComponent("journal/undo.json"))
        try engine!.undo()
        guard try Data(contentsOf: source) == Data("fixture".utf8) else { throw RenameError("Undo verification failed") }
    }
}
