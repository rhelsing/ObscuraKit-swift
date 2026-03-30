import Foundation
import ObscuraKit

/// Debug logger that feeds into AppState's log buffer.
/// Shows on the Settings tab for easy copy-paste debugging.
final class AppLogger: ObscuraLogger, @unchecked Sendable {
    weak var appState: AppState?

    private func emit(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.appState?.log(msg)
        }
    }

    func log(_ message: String) { emit(message) }

    func decryptFailed(sourceUserId: String, error: String) {
        emit("DECRYPT FAIL \(sourceUserId.prefix(8)): \(error)")
    }

    func sessionEstablishFailed(userId: String, error: String) {
        emit("SESSION FAIL \(userId.prefix(8)): \(error)")
    }

    func identityChanged(address: String) {
        emit("IDENTITY CHANGED: \(address)")
    }

    func tokenRefreshFailed(attempt: Int, error: String) {
        emit("TOKEN REFRESH FAIL #\(attempt): \(error)")
    }

    func frameParseFailed(byteCount: Int, error: String) {
        emit("FRAME PARSE FAIL (\(byteCount)b): \(error)")
    }

    func ackFailed(envelopeId: String, error: String) {
        emit("ACK FAIL \(envelopeId.prefix(8)): \(error)")
    }

    func signatureVerificationFailed(sourceUserId: String, messageType: String) {
        emit("SIG VERIFY FAIL \(sourceUserId.prefix(8)) type=\(messageType)")
    }

    func unauthorizedSync(sourceUserId: String, messageType: String) {
        emit("UNAUTH SYNC \(sourceUserId.prefix(8)) type=\(messageType)")
    }

    func databaseError(store: String, operation: String, error: String) {
        emit("DB ERROR \(store).\(operation): \(error)")
    }
}
