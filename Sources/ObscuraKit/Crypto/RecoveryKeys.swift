import Foundation
import LibSignalClient

/// Recovery key management — BIP39 phrase generation, signing, verification.
/// Matches src/v2/crypto/signatures.js and src/v2/crypto/bip39.js
public struct RecoveryKeys {

    /// Generate a 12-word recovery phrase (simplified BIP39).
    /// In production, use the full 2048-word BIP39 wordlist.
    public static func generatePhrase() -> String {
        // Generate 16 bytes (128 bits) of entropy
        var entropy = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { entropy[i] = UInt8.random(in: 0...255) }

        // Convert to 12 words using simplified word selection
        // Each word is derived from 11 bits of entropy+checksum
        let hash = sha256(Data(entropy))
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
    /// Uses SHA-256 of the phrase as the 32-byte private key seed.
    public static func deriveKeypair(from phrase: String) -> (publicKey: Data, privateKey: Data) {
        let seed = sha256(Data(phrase.utf8))
        guard let privateKey = try? PrivateKey(Array(seed)) else {
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
        let seed = sha256(Data(phrase.utf8))
        guard let privateKey = try? PrivateKey(Array(seed)) else { return Data() }
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
        // Deterministic serialization matching JS: JSON.stringify({devices, isRevocation, timestamp})
        let devices = deviceIds.map { "{\"deviceId\":\"\($0)\"}" }.joined(separator: ",")
        let json = "{\"devices\":[\(devices)],\"isRevocation\":\(isRevocation),\"timestamp\":\(timestamp)}"
        return Data(json.utf8)
    }

    // MARK: - Internal helpers

    private static func byteToBits(_ byte: UInt8) -> [Int] {
        (0..<8).map { (Int(byte) >> (7 - $0)) & 1 }
    }

    private static func bitsToInt(_ bits: [Int]) -> Int {
        bits.reduce(0) { $0 * 2 + $1 }
    }

    private static func sha256(_ data: Data) -> [UInt8] {
        return recoverySHA256(data)
    }
}

// SHA-256 implementation (shared with VerificationCode.swift)
internal func recoverySHA256(_ data: Data) -> [UInt8] {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    var msg = Array(data)
    let origLen = msg.count
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    let bitLen = UInt64(origLen) * 8
    for i in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((bitLen >> i) & 0xff)) }
    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for blockStart in stride(from: 0, to: msg.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 { let j = blockStart + i * 4; w[i] = UInt32(msg[j])<<24 | UInt32(msg[j+1])<<16 | UInt32(msg[j+2])<<8 | UInt32(msg[j+3]) }
        for i in 16..<64 { let s0 = rotr(w[i-15],7)^rotr(w[i-15],18)^(w[i-15]>>3); let s1 = rotr(w[i-2],17)^rotr(w[i-2],19)^(w[i-2]>>10); w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1 }
        var a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7]
        for i in 0..<64 { let s1=rotr(e,6)^rotr(e,11)^rotr(e,25); let ch=(e&f)^(~e&g); let t1=hh &+ s1 &+ ch &+ k[i] &+ w[i]; let s0=rotr(a,2)^rotr(a,13)^rotr(a,22); let maj=(a&b)^(a&c)^(b&c); let t2=s0 &+ maj; hh=g;g=f;f=e;e=d &+ t1;d=c;c=b;b=a;a=t1 &+ t2 }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
    var result = [UInt8]()
    for val in h { result.append(UInt8((val>>24)&0xff)); result.append(UInt8((val>>16)&0xff)); result.append(UInt8((val>>8)&0xff)); result.append(UInt8(val&0xff)) }
    return result
}

// BIP39_WORDLIST is in Bip39Wordlist.swift (2048 words from standard English wordlist)
