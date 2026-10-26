import Foundation

public enum RenamePresentation {
    /// UTF-16 ranges for NSTextView. Include a neighboring composed character for
    /// insertion/deletion anchors, including at end of string. Never split emoji.
    public static func revealRange(in name: String, changes: [NSRange]) -> NSRange {
        let text = name as NSString
        guard text.length > 0, let change = changes.first else { return NSRange(location: 0, length: 0) }
        let start = min(max(0, change.location), text.length)
        let length = min(max(0, change.length), text.length - start)
        if length > 0 { return text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: length)) }
        return text.rangeOfComposedCharacterSequence(at: min(start, text.length - 1))
    }
    public static func completion(files: Int, folders: Int) -> String {
        var parts: [String] = []
        if files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files")") }
        if folders > 0 { parts.append("\(folders) \(folders == 1 ? "folder" : "folders")") }
        return "Renamed " + (parts.isEmpty ? "0 files" : parts.joined(separator: " and ")) + "."
    }
}
