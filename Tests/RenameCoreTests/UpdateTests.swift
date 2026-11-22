import XCTest
import CryptoKit
@testable import RenameCore
final class UpdateTests: XCTestCase {
    func testTrustSignatureVersionAndChecksum() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("archive fixture".utf8)
        let url = URL(string: "https://example.invalid/batch-rename-test.zip")!
        let trust = UpdateTrust(publicKey: key.publicKey.rawRepresentation, downloadURL: url)
        var m = UpdateManifest(bundleIdentifier: "com.vortexopenclaw.batch-rename", version: "0.2.0", build: "test", assetKey: "batch-rename/releases/test.zip", downloadURL: url, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), minimumMacOS: "14.0.0")
        m.signature = try key.signature(for: m.signedBytes()).base64EncodedString()
        try UpdatePolicy.validate(m, trust: trust, currentVersion: "0.1.0", osVersion: "14.0.0")
        try UpdatePolicy.validateArchive(data, manifest: m)
        XCTAssertThrowsError(try UpdatePolicy.validateArchive(Data(), manifest: m))
        XCTAssertThrowsError(try UpdatePolicy.validate(m, trust: nil, currentVersion: "0.1.0", osVersion: "14.0.0"))
        XCTAssertThrowsError(try UpdatePolicy.validate(m, trust: trust, currentVersion: "0.2.0", osVersion: "14.0.0"))
        m.bundleIdentifier = "com.vortexopenclaw.dashcam-offloader"
        XCTAssertThrowsError(try UpdatePolicy.validate(m, trust: trust, currentVersion: "0.1.0", osVersion: "14.0.0"))
    }
    func testVersionComponentsRejectLeadingZeros() {
        XCTAssertEqual(UpdatePolicy.version("0.1.3"), [0, 1, 3])
        XCTAssertEqual(UpdatePolicy.version("10.20.30"), [10, 20, 30])
        for bad in ["01.2.3", "0.01.3", "0.1.03", "00.1.3", "0.1.00", "1.2", "1.2.3.4", "1..3", "+1.2.3", "1.2.3 ", "\u{FF11}.2.3"] {
            XCTAssertNil(UpdatePolicy.version(bad), bad)
        }
    }
    func testBundleIdentityUsesParsedVersionsBeforeCodesign() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("version-identity-" + UUID().uuidString)
        let app = root.appendingPathComponent("Candidate.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Byte-equal but unparseable versions must not satisfy identity checks.
        let manifest = UpdateManifest(bundleIdentifier: "com.vortexopenclaw.batch-rename", version: "00.2.0", build: "2", assetKey: "batch-rename/releases/test.zip", downloadURL: URL(string: "https://example.invalid/download")!, sha256: String(repeating: "0", count: 64), minimumMacOS: "14.0.0")
        let info: [String: Any] = ["CFBundleIdentifier": manifest.bundleIdentifier, "CFBundleShortVersionString": manifest.version, "CFBundleVersion": manifest.build, "CFBundleExecutable": "BatchRename", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try UpdateInstaller.validateBundle(app, manifest: manifest)) { error in
            XCTAssertEqual(error.localizedDescription, "Update bundle identity mismatch")
        }
    }
}
