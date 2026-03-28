import Foundation

/// Structured security logger for ObscuraKit.
/// Consumers can provide their own implementation; the default is a no-op.
/// Security-sensitive events are logged through this interface so they
/// never go unnoticed in production.
public protocol ObscuraLogger: Sendable {
    func decryptFailed(sourceUserId: String, error: String)
    func ackFailed(envelopeId: String, error: String)
    func frameParseFailed(byteCount: Int, error: String)
    func sessionEstablishFailed(userId: String, error: String)
    func tokenRefreshFailed(attempt: Int, error: String)
    func identityChanged(address: String)
    func signatureVerificationFailed(sourceUserId: String, messageType: String)
    func unauthorizedSync(sourceUserId: String, messageType: String)
    func databaseError(store: String, operation: String, error: String)
}

/// Default implementation that prints to stderr. Replace with your own for production.
public final class PrintLogger: ObscuraLogger, @unchecked Sendable {
    public init() {}

    public func decryptFailed(sourceUserId: String, error: String) {
        log("decrypt failed from \(sourceUserId): \(error)")
    }
    public func ackFailed(envelopeId: String, error: String) {
        log("ack failed for \(envelopeId): \(error)")
    }
    public func frameParseFailed(byteCount: Int, error: String) {
        log("frame parse failed (\(byteCount) bytes): \(error)")
    }
    public func sessionEstablishFailed(userId: String, error: String) {
        log("session establish failed for \(userId): \(error)")
    }
    public func tokenRefreshFailed(attempt: Int, error: String) {
        log("token refresh failed (attempt \(attempt)): \(error)")
    }
    public func identityChanged(address: String) {
        log("identity changed for \(address)")
    }
    public func signatureVerificationFailed(sourceUserId: String, messageType: String) {
        log("signature verification failed from \(sourceUserId) type=\(messageType)")
    }
    public func unauthorizedSync(sourceUserId: String, messageType: String) {
        log("unauthorized sync from \(sourceUserId) type=\(messageType)")
    }
    public func databaseError(store: String, operation: String, error: String) {
        log("db error in \(store).\(operation): \(error)")
    }

    private func log(_ msg: String) {
        print("[ObscuraKit] \(msg)")
    }
}

/// Silent logger for tests or when no logging is desired.
public final class NoOpLogger: ObscuraLogger, @unchecked Sendable {
    public init() {}
    public func decryptFailed(sourceUserId: String, error: String) {}
    public func ackFailed(envelopeId: String, error: String) {}
    public func frameParseFailed(byteCount: Int, error: String) {}
    public func sessionEstablishFailed(userId: String, error: String) {}
    public func tokenRefreshFailed(attempt: Int, error: String) {}
    public func identityChanged(address: String) {}
    public func signatureVerificationFailed(sourceUserId: String, messageType: String) {}
    public func unauthorizedSync(sourceUserId: String, messageType: String) {}
    public func databaseError(store: String, operation: String, error: String) {}
}
