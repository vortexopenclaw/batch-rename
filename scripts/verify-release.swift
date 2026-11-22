import Foundation
import RenameCore
let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let config = try JSONDecoder().decode(UpdateConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: "Resources/UpdateConfiguration.json")))
try UpdatePolicy.validate(manifest, trust: config.trust, currentVersion: "0.0.0", osVersion: "99.0.0")
// Installed 0.1.x clients verify only the legacy signature.
guard UpdatePolicy.hasValidLegacySignature(manifest, publicKey: config.trust.publicKey) else { fatalError("Legacy signature verification failed") }
try UpdatePolicy.validateArchive(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), manifest: manifest)
print("Release signature and archive checksum verified")
