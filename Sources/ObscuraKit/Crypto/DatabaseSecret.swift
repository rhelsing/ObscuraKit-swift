import Foundation
import Security

/// Manages the SQLCipher database encryption key per user.
/// iOS equivalent of Kotlin's DatabaseSecretProvider.
///
/// Pattern (matches Signal):
/// 1. Generate a 32-byte random key (high entropy)
/// 2. Store in iOS Keychain (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
/// 3. On launch, fetch from Keychain and pass to SQLCipher via GRDB's usePassphrase()
///
/// KDF iterations are set to 1 since the key is already 256 bits of entropy (same as Signal).
public enum DatabaseSecret {

    /// Get or create a 32-byte encryption key for a specific user.
    /// Stored in the iOS Keychain, scoped by userId.
    public static func getOrCreate(userId: String) -> Data {
        let service = "com.obscura.dbsecret"
        let account = "db_key_\(userId)"

        // Try to load existing key
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, data.count == 32 {
            return data
        }

        // Generate new 32-byte random key
        var key = Data(count: 32)
        key.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }

        // Store in Keychain
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary) // remove stale if any
        SecItemAdd(addQuery as CFDictionary, nil)

        return key
    }
}
