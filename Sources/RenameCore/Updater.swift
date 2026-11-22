import Foundation
import Darwin
import CryptoKit

public struct UpdateConfiguration: Codable {
    public let manifestURL: URL
    public let downloadURL: URL
    public let publicKey: String
    public var trust: UpdateTrust { UpdateTrust(publicKey: Data(base64Encoded: publicKey) ?? Data(), downloadURL: downloadURL) }
    public static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "UpdateConfiguration", withExtension: "json") else { throw RenameError("This build has no update service configured.") }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        for url in [config.manifestURL, config.downloadURL] {
            guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw RenameError("Invalid update endpoint") }
        }
        guard Data(base64Encoded: config.publicKey)?.count == 32 else { throw RenameError("Invalid update public key") }
        return config
    }
}

/// Redirects are rejected: only the two explicitly configured HTTPS endpoints are contacted.
public final class UpdateFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let userAgent: String
    public init(userAgent: String) { self.userAgent = userAgent }
    public convenience init(bundle: Bundle = .main) { self.init(userAgent: Self.userAgent(info: bundle.infoDictionary)) }
    /// Identifies the running bundle; malformed metadata is reported as `unknown`, never copied into the header.
    public static func userAgent(info: [String: Any]?) -> String {
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { UpdatePolicy.version($0) != nil ? $0 : nil } ?? "unknown"
        let build = (info?["CFBundleVersion"] as? String).flatMap { !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) ? $0 : nil } ?? "unknown"
        return "BatchRename/\(version) (\(build)) CFNetwork/Darwin"
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func open(_ url: URL, limit: Int, configuration: URLSessionConfiguration) async throws -> (URLSession.AsyncBytes, URLSession) {
        guard url.scheme == "https" else { throw RenameError("HTTPS is required") }
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, application/zip, application/octet-stream", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= limit else { throw RenameError("Update download rejected") }
            return (bytes, session)
        } catch { session.invalidateAndCancel(); throw error }
    }
    public func fetch(_ url: URL, limit: Int, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        let (bytes, session) = try await open(url, limit: limit, configuration: configuration)
        defer { session.invalidateAndCancel() }
        var data = Data()
        for try await byte in bytes { guard data.count < limit else { throw RenameError("Update exceeds size limit") }; data.append(byte) }
        return data
    }
}

extension UpdateFetcher {
    /// Streams to a new owner-only file while hashing, so memory stays bounded by one chunk.
    /// Returns the lowercase hex SHA-256. Refuses existing paths and links; removes partial output on failure.
    public func download(_ url: URL, to file: URL, limit: Int, configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RenameError("Cannot create update download file: \(errno)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let (bytes, session) = try await open(url, limit: limit, configuration: configuration)
            defer { session.invalidateAndCancel() }
            var hasher = SHA256(), buffer = Data(), total = 0
            let chunk = 64 * 1024
            buffer.reserveCapacity(chunk)
            func flush() throws { hasher.update(data: buffer); try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            for try await byte in bytes {
                total += 1
                guard total <= limit else { throw RenameError("Update exceeds size limit") }
                buffer.append(byte)
                if buffer.count == chunk { try flush() }
            }
            try flush()
            try handle.close()
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            try? handle.close()
            unlink(file.path)
            throw error
        }
    }
}

/// Hidden `.batch-rename-update-UUID` directories beside the app.
public enum UpdateTransactions {
    public static let prefix = ".batch-rename-update-"
    /// Refuses translocated, linked, or unwritable installations before anything is downloaded.
    public static func checkInstallLocation(_ original: URL) throws {
        try UpdateInstaller.physical(original)
        let parent = original.deletingLastPathComponent()
        guard original.pathExtension == "app", !original.path.contains("/AppTranslocation/"),
              access(parent.path, W_OK) == 0, access(original.path, W_OK) == 0 else { throw RenameError("Move the app to a writable installation folder before updating.") }
    }
    /// Creates a private transaction holding only the authenticated `release.zip`.
    /// The parent validates a scratch extraction and deletes it; the helper extracts again.
    /// Any failure removes the whole transaction, since no helper can be using it yet.
    public static func prepare(original: URL, manifest: UpdateManifest, download: (URL) async throws -> String) async throws -> URL {
        try checkInstallLocation(original)
        let transaction = original.deletingLastPathComponent().appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let archive = transaction.appendingPathComponent("release.zip")
            guard try await download(archive) == manifest.sha256 else { throw RenameError("Update checksum mismatch.") }
            let stage = transaction.appendingPathComponent("stage")
            try UpdateArchive.extract(Data(contentsOf: archive, options: .alwaysMapped), to: stage)
            try UpdateInstaller.validateBundle(stage.appendingPathComponent("Batch Rename.app"), manifest: manifest)
            try FileManager.default.removeItem(at: stage)
            return transaction
        } catch {
            discard(transaction)
            throw error
        }
    }
    /// Fields of the app's `plan.json` (written by this and earlier helpers) used for housekeeping.
    struct Record: Decodable { let original: URL; let transaction: URL; let token: String; let manifest: UpdateManifest }
    static let recoveryMarker = "NEEDS-RECOVERY.txt"
    static func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }
    /// Physical transactions beside `original` whose plan names this app and this directory.
    static func records(original: URL) -> [(URL, Record)] {
        let parent = original.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return [] }
        return names.filter { $0.hasPrefix(prefix) }.compactMap { name in
            let directory = parent.appendingPathComponent(name, isDirectory: true)
            var metadata = stat()
            guard lstat(directory.path, &metadata) == 0, metadata.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR), (try? UpdateInstaller.physical(directory)) != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("plan.json")),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  same(record.original, original), same(record.transaction, directory) else { return nil }
            return (directory, record)
        }
    }
    static func needsRecovery(_ directory: URL) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(recoveryMarker).path) }
    /// After a healthy launch: keep only the newest acknowledged transaction, trimmed to its backup
    /// and records. Unacknowledged, recovery-flagged, foreign, or unreadable transactions are never touched.
    public static func cleanUpAfterHealthyLaunch(original: URL) {
        let acknowledged = records(original: original).compactMap { directory, record -> (URL, Date)? in
            guard UpdateHealth.confirmed(at: directory, token: record.token), !needsRecovery(directory),
                  let date = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("healthy").path))?[.modificationDate] as? Date else { return nil }
            return (directory, date)
        }.sorted { $0.1 > $1.1 }
        guard let newest = acknowledged.first?.0 else { return }
        for remnant in ["release.zip", "install", "stage"] { try? FileManager.default.removeItem(at: newest.appendingPathComponent(remnant)) }
        for (older, _) in acknowledged.dropFirst() { try? FileManager.default.removeItem(at: older) }
    }
    /// Clears the recovery marker when the running app is the acknowledged result of that transaction
    /// (for example, the helper timed out before a slow but successful startup acknowledged).
    public static func clearResolvedRecovery(original: URL, runningVersion: String?, runningBuild: String?) {
        for (directory, record) in records(original: original) where needsRecovery(directory) {
            guard UpdateHealth.confirmed(at: directory, token: record.token),
                  UpdatePolicy.sameVersion(record.manifest.version, runningVersion), record.manifest.build == runningBuild else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(recoveryMarker))
        }
    }
    public static func recoveryNotices(original: URL) -> [(transaction: URL, notice: String)] {
        records(original: original).compactMap { directory, _ in
            guard let notice = try? String(contentsOf: directory.appendingPathComponent(recoveryMarker), encoding: .utf8) else { return nil }
            return (directory, notice)
        }
    }
    /// Removes only the notice. Backups and every other recovery file stay in place.
    public static func dismissRecovery(_ transaction: URL, original: URL) throws {
        guard records(original: original).contains(where: { same($0.0, transaction) }) else { throw RenameError("Not an update transaction for this app") }
        try FileManager.default.removeItem(at: transaction.appendingPathComponent(recoveryMarker))
    }
    /// Removes a transaction that no helper has been given.
    public static func discard(_ transaction: URL) {
        guard transaction.lastPathComponent.hasPrefix(prefix), (try? UpdateInstaller.physical(transaction)) != nil else { return }
        try? FileManager.default.removeItem(at: transaction)
    }
}

/// Deliberately restricted ZIP: stored entries, no extras, descriptors, links, ZIP64 or compression.
/// Releases use scripts/release-update.py, not a general-purpose ZIP tool.
public enum UpdateArchive {
    public static func extract(_ data: Data, to destination: URL) throws {
        func fail() -> RenameError { RenameError("Unsafe or unsupported update archive") }
        func n(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, offset + size <= data.count else { throw fail() }
            return (0..<size).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count <= 256 * 1024 * 1024, data.count >= 22 else { throw fail() }
        let end = data.count - 22
        guard (try n(end, 4)) == 0x06054b50, (try n(end+4, 4)) == 0, (try n(end+20, 2)) == 0 else { throw fail() }
        let count = (try n(end+10, 2)), central = (try n(end+16, 4))
        guard count > 0, count < 10000, (try n(end+8, 2)) == count, central + (try n(end+12, 4)) == end else { throw fail() }
        var cursor = central, nextLocal = 0, paths = Set<String>(), entries: [(String, Data, Bool, Bool)] = []
        for _ in 0..<count {
            guard (try n(cursor, 4)) == 0x02014b50, (try n(cursor+8, 2)) == 0, (try n(cursor+10, 2)) == 0,
                  (try n(cursor+30, 2)) == 0, (try n(cursor+32, 2)) == 0, (try n(cursor+34, 2)) == 0 else { throw fail() }
            let size = (try n(cursor+24, 4)), length = (try n(cursor+28, 2)), local = (try n(cursor+42, 4)), mode = (try n(cursor+38, 4)) >> 16
            guard size == ((try n(cursor+20, 4))), local == nextLocal, cursor+46+length <= end,
                  let path = String(data: data[(cursor+46)..<(cursor+46+length)], encoding: .utf8) else { throw fail() }
            let directory = path.hasSuffix("/")
            let clean = directory ? String(path.dropLast()) : path
            let components = clean.split(separator: "/", omittingEmptySubsequences: false)
            guard components.first == "Batch Rename.app", components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") && !$0.contains("\\") && !$0.contains("\0") }),
                  paths.insert(clean.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  mode & 0o170000 == (directory ? 0o040000 : 0o100000),
                  (try n(local, 4)) == 0x04034b50, (try n(local+6, 2)) == 0, (try n(local+8, 2)) == 0,
                  (try n(local+18, 4)) == size, (try n(local+22, 4)) == size, (try n(local+26, 2)) == length, (try n(local+28, 2)) == 0,
                  (try n(local+14, 4)) == (try n(cursor+16, 4)) else { throw fail() }
            let start = local+30+length
            guard start+size <= central, data[(local+30)..<start] == data[(cursor+46)..<(cursor+46+length)], !directory || size == 0 else { throw fail() }
            entries.append((clean, Data(data[start..<(start+size)]), directory, mode & 0o111 != 0))
            nextLocal = start+size; cursor += 46+length
        }
        guard cursor == end, nextLocal == central, !FileManager.default.fileExists(atPath: destination.path) else { throw fail() }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Entire archive has been validated before any entry is written. Private destination contains no existing links.
        for (path, bytes, directory, executable) in entries {
            let target = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory ? target : target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !directory { try bytes.write(to: target, options: .withoutOverwriting); try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: target.path) }
        }
    }
}

public enum UpdateInstaller {
    static func minimumMacOS(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let count = text.split(separator: ".", omittingEmptySubsequences: false).count
        guard count == 2 || count == 3,
              let parts = UpdatePolicy.version(count == 2 ? text + ".0" : text) else { return nil }
        return parts.map(String.init).joined(separator: ".")
    }
    public static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RenameError("Update command failed: \(executable)") }
    }
    public static func validateBundle(_ app: URL, manifest: UpdateManifest) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              dict["CFBundleIdentifier"] as? String == manifest.bundleIdentifier,
              UpdatePolicy.sameVersion(dict["CFBundleShortVersionString"] as? String, manifest.version),
              dict["CFBundleVersion"] as? String == manifest.build,
              dict["CFBundleExecutable"] as? String == "BatchRename" else { throw RenameError("Update bundle identity mismatch") }
        guard let minimum = minimumMacOS(dict["LSMinimumSystemVersion"]),
              let required = UpdatePolicy.version(manifest.minimumMacOS),
              minimum == required.map(String.init).joined(separator: ".") else { throw RenameError("Update bundle compatibility mismatch") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
    public static func physical(_ url: URL) throws {
        guard url.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw RenameError("Update paths must not contain symbolic links") }
    }
    /// Never deletes the backup. Only `UpdateTransactions.cleanUpAfterHealthyLaunch` prunes
    /// backups, and only for older acknowledged transactions.
    public static func replace(original: URL, staged: URL, backup: URL, launch: () throws -> Void) throws {
        for url in [original, staged, backup] { try physical(url) }
        guard !FileManager.default.fileExists(atPath: backup.path) else { throw RenameError("Backup already exists") }
        func move(_ source: URL, _ destination: URL) throws {
            guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw RenameError("Exclusive update move failed: \(errno)") }
        }
        func restore() throws {
            let copy = backup.deletingLastPathComponent().appendingPathComponent("restore-" + UUID().uuidString + ".app")
            try FileManager.default.copyItem(at: backup, to: copy)
            try move(copy, original)
        }
        try move(original, backup)
        do { try move(staged, original) }
        catch { try? restore(); throw error }
        do { try launch() }
        catch {
            // Preserve the failed candidate too; never overwrite another process's destination.
            let failed = backup.deletingLastPathComponent().appendingPathComponent("failed-" + UUID().uuidString + ".app")
            do { try move(original, failed); try restore() } catch { /* Original remains in backup if rollback cannot complete. */ }
            throw error
        }
    }
}

public enum UpdateHealth {
    public static func acknowledge(at directory: URL, token: String, expectedToken: String, healthy: Bool) throws {
        guard healthy, UUID(uuidString: token) != nil, token == expectedToken else { throw RenameError("Startup acknowledgment rejected") }
        try UpdateInstaller.physical(directory)
        try Data(token.utf8).write(to: directory.appendingPathComponent("healthy"), options: .withoutOverwriting)
    }
    public static func confirmed(at directory: URL, token: String) -> Bool {
        (try? String(contentsOf: directory.appendingPathComponent("healthy"), encoding: .utf8)) == token
    }
}
