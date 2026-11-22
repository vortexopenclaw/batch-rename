import Foundation
import CryptoKit

/// Signed release policy shared by the in-app updater and release signer.
///
/// Two signatures cover one release:
/// - `signature` (legacy): Ed25519 over the sorted-key JSON re-encoding of the seven
///   top-level fields. Installed 0.1.x clients verify only this; its bytes must never change.
/// - `envelope`: Ed25519 over the exact raw payload bytes. Current clients require it,
///   decode the payload strictly, and require the top-level fields to equal it.
public struct UpdateManifest: Codable {
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var assetKey: String
    public var downloadURL: URL
    public var sha256: String
    public var minimumMacOS: String
    public var signature: String?
    public var envelope: UpdateEnvelope?
    /// Legacy signed bytes. Optional fields are omitted when nil, so clearing `signature`
    /// and `envelope` reproduces the 0.1.x encoding byte-for-byte.
    public func signedBytes() throws -> Data {
        var unsigned = self; unsigned.signature = nil; unsigned.envelope = nil
        return try UpdatePolicy.encoder().encode(unsigned)
    }
    /// Produces both signatures. `issuedAt` is informational; there is deliberately no expiry.
    public func signed(with key: Curve25519.Signing.PrivateKey, issuedAt: Date = Date()) throws -> UpdateManifest {
        guard let sequence = UpdatePayload.sequence(forBuild: build) else { throw RenameError("Release build must be a positive integer without leading zeros.") }
        var manifest = self; manifest.signature = nil; manifest.envelope = nil
        manifest.signature = try key.signature(for: manifest.signedBytes()).base64EncodedString()
        let payload = UpdatePayload(schema: UpdatePayload.currentSchema, bundleIdentifier: bundleIdentifier, version: version, build: build, assetKey: assetKey, downloadURL: downloadURL, sha256: sha256, minimumMacOS: minimumMacOS, issuedAt: UpdatePayload.timestamp(issuedAt), sequence: sequence)
        let bytes = try UpdatePolicy.encoder().encode(payload)
        manifest.envelope = UpdateEnvelope(payload: bytes.base64EncodedString(), signature: try key.signature(for: bytes).base64EncodedString())
        return manifest
    }
}
public struct UpdateEnvelope: Codable, Equatable {
    /// Base64 of the raw payload JSON bytes that `signature` covers.
    public var payload: String
    public var signature: String
    public init(payload: String, signature: String) { self.payload = payload; self.signature = signature }
}
/// Schema 1 signed payload. `sequence` equals the integer build number and only increases.
public struct UpdatePayload: Codable, Equatable {
    public static let currentSchema = 1
    static let keys: Set<String> = ["schema", "bundleIdentifier", "version", "build", "assetKey", "downloadURL", "sha256", "minimumMacOS", "issuedAt", "sequence"]
    public var schema: Int
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var assetKey: String
    public var downloadURL: URL
    public var sha256: String
    public var minimumMacOS: String
    public var issuedAt: String
    public var sequence: Int
    static func sequence(forBuild build: String) -> Int? {
        guard let value = Int(build), value > 0, String(value) == build else { return nil }
        return value
    }
    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    /// Rejects unknown or missing keys and any schema other than the current one.
    public static func decodeStrict(_ data: Data) throws -> UpdatePayload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys,
              let payload = try? JSONDecoder().decode(UpdatePayload.self, from: data), payload.schema == currentSchema,
              ISO8601DateFormatter().date(from: payload.issuedAt) != nil,
              let sequence = UpdatePayload.sequence(forBuild: payload.build), payload.sequence == sequence else { throw RenameError("Unsupported or malformed signed update payload.") }
        return payload
    }
}
/// Highest manifest sequence this installation has accepted, used to detect replayed older manifests.
public struct UpdateSequenceStore {
    public static let key = "UpdateHighestAcceptedSequence"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var highest: Int { defaults.integer(forKey: Self.key) }
    public func record(_ payload: UpdatePayload) { if payload.sequence > highest { defaults.set(payload.sequence, forKey: Self.key) } }
}
public struct UpdateTrust {
    public let publicKey: Data
    public let downloadURL: URL
    public init(publicKey: Data, downloadURL: URL) { self.publicKey = publicKey; self.downloadURL = downloadURL }
}
public enum UpdatePolicy {
    /// Exactly three ASCII decimal components without leading zeros (`0` itself is allowed).
    public static func version(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && ($0 == "0" || !$0.hasPrefix("0")) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }
    /// Parsed equality: invalid versions are never equal, even when byte-identical.
    public static func sameVersion(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, let left = version(a), let right = version(b) else { return false }
        return left == right
    }
    /// The signature installed 0.1.x clients verify. Release tooling requires it; current clients rely on the envelope.
    public static func hasValidLegacySignature(_ manifest: UpdateManifest, publicKey: Data) -> Bool {
        guard let text = manifest.signature, let signature = Data(base64Encoded: text),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let bytes = try? manifest.signedBytes() else { return false }
        return key.isValidSignature(signature, for: bytes)
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    /// Validates a manifest for this client and returns its authenticated payload.
    /// `highestSequence` is the largest sequence previously accepted on this Mac.
    @discardableResult
    public static func validate(_ manifest: UpdateManifest, trust: UpdateTrust?, currentVersion: String, osVersion: String, allowCurrent: Bool = false, highestSequence: Int = 0) throws -> UpdatePayload {
        guard let trust else { throw RenameError("Updates are not configured.") }
        let failure = RenameError("Update identity, signature, version, or compatibility validation failed.")
        // Authenticate the exact payload bytes before interpreting them.
        guard let envelope = manifest.envelope, let bytes = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trust.publicKey),
              key.isValidSignature(signature, for: bytes) else { throw failure }
        let payload = try UpdatePayload.decodeStrict(bytes)
        guard payload.bundleIdentifier == manifest.bundleIdentifier, payload.version == manifest.version,
              payload.build == manifest.build, payload.assetKey == manifest.assetKey,
              payload.downloadURL == manifest.downloadURL, payload.sha256 == manifest.sha256,
              payload.minimumMacOS == manifest.minimumMacOS else { throw failure }
        guard payload.bundleIdentifier == "com.vortexopenclaw.batch-rename",
              payload.downloadURL == trust.downloadURL, trust.downloadURL.scheme == "https",
              payload.assetKey.hasPrefix("batch-rename/releases/"),
              !payload.assetKey.contains(".."), !payload.assetKey.contains("\\"),
              payload.assetKey.split(separator: "/").count == 3,
              payload.assetKey.hasSuffix(".zip"),
              payload.sha256.count == 64, payload.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let remote = version(payload.version), let local = version(currentVersion),
              (local.lexicographicallyPrecedes(remote) || (allowCurrent && local == remote)),
              let minimum = version(payload.minimumMacOS), let os = version(osVersion), !os.lexicographicallyPrecedes(minimum) else { throw failure }
        guard payload.sequence >= highestSequence else { throw RenameError("This update is older than an update already seen. It may be a replayed release; try again later.") }
        return payload
    }
    public static func validateArchive(_ data: Data, manifest: UpdateManifest) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == manifest.sha256 else { throw RenameError("Update checksum mismatch.") }
    }
}
