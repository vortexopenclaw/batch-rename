import Foundation
import CryptoKit
import RenameCore
// Headless release-pipeline roundtrip on a copy of the packaged app. Uses only a throwaway key.
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("update-bundle-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: root) }
let build = URL(fileURLWithPath: "build").standardizedFileURL
let app = root.appendingPathComponent("Batch Rename.app")
try FileManager.default.copyItem(at: build.appendingPathComponent("Batch Rename.app"), to: app)
let key = Curve25519.Signing.PrivateKey(), url = URL(string: "https://example.invalid/batch-rename/download")!
let config: [String:String] = ["manifestURL":"https://example.invalid/batch-rename/manifest.json", "downloadURL":url.absoluteString, "publicKey":key.publicKey.rawRepresentation.base64EncodedString()]
try JSONSerialization.data(withJSONObject: config).write(to: app.appendingPathComponent("Contents/Resources/UpdateConfiguration.json"))
try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
let release = root.appendingPathComponent("release")
try UpdateInstaller.run("/usr/bin/env", ["python3", "scripts/release-update.py", app.path, release.path])
var m = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: release.appendingPathComponent("unsigned.json"))).signed(with: key)
try UpdatePolicy.validate(m, trust: UpdateTrust(publicKey: key.publicKey.rawRepresentation, downloadURL: url), currentVersion: "0.0.0", osVersion: "14.0.0")
let archiveURL = release.appendingPathComponent(URL(fileURLWithPath: m.assetKey).lastPathComponent)
let archive = try Data(contentsOf: archiveURL)
try UpdatePolicy.validateArchive(archive, manifest: m)
var corrupt = archive; corrupt[corrupt.count / 2] ^= 1
do { try UpdatePolicy.validateArchive(corrupt, manifest: m); fatalError("Corrupt archive accepted") } catch {}
let destination = root.appendingPathComponent("extracted")
try UpdateArchive.extract(archive, to: destination)
let extracted = destination.appendingPathComponent("Batch Rename.app")
try UpdateInstaller.validateBundle(extracted, manifest: m)
m.build = "wrong-build"
do { try UpdateInstaller.validateBundle(extracted, manifest: m); fatalError("Wrong bundle build accepted") } catch {}
print("UPDATE BUNDLE ROUNDTRIP PASSED: ephemeral signature, real release ZIP, extraction, ad-hoc signature, identity mismatch")

// Real release tools: sign-update and verify-release read Resources/UpdateConfiguration.json
// relative to their working directory, so run them in a fixture checkout with the throwaway key.
let repo = root.appendingPathComponent("repo")
try FileManager.default.createDirectory(at: repo.appendingPathComponent("Resources"), withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: config).write(to: repo.appendingPathComponent("Resources/UpdateConfiguration.json"))
@discardableResult
func tool(_ name: String, _ arguments: [String], stdin: Data? = nil) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe(), input = Pipe()
    process.executableURL = build.appendingPathComponent(name); process.arguments = arguments
    process.currentDirectoryURL = repo; process.standardOutput = pipe; process.standardError = pipe; process.standardInput = input
    try process.run()
    if let stdin { input.fileHandleForWriting.write(stdin) }
    try input.fileHandleForWriting.close()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, output)
}
let signed = release.appendingPathComponent("manifest.json")
let signing = try tool("sign-update", [release.appendingPathComponent("unsigned.json").path, signed.path], stdin: Data(key.rawRepresentation.base64EncodedString().utf8))
guard signing.status == 0 else { fatalError("sign-update failed: \(signing.output)") }
let published = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: signed))
guard published.envelope != nil, UpdatePolicy.hasValidLegacySignature(published, publicKey: key.publicKey.rawRepresentation) else { fatalError("sign-update did not produce both signatures") }
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
let version = info["CFBundleShortVersionString"] as! String, bundleBuild = info["CFBundleVersion"] as! String
let parts = version.split(separator: ".").map { Int($0)! }
let lowerVersion = parts[2] > 0 ? "\(parts[0]).\(parts[1]).\(parts[2] - 1)" : parts[1] > 0 ? "\(parts[0]).\(parts[1] - 1).0" : "\(parts[0] - 1).0.0"
let lowerBuild = String(Int(bundleBuild)! - 1)
func verify(_ manifest: URL, _ zip: URL, _ extra: [String]) throws -> (status: Int32, output: String) {
    try tool("verify-release", [manifest.path, zip.path] + extra)
}
let accepted = try verify(signed, archiveURL, ["--previous-version", lowerVersion, "--previous-build", lowerBuild])
guard accepted.status == 0 else { fatalError("verify-release rejected a valid release: \(accepted.output)") }
print(accepted.output.trimmingCharacters(in: .whitespacesAndNewlines))
var accepted_bad: [String] = []
func expectRejected(_ label: String, _ manifest: URL, _ zip: URL, _ extra: [String]) throws {
    let result = try verify(manifest, zip, extra)
    guard result.status != 0 else { print("verify-release ACCEPTED \(label)"); accepted_bad.append(label); return }
    print("verify-release rejected \(label): \(result.output.split(separator: "\n").last ?? "")")
}
let previous = ["--previous-version", lowerVersion, "--previous-build", lowerBuild]
try expectRejected("missing previous release", signed, archiveURL, [])
try expectRejected("same version as previous", signed, archiveURL, ["--previous-version", version, "--previous-build", lowerBuild])
try expectRejected("same build as previous", signed, archiveURL, ["--previous-version", lowerVersion, "--previous-build", bundleBuild])
func writeManifest(_ manifest: UpdateManifest, _ name: String) throws -> URL {
    let target = release.appendingPathComponent(name)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: target); return target
}
let foreignSignature = try key.signature(for: Data("other".utf8)).base64EncodedString()
var legacyBroken = published; legacyBroken.signature = foreignSignature
try expectRejected("broken legacy signature", try writeManifest(legacyBroken, "legacy-broken.json"), archiveURL, previous)
var envelopeBroken = published; envelopeBroken.envelope?.signature = foreignSignature
try expectRejected("broken envelope signature", try writeManifest(envelopeBroken, "envelope-broken.json"), archiveURL, previous)
// Correctly signed and hashed, but the bundle inside disagrees: only extraction and validateBundle catch it.
var identity = published; identity.signature = nil; identity.envelope = nil; identity.build = String(Int(bundleBuild)! + 1)
try expectRejected("bundle build mismatch", try writeManifest(identity.signed(with: key), "identity.json"), archiveURL, previous)
// A resource changed after codesigning: hash and signatures are valid, codesign is not.
let modified = root.appendingPathComponent("modified/Batch Rename.app")
try FileManager.default.createDirectory(at: modified.deletingLastPathComponent(), withIntermediateDirectories: false)
try FileManager.default.copyItem(at: app, to: modified)
let icon = try FileHandle(forWritingTo: modified.appendingPathComponent("Contents/Resources/AppIcon.icns"))
try icon.seekToEnd(); try icon.write(contentsOf: Data([0])); try icon.close()
let modifiedRelease = root.appendingPathComponent("modified-release")
try UpdateInstaller.run("/usr/bin/env", ["python3", "scripts/release-update.py", modified.path, modifiedRelease.path])
let modifiedManifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: modifiedRelease.appendingPathComponent("unsigned.json"))).signed(with: key)
try expectRejected("codesign failure after extraction", try writeManifest(modifiedManifest, "modified.json"), modifiedRelease.appendingPathComponent(URL(fileURLWithPath: modifiedManifest.assetKey).lastPathComponent), previous)
guard accepted_bad.isEmpty else { fatalError("verify-release accepted: \(accepted_bad.joined(separator: ", "))") }
print("RELEASE TOOLS PASSED: sign-update wrote both signatures; verify-release accepted the real artifact against \(lowerVersion) (\(lowerBuild)) and rejected 7 bad cases")
