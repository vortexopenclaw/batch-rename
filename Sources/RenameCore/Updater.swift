import Foundation
import Darwin

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
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    public func fetch(_ url: URL, limit: Int, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        guard url.scheme == "https" else { throw RenameError("HTTPS is required") }
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= limit else { throw RenameError("Update download rejected") }
        var data = Data()
        for try await byte in bytes { guard data.count < limit else { throw RenameError("Update exceeds size limit") }; data.append(byte) }
        return data
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
    public static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RenameError("Update command failed: \(executable)") }
    }
    public static func validateBundle(_ app: URL, manifest: UpdateManifest) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              dict["CFBundleIdentifier"] as? String == manifest.bundleIdentifier,
              dict["CFBundleShortVersionString"] as? String == manifest.version,
              dict["CFBundleVersion"] as? String == manifest.build,
              dict["CFBundleExecutable"] as? String == "BatchRename" else { throw RenameError("Update bundle identity mismatch") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
    public static func physical(_ url: URL) throws {
        guard url.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw RenameError("Update paths must not contain symbolic links") }
    }
    /// Backup is never deleted automatically, including after acknowledgment.
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
