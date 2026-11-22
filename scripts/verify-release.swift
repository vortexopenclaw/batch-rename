import Foundation
import RenameCore
// Release gate: runs the client pipeline on the exact release artifact.
// Usage: verify-release <manifest.json> <release.zip> --previous-version X.Y.Z --previous-build N
// Reads the trust anchor from Resources/UpdateConfiguration.json in the working directory.
func fail(_ message: String) -> Never { fputs("verify-release: \(message)\n", stderr); exit(1) }
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 6, arguments[2] == "--previous-version", arguments[4] == "--previous-build" else {
    fail("usage: verify-release <manifest.json> <release.zip> --previous-version X.Y.Z --previous-build N")
}
let manifestURL = URL(fileURLWithPath: arguments[0]), archiveURL = URL(fileURLWithPath: arguments[1])
let previousVersion = arguments[3]
guard UpdatePolicy.version(previousVersion) != nil else { fail("invalid previous version \(previousVersion)") }
guard let previousBuild = Int(arguments[5]), previousBuild >= 0, String(previousBuild) == arguments[5] else { fail("invalid previous build \(arguments[5])") }
do {
    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: manifestURL))
    let config = try JSONDecoder().decode(UpdateConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: "Resources/UpdateConfiguration.json")))
    // Installed 0.1.x clients verify only the legacy signature; current clients require the envelope.
    guard UpdatePolicy.hasValidLegacySignature(manifest, publicKey: config.trust.publicKey) else { fail("legacy signature verification failed") }
    // Strictly newer version than the previous published release, envelope, identity, and URL policy.
    let payload = try UpdatePolicy.validate(manifest, trust: config.trust, currentVersion: previousVersion, osVersion: "99.0.0")
    guard payload.sequence > previousBuild else { fail("build \(manifest.build) is not greater than previous build \(previousBuild)") }
    guard archiveURL.lastPathComponent == URL(fileURLWithPath: manifest.assetKey).lastPathComponent else { fail("archive name does not match assetKey") }
    let archive = try Data(contentsOf: archiveURL, options: .alwaysMapped)
    try UpdatePolicy.validateArchive(archive, manifest: manifest)
    // Same extraction and bundle validation the installed client performs (identity, minimum macOS, codesign).
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("verify-release-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let extracted = scratch.appendingPathComponent("extracted")
    try UpdateArchive.extract(archive, to: extracted)
    try UpdateInstaller.validateBundle(extracted.appendingPathComponent("Batch Rename.app"), manifest: manifest)
    print("Release verified: \(manifest.version) (\(manifest.build)) > \(previousVersion) (\(previousBuild)); legacy and envelope signatures, checksum, extracted bundle identity, minimum macOS, and codesign")
} catch {
    fail(error.localizedDescription)
}
