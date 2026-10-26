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
}
