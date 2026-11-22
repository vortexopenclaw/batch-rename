import Foundation
@preconcurrency import RenameCore

/// User-facing model copy. Counts use explicit singular and plural forms so each
/// string can be localized as a whole sentence.
enum ModelText {
    static func number(_ n: Int) -> String { n.formatted(.number) }
    static func items(_ n: Int) -> String {
        n == 1 ? String(localized: "1 item") : String(localized: "\(number(n)) items")
    }
    static func ready(changes: Int, problems: Int) -> String {
        if changes == 0 && problems == 0 { return String(localized: "No changes to make.") }
        let lead = changes == 1 ? String(localized: "1 change ready.")
            : changes == 0 ? String(localized: "No changes ready.")
            : String(localized: "\(number(changes)) changes ready.")
        let tail = problems == 0 ? String(localized: "No files are overwritten.")
            : problems == 1 ? String(localized: "1 has a problem.")
            : String(localized: "\(number(problems)) have problems.")
        return lead + " " + tail
    }
    static func renameTitle(_ n: Int) -> String {
        n == 1 ? String(localized: "Rename 1 Item") : String(localized: "Rename \(number(n)) Items")
    }
    static func renamed(files: Int, folders: Int) -> String {
        let f = files == 1 ? String(localized: "1 file") : String(localized: "\(number(files)) files")
        let d = folders == 1 ? String(localized: "1 folder") : String(localized: "\(number(folders)) folders")
        switch (files > 0, folders > 0) {
        case (true, true): return String(localized: "Renamed \(f) and \(d).")
        case (false, true): return String(localized: "Renamed \(d).")
        default: return String(localized: "Renamed \(f).")
        }
    }
    static func progress(undoing: Bool, done: Int, total: Int) -> String {
        undoing ? String(localized: "Undoing \(number(done)) of \(number(total))")
            : String(localized: "Renaming \(number(done)) of \(number(total))")
    }
    static let undoAvailable = String(localized: "Undo is available.")
    static func cancelled(renamed: Int, total: Int, undo: Bool) -> String {
        guard renamed > 0 else { return String(localized: "Cancelled. Nothing was renamed.") }
        let text = String(localized: "Cancelled after \(number(renamed)) of \(number(total)).")
        return undo ? text + " " + undoAvailable : text
    }
    static func stopped(_ error: String, renamed: String?, undo: Bool) -> String {
        var parts: [String] = []
        if let renamed { parts.append(renamed) }
        parts.append(String(localized: "Stopped: \(error)"))
        if undo { parts.append(undoAvailable) }
        return parts.joined(separator: " ")
    }
    static func restored(_ n: Int) -> String {
        n == 1 ? String(localized: "Restored 1 original name.") : String(localized: "Restored \(number(n)) original names.")
    }
    static func undoStopped(_ error: String) -> String { String(localized: "Undo stopped safely: \(error)") }
    static func missingRoots(_ n: Int) -> String {
        n == 1 ? String(localized: "Skipped 1 item that no longer exists.") : String(localized: "Skipped \(number(n)) items that no longer exist.")
    }
    static func unreadable(_ n: Int) -> String {
        n == 1 ? String(localized: "1 item couldn't be read.") : String(localized: "\(number(n)) items couldn't be read.")
    }
    static func droppedSkipped(_ n: Int) -> String {
        n == 1 ? String(localized: "1 dropped item was skipped because it isn't a file on disk.")
            : String(localized: "\(number(n)) dropped items were skipped because they aren't files on disk.")
    }
    static func companions(_ n: Int) -> String {
        n == 1 ? String(localized: "Also applied to 1 companion file.") : String(localized: "Also applied to \(number(n)) companion files.")
    }
    static func header(visible: Int, total: Int) -> String {
        visible == total ? items(total) : String(localized: "Showing \(number(visible)) of \(items(total))")
    }
    static let clearedList = String(localized: "List cleared. Description and undo history preserved.")
    static let dropToBegin = String(localized: "Drop files or folders here to begin.")
    static let nothingToUndo = String(localized: "Nothing to undo")
    /// Time only for today, otherwise date and time. Journals from before 0.2 have no date.
    static func historyDate(_ date: Date?) -> String {
        guard let date else { return String(localized: "Earlier") }
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }
    static func undoHelp(count: Int, date: Date?) -> String {
        guard date != nil else { return String(localized: "Undo renaming \(items(count))") }
        return String(localized: "Undo renaming \(items(count)) from \(historyDate(date))")
    }
    static func undoThroughPrompt(batches: Int, items count: Int) -> String {
        let b = batches == 1 ? String(localized: "1 batch") : String(localized: "\(number(batches)) batches")
        return String(localized: "Undo \(b), \(items(count))?")
    }
    static func quitting(undo: Bool) -> String {
        undo ? String(localized: "Batch Rename will quit when undo finishes.")
            : String(localized: "Stopping after the current item. Batch Rename will quit when it's safe.")
    }
}

// Display labels stay separate from Codable raw values, which are storage only.
extension Action {
    var label: String {
        switch self {
        case .append: return String(localized: "Add text to end")
        case .prepend: return String(localized: "Add text to beginning")
        case .replace: return String(localized: "Find & replace")
        }
    }
}
extension Occurrences {
    var label: String {
        switch self {
        case .all: return String(localized: "All occurrences")
        case .first: return String(localized: "First occurrence")
        }
    }
}
extension Scope {
    var label: String {
        switch self {
        case .base: return String(localized: "The file name without the extension")
        case .full: return String(localized: "The entire file name and extension")
        case .ext: return String(localized: "The file extension")
        }
    }
}

enum UndoRoute: Equatable { case text, batch, none }
/// Cmd+Z goes to the text being edited first; otherwise it undoes the last batch.
enum UndoRouting {
    static func undo(editingText: Bool, batchAvailable: Bool, locked: Bool) -> UndoRoute {
        if editingText { return .text }
        return batchAvailable && !locked ? .batch : .none
    }
    /// Batches are never redone.
    static func redo(editingText: Bool) -> UndoRoute { editingText ? .text : .none }
}

enum CompanionEdit {
    /// Splits at the final dot (not a leading one). The extension keeps its dot.
    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
    static func commonEnds(_ a: [Character], _ b: [Character]) -> (prefix: Int, suffix: Int) {
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return (p, s)
    }
    /// Applies the middle of an edited name to a companion with an equally long automatic stem.
    static func propagate(automatic: String, edited: String, companion: String) -> String? {
        let a = split(automatic), e = split(edited), c = split(companion)
        guard a.ext == e.ext else { return nil }
        let stem = Array(a.stem), new = Array(e.stem), other = Array(c.stem)
        guard other.count == stem.count else { return nil }
        let (p, s) = commonEnds(stem, new)
        return String(other[..<p]) + String(new[p..<(new.count - s)]) + String(other[(other.count - s)...]) + c.ext
    }
    /// Highlight ranges for a hand-edited name: the span between the common prefix and suffix.
    static func highlight(original: String, edited: String) -> (source: NSRange, replacement: NSRange) {
        let o = Array(original), e = Array(edited)
        let (p, s) = commonEnds(o, e)
        let source = NSRange(location: String(o[..<p]).utf16.count, length: String(o[p..<(o.count - s)]).utf16.count)
        let replacement = NSRange(location: String(e[..<p]).utf16.count, length: String(e[p..<(e.count - s)]).utf16.count)
        return (source, replacement)
    }
}

/// Files opened before the model exists (Dock drops, Open With at cold launch).
@MainActor struct OpenRequests {
    private(set) var pending: [URL] = []
    mutating func receive(_ urls: [URL], model: Model?) {
        if let model { model.add(urls) } else { pending.append(contentsOf: urls) }
    }
    mutating func attach(_ model: Model) {
        guard !pending.isEmpty else { return }
        model.add(pending)
        pending = []
    }
}
