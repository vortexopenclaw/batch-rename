import Foundation
import RenameCore
let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let config = try JSONDecoder().decode(UpdateConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: "Resources/UpdateConfiguration.json")))
try UpdatePolicy.validate(manifest, trust: config.trust, currentVersion: "0.0.0", osVersion: "99.0.0")
try UpdatePolicy.validateArchive(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), manifest: manifest)
print("Release signature and archive checksum verified")
