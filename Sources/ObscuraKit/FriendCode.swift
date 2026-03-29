import Foundation

/// Friend code: base64-encoded JSON containing userId + username.
/// Matches the JS web client format. Can be QR-encoded or shared as text.
///
/// Format: `Base64({"u":"<userId>","n":"<username>"})`
public enum FriendCode {

    public struct Decoded: Sendable, Equatable {
        public let userId: String
        public let username: String
    }

    /// Generate a shareable friend code from userId + username.
    public static func encode(userId: String, username: String) -> String {
        let json: [String: String] = ["u": userId, "n": username]
        let data = try! JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        return data.base64EncodedString()
    }

    /// Decode a friend code back to userId + username.
    public static func decode(_ code: String) throws -> Decoded {
        // Handle both standard and URL-safe base64
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: normalized),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let userId = json["u"], !userId.isEmpty,
              let username = json["n"], !username.isEmpty
        else { throw FriendCodeError.invalidCode }

        return Decoded(userId: userId, username: username)
    }

    public enum FriendCodeError: Error, LocalizedError {
        case invalidCode

        public var errorDescription: String? {
            switch self {
            case .invalidCode: return "Invalid friend code"
            }
        }
    }
}
