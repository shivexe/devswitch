// Adapted from the user-owned Harbor encrypted pairing primitives.
import CryptoKit
import Foundation
import Security

struct Envelope: Codable {
    var nonce: String
    var ciphertext: String
    var tag: String
    var deviceId: String?
}

struct SyncCrypto {
    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    static func seal<T: Encodable>(_ value: T, key: Data, aad: String) throws -> Envelope {
        guard key.count == 32 else { throw AppError.message("Invalid encryption key.") }
        let box = try AES.GCM.seal(JSONEncoder().encode(value), using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
        return Envelope(nonce: box.nonce.withUnsafeBytes { Data($0).base64EncodedString() }, ciphertext: box.ciphertext.base64EncodedString(), tag: box.tag.base64EncodedString())
    }

    static func open<T: Decodable>(_ type: T.Type, envelope: Envelope, key: Data, aad: String) throws -> T {
        guard key.count == 32, let nonce = Data(base64Encoded: envelope.nonce), nonce.count == 12,
              let ciphertext = Data(base64Encoded: envelope.ciphertext), ciphertext.count <= 64 * 1024,
              let tag = Data(base64Encoded: envelope.tag), tag.count == 16 else { throw AppError.message("Invalid encrypted message.") }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
        return try JSONDecoder().decode(type, from: plaintext)
    }

    static func comparison(secret: Data, nonce: Data) -> String {
        let digest = SHA256.hash(data: secret + nonce)
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", number % 1_000_000)
    }
}
