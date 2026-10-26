import Foundation
import CryptoKit
import RenameCore
// Private key arrives only on stdin from the release job's scoped secret, never an auth store.
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: input, encoding: .utf8), let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { fatalError("Invalid signing input") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
var manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let config = try JSONDecoder().decode(UpdateConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: "Resources/UpdateConfiguration.json")))
guard key.publicKey.rawRepresentation == config.trust.publicKey else { fatalError("Signing key does not match configured public key") }
manifest.signature = try key.signature(for: manifest.signedBytes()).base64EncodedString()
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try encoder.encode(manifest).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
