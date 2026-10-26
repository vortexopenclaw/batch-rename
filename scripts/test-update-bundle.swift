import Foundation
import CryptoKit
import RenameCore
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("update-bundle-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: root) }
let app = root.appendingPathComponent("Batch Rename.app")
try FileManager.default.copyItem(at: URL(fileURLWithPath: "build/Batch Rename.app"), to: app)
let key = Curve25519.Signing.PrivateKey(), url = URL(string: "https://example.invalid/batch-rename/download")!
let config: [String:String] = ["manifestURL":"https://example.invalid/batch-rename/manifest.json", "downloadURL":url.absoluteString, "publicKey":key.publicKey.rawRepresentation.base64EncodedString()]
try JSONSerialization.data(withJSONObject: config).write(to: app.appendingPathComponent("Contents/Resources/UpdateConfiguration.json"))
try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
let release = root.appendingPathComponent("release")
try UpdateInstaller.run("/usr/bin/env", ["python3", "scripts/release-update.py", app.path, release.path])
var m = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: release.appendingPathComponent("unsigned.json")))
m.signature = try key.signature(for: m.signedBytes()).base64EncodedString()
try UpdatePolicy.validate(m, trust: UpdateTrust(publicKey: key.publicKey.rawRepresentation, downloadURL: url), currentVersion: "0.0.0", osVersion: "14.0.0")
let archive = try Data(contentsOf: release.appendingPathComponent(URL(fileURLWithPath: m.assetKey).lastPathComponent))
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
