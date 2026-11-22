import Foundation
import CryptoKit
import RenameCore
// Private key arrives only on stdin from the release job's scoped secret, never an auth store.
// Writes both signatures: the legacy one installed 0.1.x clients verify, and the schema-1 envelope.
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: input, encoding: .utf8), let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { fatalError("Invalid signing input") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
let unsigned = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
guard unsigned.signature == nil, unsigned.envelope == nil else { fatalError("Input manifest is already signed") }
let config = try JSONDecoder().decode(UpdateConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: "Resources/UpdateConfiguration.json")))
guard key.publicKey.rawRepresentation == config.trust.publicKey else { fatalError("Signing key does not match configured public key") }
let manifest = try unsigned.signed(with: key)
guard UpdatePolicy.hasValidLegacySignature(manifest, publicKey: config.trust.publicKey) else { fatalError("Legacy signature self-check failed") }
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try encoder.encode(manifest).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
