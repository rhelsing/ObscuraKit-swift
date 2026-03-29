import Foundation
import CryptoKit

/// Generate a 4-digit verification code from a public key.
/// SHA-256(key) → first 2 bytes as uint16 → mod 10000 → zero-padded.
/// Matches src/v2/crypto/signatures.js generateVerifyCode()
public func generateVerifyCode(from key: Data) -> String {
    let hash = Array(SHA256.hash(data: key))
    let code = (Int(hash[0]) << 8 | Int(hash[1])) % 10000
    return String(format: "%04d", code)
}

/// Generate verification code from recovery public key (per-user, stable across devices).
public func generateVerifyCodeFromRecoveryKey(_ recoveryPublicKey: Data) -> String {
    return generateVerifyCode(from: recoveryPublicKey)
}

/// Generate verification code from sorted device identity keys.
public func generateVerifyCodeFromDevices(_ devices: [(deviceUUID: String, signalIdentityKey: Data)]) -> String {
    let sorted = devices.sorted { $0.deviceUUID < $1.deviceUUID }
    var concatenated = Data()
    for device in sorted {
        concatenated.append(device.signalIdentityKey)
    }
    return generateVerifyCode(from: concatenated)
}
