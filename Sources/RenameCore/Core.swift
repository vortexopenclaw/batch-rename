import Foundation
import Darwin

public struct RenameError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum Action: String, CaseIterable, Codable { case append = "Add text to end", prepend = "Add text to beginning", replace = "Find & replace" }
public enum Scope: String, CaseIterable, Codable { case base = "Base name", ext = "Extension", full = "Full filename" }
public enum Occurrences: String, CaseIterable { case all = "All occurrences", first = "First occurrence" }
public struct NamePreview {
    public var name: String
    public var sourceMatches: [NSRange] = []
    public var replacements: [NSRange] = []
    public var skipped = false
    public var deletion = false
}

func errnoText(_ code: Int32) -> String { String(cString: strerror(code)) }

/// Name equivalence used by case-insensitive APFS, HFS+, and exFAT lookups:
/// Unicode case folding (ς/σ, ſ/s, ϐ/β) plus canonical composition.
public func filesystemNameKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping
}

/// Per-item values for `{#}`, `{date}`, and `{time}` tokens.
public struct TokenContext: Sendable, Equatable {
    /// 1-based position of the item in the list.
    public var index: Int
    /// Modification date (dashcam clips keep their recording time there).
    public var modified: Date?
    public init(index: Int = 1, modified: Date? = nil) { self.index = index; self.modified = modified }
}

public struct RenameOperation: Equatable {
    public var action: Action = .append
    public var scope: Scope = .base
    public var text = ""
    public var search = ""
    public var skipExistingSuffix = true
    public var ignoreCase = false
    public var occurrences: Occurrences = .all
    /// Value of `{#}` for the first item.
    public var sequenceStart = 1
    public init() {}
    public func name(_ original: String, folder: Bool = false, context: TokenContext = TokenContext()) throws -> String {
        try preview(original, folder: folder, context: context).name
    }
    /// Expands tokens in `text` only. Unknown `{...}` stays literal.
    public func expandedText(_ context: TokenContext) -> String {
        guard text.contains("{") else { return text }
        var result = "", rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = tokenValue(String(after[..<close]), context) {
                result += value
                rest = after[after.index(after: close)...]
            } else {
                result += "{"
                rest = after
            }
        }
        return result + rest
    }
    private func tokenValue(_ token: String, _ context: TokenContext) -> String? {
        if (1...4).contains(token.count), token.allSatisfy({ $0 == "#" }) {
            let n = sequenceStart + context.index - 1
            let digits = String(n.magnitude)
            return (n < 0 ? "-" : "") + String(repeating: "0", count: max(0, token.count - digits.count)) + digits
        }
        guard token == "date" || token == "time", let date = context.modified else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return token == "date"
            ? String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            : String(format: "%02d.%02d.%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
    /// Produces the proposed name. Filesystem-dependent validation lives in `Planner`.
    public func preview(_ original: String, folder: Bool = false, context: TokenContext = TokenContext()) throws -> NamePreview {
        // Folders have no extension: extension scope leaves them unchanged.
        if folder && scope == .ext { return NamePreview(name: original) }
        let text = expandedText(context)
        var target = original.startIndex..<original.endIndex
        if !folder, scope != .full {
            let dot = original.lastIndex(of: ".").flatMap { $0 == original.startIndex ? nil : $0 }
            if scope == .base { target = original.startIndex..<(dot ?? original.endIndex) }
            else { target = (dot.map { original.index(after: $0) } ?? original.endIndex)..<original.endIndex }
        }
        let value = String(original[target])
        var prefix = String(original[..<target.lowerBound])
        let suffix = String(original[target.upperBound...])
        var result = NamePreview(name: original)
        var transformed = ""
        switch action {
        case .append:
            // Exact suffix comparison after canonical composition: no case folding or word deduplication.
            if skipExistingSuffix && !text.isEmpty && value.precomposedStringWithCanonicalMapping.utf8.reversed().starts(with: text.precomposedStringWithCanonicalMapping.utf8.reversed()) {
                result.skipped = true; return result
            }
            transformed = value + text
            if !text.isEmpty {
                result.sourceMatches = [NSRange(location: prefix.utf16.count + value.utf16.count, length: 0)]
                result.replacements = [NSRange(location: prefix.utf16.count + value.utf16.count, length: text.utf16.count)]
            }
        case .prepend:
            transformed = text + value
            if !text.isEmpty {
                result.sourceMatches = [NSRange(location: prefix.utf16.count, length: 0)]
                result.replacements = [NSRange(location: prefix.utf16.count, length: text.utf16.count)]
            }
        case .replace:
            guard !search.isEmpty else { throw RenameError("Enter text to find.") }
            // Canonical equivalence (not .literal): NFD names match NFC search text.
            let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
            var cursor = target.lowerBound
            while cursor < target.upperBound,
                  let match = original.range(of: search, options: options, range: cursor..<target.upperBound, locale: Locale(identifier: "en_US_POSIX")),
                  !match.isEmpty {
                transformed += original[cursor..<match.lowerBound]
                result.sourceMatches.append(NSRange(match, in: original))
                result.replacements.append(NSRange(location: prefix.utf16.count + transformed.utf16.count, length: text.utf16.count))
                transformed += text
                cursor = match.upperBound
                if occurrences == .first { break }
            }
            transformed += original[cursor..<target.upperBound]
            result.deletion = !result.sourceMatches.isEmpty && text.isEmpty
        }
        if !folder, scope == .ext {
            if transformed.isEmpty && prefix.hasSuffix(".") { prefix.removeLast() }
            else if !transformed.isEmpty && target.isEmpty && !prefix.hasSuffix(".") {
                prefix += "."
                result.replacements = result.replacements.map { NSRange(location: $0.location + 1, length: $0.length) }
            }
        }
        result.name = prefix + transformed + suffix
        if let problem = Self.nameProblem(result.name, original: original) { throw RenameError(problem) }
        return result
    }
    /// Name-only validity, independent of the volume.
    static func nameProblem(_ name: String, original: String) -> String? {
        if name.isEmpty || name == "." || name == ".." { return "Invalid name." }
        let bytes = name.utf8
        if bytes.contains(0x2F) { return "Names cannot contain “/”." }
        if bytes.contains(0) { return "Names cannot contain a null character." }
        // Finder shows “:” as “/”; allow existing colons but never add new ones.
        if bytes.filter({ $0 == 0x3A }).count > original.utf8.filter({ $0 == 0x3A }).count { return "Names cannot contain “:”." }
        return nil
    }
}

public struct Identity: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let birth: Int64
    public let nanos: Int64
    public let kind: UInt16
    public let size: Int64
    public let modified: Int64
    public let modifiedNanos: Int64
    public var folder: Bool { kind == UInt16(S_IFDIR) }
    public var link: Bool { kind == UInt16(S_IFLNK) }
    init(_ s: stat) { device = s.st_dev; inode = s.st_ino; birth = Int64(s.st_birthtimespec.tv_sec); nanos = Int64(s.st_birthtimespec.tv_nsec); kind = s.st_mode & UInt16(S_IFMT); size = kind == UInt16(S_IFREG) ? s.st_size : 0; modified = kind == UInt16(S_IFREG) ? Int64(s.st_mtimespec.tv_sec) : 0; modifiedNanos = kind == UInt16(S_IFREG) ? Int64(s.st_mtimespec.tv_nsec) : 0 }
    public static func read(_ path: String) throws -> Identity {
        var s = stat()
        guard lstat(path, &s) == 0 else { throw RenameError("Cannot inspect \(path): \(errnoText(errno))") }
        return Identity(s)
    }
    /// The same directory entry object, ignoring content edits (size and modification time).
    public func sameLocation(_ other: Identity) -> Bool {
        device == other.device && inode == other.inode && birth == other.birth && nanos == other.nanos && kind == other.kind
    }
}
public struct Entry: Identifiable, Equatable, Sendable {
    public var path: String
    public let identity: Identity
    public let parent: Identity
    /// Modification time read when the entry was inspected.
    public let modified: Date?
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(_ path: String) throws {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        let fd = try directoryFD(URL(fileURLWithPath: self.path).deletingLastPathComponent().path)
        defer { close(fd) }
        var sourceStat = stat(), parentStat = stat()
        guard fstat(fd, &parentStat) == 0, fstatat(fd, URL(fileURLWithPath: self.path).lastPathComponent, &sourceStat, AT_SYMLINK_NOFOLLOW) == 0 else { throw RenameError("Cannot inspect \(self.path): \(errnoText(errno))") }
        identity = Identity(sourceStat)
        parent = Identity(parentStat)
        modified = Date(timeIntervalSince1970: Double(sourceStat.st_mtimespec.tv_sec) + Double(sourceStat.st_mtimespec.tv_nsec) / 1_000_000_000)
        guard identity != parent, identity.device == parent.device else { throw RenameError("Volume roots are not allowed.") }
    }
}
// A directory entry is a parent plus a name, not an inode: hardlinks remain distinct.
private func locationKey(_ entry: Entry) throws -> String {
    guard let name = try URL(fileURLWithPath: entry.path).resourceValues(forKeys: [.nameKey]).name else {
        throw RenameError("Cannot determine directory entry name: \(entry.path)")
    }
    // Ask the filesystem for the actual spelling rather than guessing its case
    // or Unicode comparison policy. Byte encoding preserves distinct hardlinks.
    return "\(entry.parent.device)|\(entry.parent.inode)|\(entry.parent.birth)|\(entry.parent.nanos)|\(Data(name.utf8).base64EncodedString())"
}

private let companionCamera = try! NSRegularExpression(pattern: "^(.*[0-9_](?:[A-Z])?)[FRI]$")
/// Dashcam companion grouping: front/rear/interior clips and sidecars share a key.
/// The stem drops its extension and a trailing camera letter (Viofo `…004409F`,
/// BlackVue `…_NF`, Thinkware `…_F`), then is lowercased.
public func companionGroupKey(for name: String) -> String {
    var stem = name
    if let dot = name.lastIndex(of: "."), dot != name.startIndex { stem = String(name[..<dot]) }
    let ns = stem as NSString
    if let match = companionCamera.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) {
        stem = ns.substring(with: match.range(at: 1))
    }
    return stem.lowercased()
}

public struct ScanReport: Sendable {
    public var entries: [Entry]
    /// Explicit roots that are missing or cannot be inspected.
    public var missingRoots: [String]
    /// Skipped descendants, each naming the path and the system error.
    public var issues: [String]
}
public struct Inventory: Sendable {
    public var roots: [String] = []
    public var files = true, folders = false, recursive = false
    /// Explicitly added regular files also add sibling files with the same `companionGroupKey`.
    public var includeCompanions = false
    public init() {}
    public mutating func append(_ paths: [String]) {
        var known = Set(roots)
        for p in paths { let p = URL(fileURLWithPath: p).standardizedFileURL.path; if known.insert(p).inserted { roots.append(p) } }
    }
    public mutating func removeRoots(matching entries: [Entry]) {
        let paths = Set(entries.map(\.path))
        let keys = Set(entries.compactMap { try? locationKey($0) })
        roots.removeAll { path in
            if paths.contains(path) { return true }
            guard let entry = try? Entry(path), let key = try? locationKey(entry) else { return false }
            return keys.contains(key)
        }
    }
    /// Throws only for missing explicit roots; unreadable descendants are skipped.
    public func scan() throws -> [Entry] {
        let report = scanReport()
        if let missing = report.missingRoots.first { throw RenameError("Cannot find or inspect \(missing).") }
        return report.entries
    }
    public func scanReport() -> ScanReport {
        var result: [Entry] = [], seen = Set<String>(), missing: [String] = [], issues: [String] = []
        var listings: [String: [String]] = [:]
        func list(_ path: String) -> [String]? {
            if let cached = listings[path] { return cached }
            do { let names = try directoryNames(path).sorted(); listings[path] = names; return names }
            catch { issues.append(error.localizedDescription); return nil }
        }
        func visit(_ path: String, explicit: Bool, device: Int32?) {
            let e: Entry
            do { e = try Entry(path) } catch {
                if explicit { missing.append(path) } else { issues.append(error.localizedDescription) }
                return
            }
            if let device, e.identity.device != device { return }
            if !explicit && e.name.hasPrefix(".") { return }
            guard let key = try? locationKey(e) else { issues.append("Cannot determine directory entry name: \(path)"); return }
            let newlySeen = seen.insert(key).inserted
            if !newlySeen && !explicit { return }
            if newlySeen && (e.identity.folder ? folders : files) { result.append(e) }
            if explicit && includeCompanions && e.identity.kind == UInt16(S_IFREG) {
                let parent = URL(fileURLWithPath: e.path).deletingLastPathComponent().path
                let group = companionGroupKey(for: e.name)
                for name in list(parent) ?? [] where !name.hasPrefix(".") && companionGroupKey(for: name) == group {
                    let child = URL(fileURLWithPath: parent).appendingPathComponent(name).path
                    guard let ci = try? Identity.read(child), ci.kind == UInt16(S_IFREG), ci.device == e.identity.device else { continue }
                    visit(child, explicit: false, device: e.identity.device)
                }
            }
            guard e.identity.folder else { return }
            do {
                let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey, .isAliasFileKey])
                if values.isPackage == true || values.isAliasFile == true { return }
            } catch { issues.append("Cannot inspect \(path): \(error.localizedDescription)"); return }
            guard explicit || recursive, let names = list(path) else { return }
            for name in names where !name.hasPrefix(".") {
                let child = URL(fileURLWithPath: path).appendingPathComponent(name).path
                let ci: Identity
                do { ci = try Identity.read(child) } catch { issues.append(error.localizedDescription); continue }
                if ci.device != e.identity.device { continue }
                if ci.folder && !recursive {
                    guard folders else { continue }
                    do {
                        let entry = try Entry(child)
                        if seen.insert(try locationKey(entry)).inserted { result.append(entry) }
                    } catch { issues.append(error.localizedDescription) }
                } else { visit(child, explicit: false, device: e.identity.device) }
            }
        }
        for root in roots { visit(root, explicit: true, device: nil) }
        return ScanReport(entries: result, missingRoots: missing, issues: issues)
    }
}
public struct PlanItem: Sendable {
    public let entry: Entry
    public let destination: String
    public init(entry: Entry, destination: String) { self.entry = entry; self.destination = destination }
}
/// A requested name for one entry (for example a per-clip description).
public struct Proposal: Sendable {
    public var entry: Entry
    public var name: String
    public init(entry: Entry, name: String) { self.entry = entry; self.name = name }
}
public struct PlanResult: Sendable {
    /// Valid renames, descendants before their parents.
    public var items: [PlanItem]
    /// User-readable problems keyed by entry path. Problem rows are excluded from `items`.
    public var problems: [String: String]
    public init(items: [PlanItem], problems: [String: String]) { self.items = items; self.problems = problems }
}
public enum Planner {
    private struct Folder { let nameMax: Int; let fat: Bool; var names: Set<[UInt8]>? }
    private static func folder(_ path: String, _ cache: inout [String: Folder]) -> Folder {
        if let cached = cache[path] { return cached }
        let max = pathconf(path, _PC_NAME_MAX)
        var fs = statfs(), type = ""
        if statfs(path, &fs) == 0 {
            type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
        }
        let folder = Folder(nameMax: max > 0 ? max : 255, fat: type == "msdos" || type == "exfat", names: nil)
        cache[path] = folder
        return folder
    }
    static func fatProblem(_ name: String) -> String? {
        let forbidden: Set<Unicode.Scalar> = ["\"", "*", "/", ":", "<", ">", "?", "\\", "|"]
        if name.unicodeScalars.contains(where: { forbidden.contains($0) || $0.value < 0x20 || $0.value == 0x7F }) {
            return "SD card (FAT/exFAT) names cannot contain \" * / : < > ? \\ | or control characters."
        }
        if let last = name.unicodeScalars.last, last == " " || last == "." { return "SD card (FAT/exFAT) names cannot end with a space or period." }
        return nil
    }
    public static func plan(proposals: [Proposal]) -> PlanResult {
        var problems: [String: String] = [:], folders: [String: Folder] = [:]
        var candidates: [(entry: Entry, name: String, parent: String, key: String)] = []
        var owners: [String: [String]] = [:]
        for proposal in proposals {
            let e = proposal.entry, name = proposal.name
            if name.utf8.elementsEqual(e.name.utf8) { continue }
            let parent = URL(fileURLWithPath: e.path).deletingLastPathComponent().path
            let facts = folder(parent, &folders)
            var problem = RenameOperation.nameProblem(name, original: e.name)
            if problem == nil, name.hasPrefix("."), !e.name.hasPrefix(".") { problem = "Would hide this item (name would start with a period)" }
            if problem == nil, facts.fat { problem = fatProblem(name) }
            if problem == nil, name.utf16.count > facts.nameMax { problem = "Name is too long (\(name.utf16.count) of \(facts.nameMax) characters)." }
            if problem == nil, (parent as NSString).appendingPathComponent(name).utf8.count >= Int(PATH_MAX) { problem = "Path is too long." }
            if let problem { problems[e.path] = problem; continue }
            // Conservative alias rejection catches equivalent planned names even on case-sensitive disks.
            let key = "\(e.parent.device)|\(e.parent.inode)|\(filesystemNameKey(name))"
            owners[key, default: []].append(e.path)
            candidates.append((e, name, parent, key))
        }
        var items: [(depth: Int, item: PlanItem)] = []
        for c in candidates {
            if owners[c.key, default: []].count > 1 { problems[c.entry.path] = "Another item would get the same name (“\(c.name)”)."; continue }
            let destination = (c.parent as NSString).appendingPathComponent(c.name)
            if let existing = try? Identity.read(destination) {
                // The filesystem itself resolved the name. Only an equivalent spelling of this
                // same entry (case or Unicode form) is a rename; anything else is occupied.
                var facts = folder(c.parent, &folders)
                if facts.names == nil {
                    facts.names = (try? directoryNames(c.parent)).map { Set($0.map { Array($0.utf8) }) } ?? []
                    folders[c.parent] = facts
                }
                let equivalent = filesystemNameKey(c.name) == filesystemNameKey(c.entry.name) && existing == c.entry.identity
                guard equivalent, !(facts.names ?? []).contains(Array(c.name.utf8)) else {
                    problems[c.entry.path] = "An item named “\(c.name)” already exists."; continue
                }
            }
            items.append((c.entry.path.utf8.reduce(0) { $1 == 0x2F ? $0 + 1 : $0 }, PlanItem(entry: c.entry, destination: destination)))
        }
        items.sort { $0.depth == $1.depth ? $0.item.entry.path < $1.item.entry.path : $0.depth > $1.depth }
        return PlanResult(items: items.map(\.item), problems: problems)
    }
    /// Legacy all-or-nothing planning: throws the first problem in entry order.
    /// Token indices follow entry order.
    public static func plan(_ entries: [Entry], operation: RenameOperation) throws -> [PlanItem] {
        var proposals: [Proposal] = []
        for (i, e) in entries.enumerated() {
            let name = try operation.name(e.name, folder: e.identity.folder, context: TokenContext(index: i + 1, modified: e.modified))
            proposals.append(Proposal(entry: e, name: name))
        }
        let result = plan(proposals: proposals)
        if let first = entries.first(where: { result.problems[$0.path] != nil }) { throw RenameError(result.problems[first.path]!) }
        return result.items
    }
}

// Open every ancestor without following symlinks. Hold the parent descriptor through rename.
func directoryFD(_ path: String) throws -> Int32 {
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw RenameError("Cannot open filesystem root: \(errnoText(errno))") }
    for component in path.split(separator: "/") {
        let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let code = errno
        close(fd)
        guard next >= 0 else {
            throw RenameError("Cannot open folder \(path): \(errnoText(code))" + (code == ELOOP ? " (an ancestor is a symlink)" : ""))
        }
        fd = next
    }
    return fd
}
public struct Step: Codable {
    public var source: String, destination: String
    public var identity: Identity, parent: Identity
    public var batch = UUID()
    public var done = false
    public var undone = false
}
struct Journal: Codable { var version = 1; var steps: [Step] = []; var undoing = false; var recoveryRequired: String? = nil }
public final class Engine {
    private let journalURL: URL
    private var journal: Journal
    private var lockFD: Int32 = -1
    // Internal deterministic test seam, after the final identity check.
    var beforeRename: (() throws -> Void)?
    public var steps: [Step] { journal.steps }
    public var completedPaths: [String: Identity] {
        var paths: [String: Identity] = [:]
        for step in journal.steps where step.done && !step.undone {
            var remapped: [String: Identity] = [:]
            for (path, id) in paths {
                let next = path == step.source ? step.destination : (path.hasPrefix(step.source + "/") ? step.destination + path.dropFirst(step.source.count) : path)
                remapped[next] = id
            }
            paths = remapped; paths[step.destination] = step.identity
        }
        return paths
    }
    public var canUndo: Bool { journal.steps.contains { $0.done && !$0.undone } }
    public init(journalURL: URL) throws {
        self.journalURL = journalURL
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lockFD = open(journalURL.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { if lockFD >= 0 { close(lockFD) }; throw RenameError("Another app instance owns undo history.") }
        do {
            if FileManager.default.fileExists(atPath: journalURL.path) { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)) }
            else { journal = Journal() }
            guard journal.version == 1 else { throw RenameError("Unsupported journal version.") }
        } catch { close(lockFD); lockFD = -1; throw error }
        try reconcile()
    }
    deinit { if lockFD >= 0 { close(lockFD) } }
    private func save() throws {
        let data = try JSONEncoder().encode(journal)
        let tmp = journalURL.path + "." + UUID().uuidString
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RenameError("Cannot create durable undo record.") }
        defer { close(fd); unlink(tmp) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                guard n > 0 else { throw RenameError("Undo journal write failed.") }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw RenameError("Undo journal sync failed.") }
        guard rename(tmp, journalURL.path) == 0 else { throw RenameError("Undo journal commit failed.") }
        let parent = try directoryFD(journalURL.deletingLastPathComponent().path)
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw RenameError("Undo directory sync failed.") }
    }
    private func reconcile() throws {
        if let reason = journal.recoveryRequired { throw RenameError(reason) }
        // Only a single boundary can be interrupted: serial execution persists every step.
        if journal.undoing, let i = journal.steps.lastIndex(where: { $0.done && !$0.undone }) {
            let s = journal.steps[i]
            let src = try? Identity.read(s.source), dst = try? Identity.read(s.destination)
            if src == s.identity && dst == nil { journal.steps[i].undone = true }
            else if dst != s.identity { throw RenameError("Interrupted undo is ambiguous. Preserve the journal and inspect files.") }
            journal.undoing = false; try save()
        }
        if let i = journal.steps.lastIndex(where: { !$0.done && !$0.undone }) {
            let s = journal.steps[i]
            let src = try? Identity.read(s.source), dst = try? Identity.read(s.destination)
            if dst == s.identity && src == nil { journal.steps[i].done = true }
            else if src == s.identity && dst != s.identity { journal.steps[i].undone = true }
            else { throw RenameError("Interrupted rename is ambiguous. Preserve the journal and inspect files.") }
            try save()
        }
    }
    private func move(_ s: Step, undo: Bool, mutated: inout Bool) throws {
        let source = undo ? s.destination : s.source, destination = undo ? s.source : s.destination
        let parentURL = URL(fileURLWithPath: source).deletingLastPathComponent()
        let fd = try directoryFD(parentURL.path)
        defer { close(fd) }
        let capability = try parentURL.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
        guard capability.volumeSupportsExclusiveRenaming == true else { throw RenameError("This volume does not support safe exclusive rename.") }
        let sourceName = URL(fileURLWithPath: source).lastPathComponent
        let destinationName = URL(fileURLWithPath: destination).lastPathComponent
        var ps = stat(), ss = stat()
        guard fstat(fd, &ps) == 0, Identity(ps) == s.parent,
              fstatat(fd, sourceName, &ss, AT_SYMLINK_NOFOLLOW) == 0, Identity(ss) == s.identity else { throw RenameError("File or parent changed since preview: \(source)") }
        // Darwin has no inode-conditional rename. RENAME_EXCL protects the destination,
        // not source identity. Keep this gap small, then detect substitution below.
        try beforeRename?()
        guard renameatx_np(fd, sourceName, fd, destinationName, UInt32(RENAME_EXCL)) == 0 else { throw RenameError("Rename stopped: \(String(cString: strerror(errno))) · \(source)") }
        mutated = true
        var moved = stat()
        let destinationMatches = fstatat(fd, destinationName, &moved, AT_SYMLINK_NOFOLLOW) == 0 && Identity(moved) == s.identity
        let pathFD = try? directoryFD(parentURL.path)
        var pathStat = stat()
        let parentMatches = pathFD.map { fstat($0, &pathStat) == 0 && Identity(pathStat) == s.parent } ?? false
        if let pathFD { close(pathFD) }
        guard destinationMatches && parentMatches else {
            // Never guess or race another rename to roll back an unexpected entry.
            // Persist a manual-recovery classification so reload cannot certify this move.
            let reason = "Identity changed during rename: \(source) → \(destination). Files were left in place; preserve the journal and inspect both paths before recovery."
            journal.recoveryRequired = reason
            try save()
            throw RenameError(reason)
        }
        // Post-checks detect observed races only; hostile concurrent namespace changes
        // after a check cannot be excluded, and a batch is not atomic.
        guard fsync(fd) == 0 else { throw RenameError("Directory sync failed; relaunch to reconcile.") }
    }
    private func execute(_ source: String, _ destination: String, _ identity: Identity, _ parent: Identity, _ batch: UUID) throws {
        guard try Identity.read(source) == identity else { throw RenameError("Source changed before journaling: \(source)") }
        let step = Step(source: source, destination: destination, identity: identity, parent: parent, batch: batch)
        journal.steps.append(step); try save()
        var mutated = false
        do { try move(step, undo: false, mutated: &mutated) }
        catch {
            if !mutated { journal.steps[journal.steps.count - 1].undone = true; try save() }
            throw error
        }
        journal.steps[journal.steps.count - 1].done = true; try save()
    }
    public func apply(_ plan: [PlanItem], cancelled: () -> Bool = { false }, beforeMove: ((PlanItem) throws -> Void)? = nil) throws {
        // Preflight the whole batch: moving this storage (or any ancestor) would
        // detach the journal/lock after an earlier rename had already succeeded.
        func storageKey(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        }
        let storage = [storageKey(journalURL.path), storageKey(journalURL.path + ".lock")]
        for item in plan {
            for path in [item.entry.path, item.destination] {
                let key = storageKey(path)
                guard !storage.contains(where: { $0 == key || $0.hasPrefix(key + "/") }) else {
                    throw RenameError("Cannot rename undo storage or a directory containing it.")
                }
            }
        }
        try reconcile()
        let batch = UUID()
        for item in plan {
            if cancelled() { return }
            try beforeMove?(item)
            // Journal a temporary hop only for filesystem-equivalent case/Unicode changes.
            if let id = try? Identity.read(item.destination), id == item.entry.identity {
                let temporary = URL(fileURLWithPath: item.entry.path).deletingLastPathComponent().appendingPathComponent(".batch-rename-" + UUID().uuidString).path
                try execute(item.entry.path, temporary, item.entry.identity, item.entry.parent, batch)
                try execute(temporary, item.destination, item.entry.identity, item.entry.parent, batch)
            } else { try execute(item.entry.path, item.destination, item.entry.identity, item.entry.parent, batch) }
        }
    }
    public func undo() throws {
        try reconcile()
        // Restore ancestors before children within the latest incomplete batch.
        guard let batch = journal.steps.last(where: { $0.done && !$0.undone })?.batch else { return }
        for i in journal.steps.indices.reversed() where journal.steps[i].done && !journal.steps[i].undone && journal.steps[i].batch == batch {
            journal.undoing = true; try save()
            var mutated = false
            do { try move(journal.steps[i], undo: true, mutated: &mutated) }
            catch {
                // A rejected syscall or validation did not mutate the namespace.
                // Retain completed history without poisoning reload reconciliation.
                if !mutated { journal.undoing = false; try save() }
                throw error
            }
            journal.steps[i].undone = true; journal.undoing = false; try save()
        }
    }
}

func directoryNames(_ path: String) throws -> [String] {
    let fd = try directoryFD(path)
    guard let directory = fdopendir(fd) else { let code = errno; close(fd); throw RenameError("Cannot list folder \(path): \(errnoText(code))") }
    defer { closedir(directory) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name != "." && name != ".." { names.append(name) }
        errno = 0
    }
    guard errno == 0 else { throw RenameError("Cannot list folder \(path): \(errnoText(errno))") }
    return names
}
