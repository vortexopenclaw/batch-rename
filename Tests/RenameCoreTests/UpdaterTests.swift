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
        client?.urlProtocol(self, didLoad: Data("fixture".utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
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
        var data = Data()
        func n(_ number: Int, _ width: Int) { for i in 0..<width { data.append(UInt8((number >> (8*i)) & 255)) } }
        let name = Data(path.utf8), content = Data("fixture".utf8)
        n(0x04034b50,4); n(20,2); n(0,2); n(0,2); n(0,4); n(0,4); n(content.count,4); n(content.count,4); n(name.count,2); n(0,2); data.append(name); data.append(content)
        let central = data.count
        n(0x02014b50,4); n(0x0314,2); n(20,2); n(0,2); n(0,2); n(0,4); n(0,4); n(content.count,4); n(content.count,4); n(name.count,2); n(0,2); n(0,2); n(0,2); n(0,2); n(mode << 16,4); n(0,4); data.append(name)
        let size = data.count-central
        n(0x06054b50,4); n(0,4); n(1,2); n(1,2); n(size,4); n(central,4); n(0,2)
        return data
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
