import Foundation

/// ECS-style signals for ORM models — ephemeral, not persisted.
/// Typing indicators, read receipts, presence — real-time state that auto-expires.
///
/// Signals are declared on the model:
/// ```swift
/// struct DirectMessage: SyncModel {
///     static let signals: [SignalType] = [.typing, .read]
///     ...
/// }
/// ```
///
/// Used via purpose-built methods:
/// ```swift
/// messages.typing(conversationId: convId)
/// for await who in messages.observeTyping(conversationId: convId) { ... }
/// ```

// MARK: - Signal Types

public enum SignalType: String, Sendable, Codable {
    case typing
    case stoppedTyping
    case read
}

/// Wire format for MODEL_SIGNAL — encoded as JSON in ClientMessage.
/// Not persisted, not CRDT-merged, held in memory with auto-expire.
public struct ModelSignalPayload: Codable, Sendable {
    public let model: String          // "directMessage"
    public let signal: String         // "typing", "stoppedTyping", "read"
    public let data: [String: String] // {"conversationId": "..."}
    public let authorDeviceId: String
    public let timestamp: UInt64

    public init(model: String, signal: SignalType, data: [String: String], authorDeviceId: String) {
        self.model = model
        self.signal = signal.rawValue
        self.data = data
        self.authorDeviceId = authorDeviceId
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Signal Store (in-memory, auto-expire)

/// Holds active signals in memory. Auto-expires after timeout.
/// Thread-safe via actor isolation.
public actor SignalStore {
    /// Key: "\(model):\(signal):\(contextKey)" → set of active author device IDs
    private var active: [String: [(authorDeviceId: String, expiresAt: UInt64)]] = [:]

    /// Signal expiry in milliseconds (default 5 seconds)
    private let expiryMs: UInt64 = 5_000

    /// Record an incoming signal. Auto-expires after 5 seconds.
    public func receive(_ payload: ModelSignalPayload) {
        let key = signalKey(model: payload.model, signal: payload.signal, data: payload.data)
        NSLog("[ObscuraKit] SignalStore.receive key=%@ signal=%@", key, payload.signal)

        // Drop stale signals (older than 5 seconds)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if now - payload.timestamp > 5_000 { NSLog("[ObscuraKit] SignalStore DROPPED stale"); return }

        let expiresAt = now + expiryMs

        // Remove existing entry from same author, add fresh
        var entries = active[key] ?? []
        entries.removeAll { $0.authorDeviceId == payload.authorDeviceId }
        entries.append((authorDeviceId: payload.authorDeviceId, expiresAt: expiresAt))
        active[key] = entries
    }

    /// Clear all active signals (e.g., when a real message arrives).
    public func clearAll() {
        active.removeAll()
    }

    /// Remove a signal explicitly (e.g., stoppedTyping).
    public func remove(model: String, signal: String, data: [String: String], authorDeviceId: String) {
        let key = signalKey(model: model, signal: signal, data: data)
        active[key]?.removeAll { $0.authorDeviceId == authorDeviceId }
    }

    /// Get all active (non-expired) author device IDs for a signal.
    public func getActive(model: String, signal: String, data: [String: String]) -> [String] {
        let key = signalKey(model: model, signal: signal, data: data)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let entries = active[key] ?? []
        let live = entries.filter { $0.expiresAt > now }
        active[key] = live
        if !live.isEmpty {
            NSLog("[ObscuraKit] SignalStore.getActive key=%@ count=%d", key, live.count)
        }
        return live.map(\.authorDeviceId)
    }

    /// Check if any signals are active for a given context.
    public func isActive(model: String, signal: String, data: [String: String]) -> Bool {
        !getActive(model: model, signal: signal, data: data).isEmpty
    }

    private func signalKey(model: String, signal: String, data: [String: String]) -> String {
        // Key only on conversationId (the primary context). Extra fields like senderUsername are ignored.
        let convId = data["conversationId"] ?? ""
        return "\(model):\(signal):\(convId)"
    }
}

// MARK: - Signal observation

/// Observable signal stream — push-based, fires immediately on signal changes.
public struct SignalObservation {
    let store: SignalStore
    let model: String
    let signal: String
    let data: [String: String]

    /// Stream of active author device IDs. Polls every 300ms.
    public var values: AsyncStream<[String]> {
        AsyncStream { continuation in
            let task = Task {
                var last: [String] = []
                while !Task.isCancelled {
                    let current = await store.getActive(model: model, signal: signal, data: data)
                    if current != last {
                        continuation.yield(current)
                        last = current
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - TypedModel signal extensions

extension TypedModel {
    /// Send a typing indicator for a conversation.
    /// Auto-throttled: won't send more than once per 2 seconds.
    public func typing(conversationId: String) async {
        let key = "typing:\(conversationId)"
        let now = Date()
        if let last = SignalThrottle.shared.lastSent[key], now.timeIntervalSince(last) < 2.0 {
            return // Throttled
        }
        SignalThrottle.shared.lastSent[key] = now
        await sendSignal(.typing, data: ["conversationId": conversationId])
    }

    /// Explicitly stop typing.
    public func stopTyping(conversationId: String) async {
        await sendSignal(.stoppedTyping, data: ["conversationId": conversationId])
    }

    /// Send a read receipt.
    public func read(conversationId: String) async {
        await sendSignal(.read, data: ["conversationId": conversationId])
    }

    /// Observe who is typing in a conversation.
    /// Returns a stream of active author device IDs.
    public func observeTyping(conversationId: String) -> SignalObservation {
        SignalObservation(
            store: signalStore,
            model: T.modelName,
            signal: SignalType.typing.rawValue,
            data: ["conversationId": conversationId]
        )
    }

    /// Observe read receipts for a conversation.
    public func observeRead(conversationId: String) -> SignalObservation {
        SignalObservation(
            store: signalStore,
            model: T.modelName,
            signal: SignalType.read.rawValue,
            data: ["conversationId": conversationId]
        )
    }

    // MARK: - Internal

    private var signalStore: SignalStore {
        SignalStoreRegistry.shared.store
    }

    private func sendSignal(_ type: SignalType, data: [String: String]) async {
        let payload = ModelSignalPayload(
            model: T.modelName,
            signal: type,
            data: data,
            authorDeviceId: model.deviceId
        )

        // Encode and send via the client
        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        // Build ClientMessage with type .modelSignal
        var msg = Obscura_V2_ClientMessage()
        msg.type = .modelSignal
        msg.text = jsonString  // Payload rides in the text field
        msg.timestamp = payload.timestamp

        guard let msgData = try? msg.serializedData() else { return }

        // Send to all friends (same as MODEL_SYNC)
        // Access the client through the model's broadcast callback
        await model.onSignalSend?(msgData)
    }
}

// MARK: - Global Signal Store

/// Signal send throttle — prevents flooding.
public class SignalThrottle {
    public static let shared = SignalThrottle()
    var lastSent: [String: Date] = [:]
    private init() {}
}

/// Singleton signal store — shared across all models.
public class SignalStoreRegistry {
    public static let shared = SignalStoreRegistry()
    public let store = SignalStore()

    /// Continuations waiting for signal changes
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    private init() {}

    /// Notify all observers that signals changed.
    public func notifyObservers() {
        for (_, cont) in observers {
            cont.yield()
        }
    }

    /// Subscribe to signal changes.
    func observe() -> (id: UUID, stream: AsyncStream<Void>) {
        let id = UUID()
        let stream = AsyncStream<Void> { continuation in
            self.observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.observers.removeValue(forKey: id)
            }
        }
        return (id, stream)
    }
}
