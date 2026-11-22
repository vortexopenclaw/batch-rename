import XCTest
import CryptoKit
@testable import RenameCore

let fixtureUserAgent = "BatchRename/9.8.7 (65) CFNetwork/Darwin"
final class DownloadFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), fixtureUserAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, application/zip, application/octet-stream")
        if request.url!.path == "/fail" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let status = request.url!.path == "/404" ? 404 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        let body = ["/large": Self.large, "/bundle": Self.bundle][request.url!.path] ?? Data("fixture".utf8)
        // Several chunks, so streaming crosses buffer boundaries.
        var offset = 0
        while offset < body.count { let next = min(offset + 100_000, body.count); client?.urlProtocol(self, didLoad: body.subdata(in: offset..<next)); offset = next }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static let large = Data((0..<300_001).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    static var bundle = Data()
}
func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func posixMode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
final class UpdaterTests: XCTestCase {
    func testBundleMinimumNormalization() {
        XCTAssertEqual(UpdateInstaller.minimumMacOS("14.0"), "14.0.0")
        XCTAssertEqual(UpdateInstaller.minimumMacOS("15.2.1"), "15.2.1")
        XCTAssertNil(UpdateInstaller.minimumMacOS("999999999999999999999999.0"))
    }
    func testBundleRejectsMissingMalformedOrMismatchedMinimumBeforeCodesign() throws {
        let app = try root().appendingPathComponent("Candidate.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let manifest = UpdateManifest(bundleIdentifier: "com.vortexopenclaw.batch-rename", version: "0.2.0", build: "2", assetKey: "batch-rename/releases/test.zip", downloadURL: URL(string: "https://example.invalid/download")!, sha256: String(repeating: "0", count: 64), minimumMacOS: "14.0.0")
        for minimum: Any? in [nil, "", "14", "14.", "14..0", "14.0.0.1", "14.0-beta", " 14.0", "14.0\n", "１４.０", 14, true, "15.0"] {
            var info: [String: Any] = ["CFBundleIdentifier": manifest.bundleIdentifier, "CFBundleShortVersionString": manifest.version, "CFBundleVersion": manifest.build, "CFBundleExecutable": "BatchRename"]
            info["LSMinimumSystemVersion"] = minimum
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            XCTAssertThrowsError(try UpdateInstaller.validateBundle(app, manifest: manifest)) { error in
                XCTAssertEqual(error.localizedDescription, "Update bundle compatibility mismatch", "minimum: \(String(describing: minimum))")
            }
        }
    }
    func root() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("updater-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    // Exact release ZIP subset, with caller-controlled path/type for malicious fixtures.
    func zip(_ path: String = "Batch Rename.app/Contents/test", mode: Int = 0o100644) -> Data {
        zip(entries: [(path, Data("fixture".utf8), mode)])
    }
    func zip(entries: [(String, Data, Int)]) -> Data {
        var data = Data(), centralRecords = Data()
        func n(_ number: Int, _ width: Int, into target: inout Data) { for i in 0..<width { target.append(UInt8((number >> (8*i)) & 255)) } }
        for (path, content, mode) in entries {
            let name = Data(path.utf8), local = data.count
            for (value, width) in [(0x04034b50,4), (20,2), (0,2), (0,2), (0,4), (0,4), (content.count,4), (content.count,4), (name.count,2), (0,2)] { n(value, width, into: &data) }
            data.append(name); data.append(content)
            for (value, width) in [(0x02014b50,4), (0x0314,2), (20,2), (0,2), (0,2), (0,4), (0,4), (content.count,4), (content.count,4), (name.count,2), (0,2), (0,2), (0,2), (0,2), (mode << 16,4), (local,4)] { n(value, width, into: &centralRecords) }
            centralRecords.append(name)
        }
        let central = data.count
        data.append(centralRecords)
        for (value, width) in [(0x06054b50,4), (0,4), (entries.count,2), (entries.count,2), (centralRecords.count,4), (central,4), (0,2)] { n(value, width, into: &data) }
        return data
    }
    /// Minimal ad-hoc signed bundle archived in the release ZIP layout.
    func signedBundleArchive(version: String, build: String) throws -> Data {
        let source = try root(), app = source.appendingPathComponent("Batch Rename.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/BatchRename"))
        let info: [String: Any] = ["CFBundleIdentifier": UpdateFixture.bundleIdentifier, "CFBundleShortVersionString": version, "CFBundleVersion": build, "CFBundleExecutable": "BatchRename", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        let paths = FileManager.default.enumerator(atPath: app.path)!.compactMap { $0 as? String }.sorted()
        var entries: [(String, Data, Int)] = [("Batch Rename.app/", Data(), 0o040755)]
        for path in paths {
            let url = app.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { entries.append(("Batch Rename.app/\(path)/", Data(), 0o040755)) }
            else { entries.append(("Batch Rename.app/\(path)", try Data(contentsOf: url), try posixMode(url) & 0o111 != 0 ? 0o100755 : 0o100644)) }
        }
        return zip(entries: entries)
    }
    func updateTransactions(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".batch-rename-update-") }
    }
    func testStreamingDownloadIsOwnerOnlyHashedAndBounded() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DownloadFixture.self]
        let fetcher = UpdateFetcher(userAgent: fixtureUserAgent), root = try root()
        let large = URL(string: "https://example.invalid/large")!, file = root.appendingPathComponent("release.zip")
        let digest = try await fetcher.download(large, to: file, limit: DownloadFixture.large.count, configuration: configuration)
        XCTAssertEqual(digest, sha256Hex(DownloadFixture.large))
        XCTAssertEqual(try Data(contentsOf: file), DownloadFixture.large)
        XCTAssertEqual(try posixMode(file), 0o600)
        for (name, url, limit) in [("over", large, DownloadFixture.large.count - 1), ("404", URL(string: "https://example.invalid/404")!, 100), ("fail", URL(string: "https://example.invalid/fail")!, 100)] {
            let target = root.appendingPathComponent(name)
            do { _ = try await fetcher.download(url, to: target, limit: limit, configuration: configuration); XCTFail("Accepted \(name)") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "partial \(name) removed")
        }
        // Never overwrite or follow an existing destination.
        let existing = root.appendingPathComponent("existing"), link = root.appendingPathComponent("link")
        try Data("keep".utf8).write(to: existing)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        for target in [existing, link] {
            do { _ = try await fetcher.download(large, to: target, limit: DownloadFixture.large.count, configuration: configuration); XCTFail("Overwrote \(target.lastPathComponent)") } catch {}
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
    }
    func testPrepareChecksLocationBeforeDownloadAndRemovesFailedTransactions() async throws {
        let root = try root(), archive = try signedBundleArchive(version: UpdateFixture.releaseVersion, build: UpdateFixture.releaseBuild)
        let manifest = UpdateFixture.manifest(sha256: sha256Hex(archive))
        let install = root.appendingPathComponent("Applications"), original = install.appendingPathComponent("Batch Rename.app")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        var downloads = 0
        func expectFailure(_ original: URL, _ manifest: UpdateManifest, _ label: String, download: @escaping (URL) async throws -> String) async throws {
            do { _ = try await UpdateTransactions.prepare(original: original, manifest: manifest) { downloads += 1; return try await download($0) }; XCTFail("Accepted \(label)") } catch {}
            XCTAssertEqual(try updateTransactions(in: original.deletingLastPathComponent()), [], "\(label) left a transaction")
        }
        // Location problems are reported before any download starts.
        let translocated = root.appendingPathComponent("AppTranslocation/ABC/d/Batch Rename.app")
        try FileManager.default.createDirectory(at: translocated, withIntermediateDirectories: true)
        try await expectFailure(translocated, manifest, "translocated") { _ in "" }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: install.path)
        try await expectFailure(original, manifest, "read-only folder") { _ in "" }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: install.path)
        XCTAssertEqual(downloads, 0)
        // Any failure before the helper exists removes the whole transaction.
        try await expectFailure(original, manifest, "download error") { _ in throw URLError(.networkConnectionLost) }
        try await expectFailure(original, manifest, "checksum") { url in try archive.write(to: url); return String(repeating: "0", count: 64) }
        try await expectFailure(original, UpdateFixture.manifest(sha256: sha256Hex(archive), build: "99"), "bundle identity") { url in try archive.write(to: url); return sha256Hex(archive) }
        try await expectFailure(original, UpdateFixture.manifest(sha256: sha256Hex(zip())), "unsafe archive") { url in try self.zip().write(to: url); return sha256Hex(self.zip()) }
        XCTAssertEqual(downloads, 4)
        // Success keeps only the authenticated archive; the helper re-extracts it.
        DownloadFixture.bundle = archive
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DownloadFixture.self]
        let transaction = try await UpdateTransactions.prepare(original: original, manifest: manifest) {
            try await UpdateFetcher(userAgent: fixtureUserAgent).download(URL(string: "https://example.invalid/bundle")!, to: $0, limit: 256 * 1024 * 1024, configuration: configuration)
        }
        XCTAssertEqual(try updateTransactions(in: install), [transaction.lastPathComponent])
        XCTAssertEqual(try posixMode(transaction), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: transaction.path), ["release.zip"])
        XCTAssertEqual(try posixMode(transaction.appendingPathComponent("release.zip")), 0o600)
        XCTAssertEqual(try Data(contentsOf: transaction.appendingPathComponent("release.zip")), archive)
    }
    func testRestrictedArchiveAndMaliciousPaths() throws {
        let root = try root(), destination = root.appendingPathComponent("good")
        try UpdateArchive.extract(zip(), to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Batch Rename.app/Contents/test"), encoding: .utf8), "fixture")
        for path in ["../escape", "/absolute", "Batch Rename.app/../escape", "Batch Rename.app//bad", "Batch Rename.app/./bad", "Batch Rename.app/a\\b", "Batch Rename.app/a:b", "Other.app/file", "Batch Rename.app/a\0b"] {
            XCTAssertThrowsError(try UpdateArchive.extract(zip(path), to: root.appendingPathComponent(UUID().uuidString)), path)
        }
        XCTAssertThrowsError(try UpdateArchive.extract(zip(mode: 0o120777), to: root.appendingPathComponent("link")))
        for length in [0, 21, 40, zip().count-1] { XCTAssertThrowsError(try UpdateArchive.extract(Data(zip().prefix(length)), to: root.appendingPathComponent(UUID().uuidString))) }
        var bad = zip(); bad[8] = 8
        XCTAssertThrowsError(try UpdateArchive.extract(bad, to: root.appendingPathComponent("compressed")))
        XCTAssertThrowsError(try UpdateArchive.extract(zip(), to: destination))
    }
    func testAllSignedFieldsAndVersionGates() throws {
        let key = Curve25519.Signing.PrivateKey(), url = URL(string: "https://example.invalid/batch-rename/download")!
        let trust = UpdateTrust(publicKey: key.publicKey.rawRepresentation, downloadURL: url)
        let m = try UpdateManifest(bundleIdentifier: "com.vortexopenclaw.batch-rename", version: "0.2.0", build: "2", assetKey: "batch-rename/releases/test.zip", downloadURL: url, sha256: SHA256.hash(data: zip()).map { String(format: "%02x", $0) }.joined(), minimumMacOS: "14.0.0").signed(with: key)
        // Envelope tampering is covered field by field in UpdateTests.
        let fields = ["bundleIdentifier", "version", "build", "assetKey", "downloadURL", "sha256", "minimumMacOS"]
        for field in fields {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
            object[field] = field == "downloadURL" ? "https://example.invalid/evil" : "tampered"
            let bad = try JSONDecoder().decode(UpdateManifest.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try UpdatePolicy.validate(bad, trust: trust, currentVersion: "0.1.0", osVersion: "14.0.0"), field)
        }
        try UpdatePolicy.validate(m, trust: trust, currentVersion: "0.2.0", osVersion: "14.0.0", allowCurrent: true)
        for current in ["0.2.0", "1.0.0", "invalid"] { XCTAssertThrowsError(try UpdatePolicy.validate(m, trust: trust, currentVersion: current, osVersion: "14.0.0")) }
        XCTAssertThrowsError(try UpdatePolicy.validate(m, trust: trust, currentVersion: "0.1.0", osVersion: "13.9.0"))
        var tampered = zip(); tampered[35] ^= 1
        XCTAssertThrowsError(try UpdatePolicy.validateArchive(tampered, manifest: m))
    }
    func testInstallFailuresRetainOriginalAndSuccessfulBackup() throws {
        let root = try root(), original = root.appendingPathComponent("original.app"), staged = root.appendingPathComponent("new.app"), backup = root.appendingPathComponent("backup.app")
        try Data("original".utf8).write(to: original)
        XCTAssertThrowsError(try UpdateInstaller.replace(original: original, staged: staged, backup: backup) {})
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
        try FileManager.default.removeItem(at: backup) // fixture cleanup between independent attempts
        try Data("new".utf8).write(to: staged)
        XCTAssertThrowsError(try UpdateInstaller.replace(original: original, staged: staged, backup: backup) { throw RenameError("launch failed") })
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
        try FileManager.default.removeItem(at: backup) // fixture cleanup between independent attempts
        try Data("new".utf8).write(to: staged)
        try UpdateInstaller.replace(original: original, staged: staged, backup: backup) {}
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
        XCTAssertThrowsError(try UpdateInstaller.replace(original: original, staged: staged, backup: backup) {})
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
    }
    func testHealthAcknowledgmentRequiresTokenAndHealthyStartup() throws {
        let root = try root(), token = UUID().uuidString
        XCTAssertFalse(UpdateHealth.confirmed(at: root, token: token))
        XCTAssertThrowsError(try UpdateHealth.acknowledge(at: root, token: token, expectedToken: token, healthy: false))
        XCTAssertThrowsError(try UpdateHealth.acknowledge(at: root, token: UUID().uuidString, expectedToken: token, healthy: true))
        try UpdateHealth.acknowledge(at: root, token: token, expectedToken: token, healthy: true)
        XCTAssertTrue(UpdateHealth.confirmed(at: root, token: token))
        XCTAssertFalse(UpdateHealth.confirmed(at: root, token: UUID().uuidString))
    }
    func testDownloadFailuresAndBounds() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DownloadFixture.self]
        for path in ["fail", "404", "too-large"] {
            do { _ = try await UpdateFetcher(userAgent: fixtureUserAgent).fetch(URL(string: "https://example.invalid/" + path)!, limit: path == "too-large" ? 3 : 100, configuration: configuration); XCTFail("Accepted \(path)") } catch {}
        }
        let data = try await UpdateFetcher(userAgent: fixtureUserAgent).fetch(URL(string: "https://example.invalid/good")!, limit: 100, configuration: configuration)
        XCTAssertEqual(data, Data("fixture".utf8))
    }
    func testUserAgentComesFromRunningBundle() throws {
        XCTAssertEqual(UpdateFetcher.userAgent(info: ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "65"]), fixtureUserAgent)
        XCTAssertEqual(UpdateFetcher.userAgent(info: ["CFBundleShortVersionString": "0.1.4", "CFBundleVersion": "5"]), "BatchRename/0.1.4 (5) CFNetwork/Darwin")
        // Missing or malformed metadata never leaks arbitrary text into the header.
        XCTAssertEqual(UpdateFetcher.userAgent(info: nil), "BatchRename/unknown (unknown) CFNetwork/Darwin")
        XCTAssertEqual(UpdateFetcher.userAgent(info: ["CFBundleShortVersionString": "1.0.0\r\nX: y", "CFBundleVersion": "5 6"]), "BatchRename/unknown (unknown) CFNetwork/Darwin")
        let app = try root().appendingPathComponent("Agent.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.agent", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "65"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(UpdateFetcher(bundle: try XCTUnwrap(Bundle(url: app))).userAgent, fixtureUserAgent)
    }
}
