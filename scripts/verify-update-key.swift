import CryptoKit
import Foundation

// Validate that release signing uses the public key embedded in the application.
do {
    guard CommandLine.arguments.count == 2,
          let expected = ProcessInfo.processInfo.environment["SPEAKFLOW_UPDATE_PUBLIC_KEY"],
          let expectedData = Data(base64Encoded: expected) else { exit(1) }
    let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32 else { exit(1) }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    guard key.publicKey.rawRepresentation == expectedData else { exit(1) }
} catch {
    exit(1)
}
