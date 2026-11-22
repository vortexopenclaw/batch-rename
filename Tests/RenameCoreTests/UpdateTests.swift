import XCTest
import CryptoKit
@testable import RenameCore

/// Shared synthetic release identity. Never the production key or a published release.
enum UpdateFixture {
    static let bundleIdentifier = "com.vortexopenclaw.batch-rename"
    static let installedVersion = "1.4.0"
    static let releaseVersion = "1.5.0"
    static let releaseBuild = "15"
    static let osVersion = "14.0.0"
    static let downloadURL = URL(string: "https://example.invalid/batch-rename/download")!
    static func manifest(sha256: String = String(repeating: "0", count: 64), version: String = releaseVersion, build: String = releaseBuild) -> UpdateManifest {
        UpdateManifest(bundleIdentifier: bundleIdentifier, version: version, build: build, assetKey: "batch-rename/releases/batch-rename-\(version.replacingOccurrences(of: ".", with: "_"))-\(build)-\(sha256).zip", downloadURL: downloadURL, sha256: sha256, minimumMacOS: "14.0.0")
    }
    /// Bytes exactly as scripts/sign-update.swift writes them.
    static func published(_ manifest: UpdateManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
}

// MARK: Frozen 0.1.3 client verification (copied from b180a67 Sources/RenameCore/UpdatePolicy.swift).
// Do not "fix" or modernize this copy: it stands in for clients already installed in the field.
struct LegacyManifest013: Codable {
    var bundleIdentifier: String
    var version: String
    var build: String
    var assetKey: String
    var downloadURL: URL
    var sha256: String
    var minimumMacOS: String
    var signature: String?
    func signedBytes() throws -> Data {
        var unsigned = self; unsigned.signature = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(unsigned)
    }
}
enum LegacyPolicy013 {
    static func version(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }
    static func validate(_ manifest: LegacyManifest013, trust: UpdateTrust?, currentVersion: String, osVersion: String, allowCurrent: Bool = false) throws {
        guard let trust else { throw RenameError("Updates are not configured.") }
        guard manifest.bundleIdentifier == "com.vortexopenclaw.batch-rename",
              manifest.downloadURL == trust.downloadURL, trust.downloadURL.scheme == "https",
              manifest.assetKey.hasPrefix("batch-rename/releases/"),
              !manifest.assetKey.contains(".."), !manifest.assetKey.contains("\\"),
              manifest.assetKey.split(separator: "/").count == 3,
              manifest.assetKey.hasSuffix(".zip"), !manifest.build.isEmpty,
              manifest.sha256.count == 64, manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let remote = version(manifest.version), let local = version(currentVersion),
              (local.lexicographicallyPrecedes(remote) || (allowCurrent && local == remote)),
              let minimum = version(manifest.minimumMacOS), let os = version(osVersion), !os.lexicographicallyPrecedes(minimum),
              let signatureText = manifest.signature, let signature = Data(base64Encoded: signatureText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trust.publicKey),
              key.isValidSignature(signature, for: try manifest.signedBytes()) else { throw RenameError("Update identity, signature, version, or compatibility validation failed.") }
    }
    static func validateArchive(_ data: Data, manifest: LegacyManifest013) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == manifest.sha256 else { throw RenameError("Update checksum mismatch.") }
    }
}

final class UpdateTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    var trust: UpdateTrust { UpdateTrust(publicKey: key.publicKey.rawRepresentation, downloadURL: UpdateFixture.downloadURL) }
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func validate(_ m: UpdateManifest, highest: Int = 0) throws { try UpdatePolicy.validate(m, trust: trust, currentVersion: UpdateFixture.installedVersion, osVersion: UpdateFixture.osVersion, highestSequence: highest) }

    func testTrustSignatureVersionAndChecksum() throws {
        let data = Data("archive fixture".utf8)
        var m = try UpdateFixture.manifest(sha256: digest(data)).signed(with: key)
        try validate(m)
        try UpdatePolicy.validateArchive(data, manifest: m)
        XCTAssertThrowsError(try UpdatePolicy.validateArchive(Data(), manifest: m))
        XCTAssertThrowsError(try UpdatePolicy.validate(m, trust: nil, currentVersion: UpdateFixture.installedVersion, osVersion: UpdateFixture.osVersion))
        XCTAssertThrowsError(try UpdatePolicy.validate(m, trust: trust, currentVersion: UpdateFixture.releaseVersion, osVersion: UpdateFixture.osVersion))
        m.bundleIdentifier = "com.vortexopenclaw.dashcam-offloader"
        XCTAssertThrowsError(try validate(m))
    }
    func testFrozenLegacyClientAcceptsNewlySignedManifest() throws {
        let archive = Data("archive fixture".utf8)
        let published = try UpdateFixture.published(UpdateFixture.manifest(sha256: digest(archive)).signed(with: key))
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: published) as? [String: Any])?["envelope"], "fixture must carry the new envelope")
        // Exactly what an installed 0.1.3 client does with the downloaded bytes.
        let legacy = try JSONDecoder().decode(LegacyManifest013.self, from: published)
        try LegacyPolicy013.validate(legacy, trust: trust, currentVersion: "0.1.3", osVersion: UpdateFixture.osVersion, allowCurrent: true)
        try LegacyPolicy013.validateArchive(archive, manifest: legacy)
        // The production legacy bytes are unchanged, so both encoders agree exactly.
        XCTAssertEqual(try legacy.signedBytes(), try JSONDecoder().decode(UpdateManifest.self, from: published).signedBytes())
        XCTAssertTrue(UpdatePolicy.hasValidLegacySignature(try JSONDecoder().decode(UpdateManifest.self, from: published), publicKey: key.publicKey.rawRepresentation))
        // Negative control: the frozen verifier still rejects a tampered legacy field.
        var tampered = legacy; tampered.sha256 = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try LegacyPolicy013.validate(tampered, trust: trust, currentVersion: "0.1.3", osVersion: UpdateFixture.osVersion))
    }
    func testEnvelopeIsRequiredAndCoversEveryPayloadField() throws {
        let m = try UpdateFixture.manifest().signed(with: key)
        try validate(m)
        var legacyOnly = m; legacyOnly.envelope = nil
        XCTAssertTrue(UpdatePolicy.hasValidLegacySignature(legacyOnly, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try validate(legacyOnly), "legacy-only manifest")
        let envelope = try XCTUnwrap(m.envelope)
        let payload = try XCTUnwrap(Data(base64Encoded: envelope.payload))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "bundleIdentifier", "version", "build", "assetKey", "downloadURL", "sha256", "minimumMacOS", "issuedAt", "sequence"])
        for field in object.keys {
            var changed = object
            switch object[field] {
            case let number as Int: changed[field] = number + 1
            case let text as String: changed[field] = field == "downloadURL" ? "https://example.invalid/evil" : text + "0"
            default: XCTFail(field)
            }
            var bad = m
            bad.envelope?.payload = try JSONSerialization.data(withJSONObject: changed, options: .sortedKeys).base64EncodedString()
            XCTAssertThrowsError(try validate(bad), "tampered payload \(field)")
        }
        var badSignature = m; badSignature.envelope?.signature = try key.signature(for: Data("other".utf8)).base64EncodedString()
        XCTAssertThrowsError(try validate(badSignature), "envelope signature")
        var notBase64 = m; notBase64.envelope?.payload = "%%%"
        XCTAssertThrowsError(try validate(notBase64), "payload encoding")
        var otherKey = m; otherKey.envelope = try UpdateFixture.manifest().signed(with: Curve25519.Signing.PrivateKey()).envelope
        XCTAssertThrowsError(try validate(otherKey), "untrusted envelope key")
    }
    func testTopLevelFieldsMustEqualSignedPayload() throws {
        let m = try UpdateFixture.manifest().signed(with: key)
        for field in ["bundleIdentifier", "version", "build", "assetKey", "downloadURL", "sha256", "minimumMacOS"] {
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: UpdateFixture.published(m)) as? [String: Any])
            object[field] = ["version": "1.6.0", "build": "16", "downloadURL": "https://example.invalid/batch-rename/other", "sha256": String(repeating: "a", count: 64), "minimumMacOS": "14.1.0", "assetKey": "batch-rename/releases/other.zip"][field] ?? "tampered"
            var bad = try JSONDecoder().decode(UpdateManifest.self, from: JSONSerialization.data(withJSONObject: object))
            bad.signature = try key.signature(for: bad.signedBytes()).base64EncodedString() // valid for old clients
            XCTAssertThrowsError(try validate(bad), field)
        }
    }
    func testStrictPayloadSchemaRejectsUnknownMissingAndWrongValues() throws {
        let m = try UpdateFixture.manifest().signed(with: key)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: XCTUnwrap(m.envelope).payload))) as? [String: Any])
        var cases: [String: [String: Any]] = [:]
        cases["unknown key"] = object.merging(["channel": "beta"]) { a, _ in a }
        cases["schema 2"] = object.merging(["schema": 2]) { _, b in b }
        cases["schema string"] = object.merging(["schema": "1"]) { _, b in b }
        cases["sequence not build"] = object.merging(["sequence": 99]) { _, b in b }
        cases["issuedAt malformed"] = object.merging(["issuedAt": "yesterday"]) { _, b in b }
        var missing = object; missing.removeValue(forKey: "issuedAt"); cases["missing issuedAt"] = missing
        for (name, value) in cases {
            let bytes = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            var bad = m
            bad.envelope = UpdateEnvelope(payload: bytes.base64EncodedString(), signature: try key.signature(for: bytes).base64EncodedString())
            XCTAssertThrowsError(try validate(bad), name)
        }
        XCTAssertThrowsError(try UpdateFixture.manifest(build: "015").signed(with: key), "non-canonical build cannot become a sequence")
    }
    func testOlderSequenceThanAlreadySeenIsRejected() throws {
        let m = try UpdateFixture.manifest().signed(with: key)
        let sequence = try XCTUnwrap(Int(UpdateFixture.releaseBuild))
        XCTAssertEqual(try UpdatePolicy.validate(m, trust: trust, currentVersion: UpdateFixture.installedVersion, osVersion: UpdateFixture.osVersion).sequence, sequence)
        try validate(m, highest: sequence)
        XCTAssertThrowsError(try validate(m, highest: sequence + 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("older than an update already seen"), error.localizedDescription)
        }
        let suite = "batch-rename-sequence-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = UpdateSequenceStore(defaults: defaults)
        XCTAssertEqual(store.highest, 0)
        let payload = try UpdatePolicy.validate(m, trust: trust, currentVersion: UpdateFixture.installedVersion, osVersion: UpdateFixture.osVersion, highestSequence: store.highest)
        store.record(payload)
        XCTAssertEqual(store.highest, sequence)
        var older = payload; older.sequence = sequence - 1; store.record(older)
        XCTAssertEqual(store.highest, sequence, "never lowered")
        XCTAssertThrowsError(try validate(UpdateFixture.manifest(version: "1.4.1", build: "14").signed(with: key), highest: store.highest))
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
        let manifest = UpdateFixture.manifest(version: "00.2.0")
        let info: [String: Any] = ["CFBundleIdentifier": manifest.bundleIdentifier, "CFBundleShortVersionString": manifest.version, "CFBundleVersion": manifest.build, "CFBundleExecutable": "BatchRename", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try UpdateInstaller.validateBundle(app, manifest: manifest)) { error in
            XCTAssertEqual(error.localizedDescription, "Update bundle identity mismatch")
        }
    }
}
