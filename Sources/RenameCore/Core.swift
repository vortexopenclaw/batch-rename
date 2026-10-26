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
public struct RenameOperation: Equatable {
    public var action: Action = .append
    public var scope: Scope = .base
    public var text = ""
    public var search = ""
    public var skipExistingSuffix = true
    public var ignoreCase = false
    public var occurrences: Occurrences = .all
    public init() {}
    public func name(_ original: String, folder: Bool = false) throws -> String {
        try preview(original, folder: folder).name
    }
    public func preview(_ original: String, folder: Bool = false) throws -> NamePreview {
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
            // Exact UTF-8 suffix comparison: no case folding or word deduplication.
            if skipExistingSuffix && !text.isEmpty && value.utf8.suffix(text.utf8.count).elementsEqual(text.utf8) {
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
            let options: String.CompareOptions = ignoreCase ? [.literal, .caseInsensitive] : [.literal]
            var cursor = target.lowerBound
            while cursor < target.upperBound,
                  let match = original.range(of: search, options: options, range: cursor..<target.upperBound, locale: Locale(identifier: "en_US_POSIX")) {
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
        guard !result.name.isEmpty, result.name != ".", result.name != "..", !result.name.contains("/"), !result.name.contains("\0"), !result.name.contains(":") else { throw RenameError("Invalid filename.") }
        return result
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
        guard lstat(path, &s) == 0 else { throw RenameError("Cannot inspect \(path): \(String(cString: strerror(errno)))") }
        return Identity(s)
    }
}
public struct Entry: Identifiable, Equatable, Sendable {
    public var path: String
    public let identity: Identity
    public let parent: Identity
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(_ path: String) throws {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        let fd = try directoryFD(URL(fileURLWithPath: self.path).deletingLastPathComponent().path)
        defer { close(fd) }
        var sourceStat = stat(), parentStat = stat()
        guard fstat(fd, &parentStat) == 0, fstatat(fd, URL(fileURLWithPath: self.path).lastPathComponent, &sourceStat, AT_SYMLINK_NOFOLLOW) == 0 else { throw RenameError("Cannot inspect directory entry: \(self.path)") }
        identity = Identity(sourceStat)
        parent = Identity(parentStat)
        guard identity != parent, identity.device == parent.device else { throw RenameError("Volume roots are not allowed.") }
    }
}
public struct Inventory: Sendable {
    public var roots: [String] = []
    public var files = true, folders = false, recursive = false
    public init() {}
    public mutating func append(_ paths: [String]) { for p in paths { let p = URL(fileURLWithPath: p).standardizedFileURL.path; if !roots.contains(p) { roots.append(p) } } }
    public func scan() throws -> [Entry] {
        var result: [Entry] = [], seen = Set<String>()
        func visit(_ path: String, explicit: Bool, device: Int32?) throws {
            let e = try Entry(path)
            if let device, e.identity.device != device { return }
            if !explicit && e.name.hasPrefix(".") { return }
            let newlySeen = seen.insert(path).inserted
            if !newlySeen && !explicit { return }
            if newlySeen && (e.identity.folder ? folders : files) { result.append(e) }
            guard e.identity.folder else { return }
            let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey, .isAliasFileKey])
            if values.isPackage == true || values.isAliasFile == true { return }
            if explicit || recursive {
                for name in try directoryNames(path).sorted() {
                    let child = URL(fileURLWithPath: path).appendingPathComponent(name).path
                    if name.hasPrefix(".") { continue }
                    let ci = try Identity.read(child)
                    if ci.device != e.identity.device { continue }
                    if ci.folder && !recursive {
                        if folders, seen.insert(child).inserted { result.append(try Entry(child)) }
                    } else { try visit(child, explicit: false, device: e.identity.device) }
                }
            }
        }
        for root in roots { try visit(root, explicit: true, device: nil) }
        return result
    }
}
public struct PlanItem: Sendable {
    public let entry: Entry
    public let destination: String
    public init(entry: Entry, destination: String) { self.entry = entry; self.destination = destination }
}
public enum Planner {
    public static func plan(_ entries: [Entry], operation: RenameOperation) throws -> [PlanItem] {
        var result: [PlanItem] = [], targets = Set<String>()
        for e in entries {
            let name = try operation.name(e.name, folder: e.identity.folder)
            if name.utf8.elementsEqual(e.name.utf8) { continue }
            let parent = URL(fileURLWithPath: e.path).deletingLastPathComponent()
            let max = pathconf(parent.path, _PC_NAME_MAX)
            guard max > 0, name.utf8.count <= max else { throw RenameError("Filename too long: \(name)") }
            let dst = parent.appendingPathComponent(name).path
            guard dst.utf8.count < Int(PATH_MAX) else { throw RenameError("Path too long.") }
            // Conservative alias rejection catches equivalent planned names even on case-sensitive disks.
            let key = dst.precomposedStringWithCanonicalMapping.lowercased()
            guard targets.insert(key).inserted else { throw RenameError("Duplicate proposed name: \(name)") }
            if let existing = try? Identity.read(dst) {
                let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
                let exactDestination = names.contains { $0.utf8.elementsEqual(name.utf8) }
                guard existing == e.identity, !exactDestination else { throw RenameError("Destination exists: \(name)") }
            }
            result.append(PlanItem(entry: e, destination: dst))
        }
        return result.sorted { a, b in
            let ad = a.entry.path.split(separator: "/").count, bd = b.entry.path.split(separator: "/").count
            return ad == bd ? a.entry.path < b.entry.path : ad > bd
        }
    }
}

// Open every ancestor without following symlinks. Hold the parent descriptor through rename.
func directoryFD(_ path: String) throws -> Int32 {
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw RenameError("Cannot open filesystem root.") }
    for component in path.split(separator: "/") {
        let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        close(fd)
        guard next >= 0 else { throw RenameError("An ancestor is unavailable or a symlink: \(path)") }
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
    guard let directory = fdopendir(fd) else { close(fd); throw RenameError("Cannot enumerate directory.") }
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
    guard errno == 0 else { throw RenameError("Directory enumeration failed.") }
    return names
}
