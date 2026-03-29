import Foundation
import CryptoKit
import LibSignalClient

/// Recovery key management — BIP39 phrase generation, signing, verification.
/// Matches src/v2/crypto/signatures.js and src/v2/crypto/bip39.js
public struct RecoveryKeys {

    /// Generate a 12-word recovery phrase (simplified BIP39).
    public static func generatePhrase() -> String {
        var entropy = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { entropy[i] = UInt8.random(in: 0...255) }

        let hash = Array(SHA256.hash(data: entropy))
        let allBits = entropy.flatMap { byteToBits($0) } + byteToBits(hash[0]).prefix(4)

        var words: [String] = []
        for i in 0..<12 {
            let start = i * 11
            let end = min(start + 11, allBits.count)
            let bits = Array(allBits[start..<end])
            let index = bitsToInt(bits) % BIP39_WORDLIST.count
            words.append(BIP39_WORDLIST[index])
        }

        return words.joined(separator: " ")
    }

    /// Derive a Curve25519 keypair from a recovery phrase.
    /// Uses PBKDF2-HMAC-SHA256 with BIP39-standard salt and 2048 iterations.
    public static func deriveKeypair(from phrase: String) -> (publicKey: Data, privateKey: Data) {
        let seed = pbkdf2(password: Array(phrase.utf8), salt: Array("mnemonic".utf8), iterations: 2048, keyLength: 32)
        guard let privateKey = try? PrivateKey(seed) else {
            return (publicKey: Data(), privateKey: Data())
        }
        let publicKey = privateKey.publicKey
        return (publicKey: Data(publicKey.serialize()), privateKey: Data(seed))
    }

    /// Get the public key from a recovery phrase.
    public static func getPublicKey(from phrase: String) -> Data {
        return deriveKeypair(from: phrase).publicKey
    }

    /// Sign data with a recovery phrase (derive key, sign, discard private key).
    public static func sign(phrase: String, data: Data) -> Data {
        let seed = pbkdf2(password: Array(phrase.utf8), salt: Array("mnemonic".utf8), iterations: 2048, keyLength: 32)
        guard let privateKey = try? PrivateKey(seed) else { return Data() }
        let signature = privateKey.generateSignature(message: Array(data))
        return Data(signature)
    }

    /// Verify a signature against a recovery public key.
    public static func verify(publicKey: Data, data: Data, signature: Data) -> Bool {
        guard let pk = try? PublicKey(Array(publicKey)) else { return false }
        return (try? pk.verifySignature(message: Array(data), signature: Array(signature))) ?? false
    }

    /// Serialize a DeviceAnnounce for signing (deterministic JSON).
    public static func serializeAnnounceForSigning(
        deviceIds: [String], timestamp: UInt64, isRevocation: Bool
    ) -> Data {
        let dict: [String: Any] = [
            "devices": deviceIds.map { ["deviceId": $0] },
            "isRevocation": isRevocation,
            "timestamp": timestamp,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            return data
        }
        return Data("{}".utf8)
    }

    // MARK: - Internal helpers

    private static func byteToBits(_ byte: UInt8) -> [Int] {
        (0..<8).map { (Int(byte) >> (7 - $0)) & 1 }
    }

    private static func bitsToInt(_ bits: [Int]) -> Int {
        bits.reduce(0) { $0 * 2 + $1 }
    }
}

// MARK: - PBKDF2-HMAC-SHA256 using CryptoKit

/// PBKDF2 key derivation using HMAC-SHA256, per RFC 2898.
internal func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> [UInt8] {
    let symmetricKey = SymmetricKey(data: password)
    var derivedKey = [UInt8]()
    let blockCount = (keyLength + 31) / 32

    for blockIndex in 1...blockCount {
        let blockBytes: [UInt8] = [
            UInt8((blockIndex >> 24) & 0xff),
            UInt8((blockIndex >> 16) & 0xff),
            UInt8((blockIndex >> 8) & 0xff),
            UInt8(blockIndex & 0xff),
        ]
        var u = Array(HMAC<SHA256>.authenticationCode(for: salt + blockBytes, using: symmetricKey))
        var result = u

        for _ in 1..<iterations {
            u = Array(HMAC<SHA256>.authenticationCode(for: u, using: symmetricKey))
            for j in 0..<32 { result[j] ^= u[j] }
        }
        derivedKey.append(contentsOf: result)
    }

    return Array(derivedKey.prefix(keyLength))
}

// BIP39_WORDLIST is in Bip39Wordlist.swift (2048 words from standard English wordlist)
