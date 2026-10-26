import Foundation
import CryptoKit

/// Signed release policy shared by the in-app updater and release signer.
public struct UpdateManifest: Codable {
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var assetKey: String
    public var downloadURL: URL
    public var sha256: String
    public var minimumMacOS: String
    public var signature: String?
    public func signedBytes() throws -> Data {
        var unsigned = self; unsigned.signature = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(unsigned)
    }
}
public struct UpdateTrust {
    public let publicKey: Data
    public let downloadURL: URL
    public init(publicKey: Data, downloadURL: URL) { self.publicKey = publicKey; self.downloadURL = downloadURL }
}
public enum UpdatePolicy {
    public static func version(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }
    public static func validate(_ manifest: UpdateManifest, trust: UpdateTrust?, currentVersion: String, osVersion: String, allowCurrent: Bool = false) throws {
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
    public static func validateArchive(_ data: Data, manifest: UpdateManifest) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == manifest.sha256 else { throw RenameError("Update checksum mismatch.") }
    }
}
