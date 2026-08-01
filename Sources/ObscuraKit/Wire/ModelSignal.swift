import Foundation

/// Ephemeral signals — typing indicators, read receipts, presence. Real-time state that
/// auto-expires and is never persisted, which is what makes it DROPPABLE
/// (`obscura-proto/KIT_API.md` §4) rather than something the inbox has to carry.
///
/// ```swift
/// await client.sendTyping(modelKey: "directMessage", conversationId: convId)
/// for await who in client.observeTyping(modelKey: "directMessage", conversationId: convId).values {}
/// ```
///
/// **This file lived in `ORM/` and is keep-forever code** (`obscura-proto/RESET.md`). It moved here
/// rather than being deleted with the engine, minus two extensions — `extension TypedModel` and
/// `extension Model` — which were the ORM's entrance to signals and referenced ORM types. Their
/// replacement is `ObscuraClient.sendTyping` / `stopTyping` / `observeTyping`, which take the
/// `modelKey` as an opaque string exactly as the inbox and the entry store do. That is what makes
/// this a relocation rather than a surviving fragment of the engine.

// MARK: - Signal Types

public enum SignalType: String, Sendable, Codable {
    case typing
    case stoppedTyping
    case read
}

/// In-memory representation of a received/derived signal, held by [SignalStore]
/// until it auto-expires. The wire form is the typed `ModelSignal` protobuf
/// message (not JSON); this struct is the kit-internal shape used by the store.
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

    /// Build a payload from a received wire signal. Identity (author, display name)
    /// and timestamp come from the authenticated ClientMessage envelope, not the payload.
    public init(model: String, signalRaw: String, conversationId: String, senderUsername: String, authorDeviceId: String, timestamp: UInt64) {
        self.model = model
        self.signal = signalRaw
        self.data = ["conversationId": conversationId, "senderUsername": senderUsername]
        self.authorDeviceId = authorDeviceId
        self.timestamp = timestamp
    }
}

// MARK: - Signal Store (in-memory, auto-expire)

/// Holds active signals in memory. Auto-expires after timeout.
/// Thread-safe via actor isolation.
public actor SignalStore {
    /// Key: "\(model):\(signal):\(contextKey)" → active signalers with username + expiry
    private var active: [String: [(authorDeviceId: String, senderUsername: String, expiresAt: UInt64)]] = [:]

    /// Signal expiry in milliseconds (default 5 seconds)
    private let expiryMs: UInt64 = 5_000

    /// Record an incoming signal. Auto-expires after 5 seconds.
    public func receive(_ payload: ModelSignalPayload) {
        let key = signalKey(model: payload.model, signal: payload.signal, data: payload.data)

        // Drop stale signals (older than 5 seconds).
        //
        // ⚠️ The subtraction MUST NOT be `now - payload.timestamp`. `payload.timestamp` is
        // peer-supplied and unclamped — it is `ClientMessage.timestamp` off the wire — so a peer
        // whose clock is even a millisecond ahead makes that expression negative, and `UInt64`
        // subtraction **traps**. A trap is not catchable, so `processEnvelope`'s `do/catch` cannot
        // contain it: the app dies.
        //
        // Any authenticated user can deliver a MODEL_SIGNAL (friendship is not required to send —
        // `KIT_API.md` §4.1), and Kotlin's sender stamps `System.currentTimeMillis()`, so an Android
        // peer with a slightly fast clock was enough. Remote crash, no privileges needed.
        //
        // Comparing instead of subtracting is total. A future timestamp is treated as fresh, which is
        // the same thing SPEC §2.4 does for a peer-supplied time it cannot trust: clamp toward now
        // rather than reject.
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if payload.timestamp < now && now - payload.timestamp > 5_000 { return }

        let expiresAt = now + expiryMs
        let username = payload.data["senderUsername"] ?? payload.authorDeviceId

        // Remove existing entry from same author, add fresh
        var entries = active[key] ?? []
        entries.removeAll { $0.authorDeviceId == payload.authorDeviceId }
        entries.append((authorDeviceId: payload.authorDeviceId, senderUsername: username, expiresAt: expiresAt))
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

    /// Get active usernames for a signal. Returns usernames (not device IDs).
    public func getActive(model: String, signal: String, data: [String: String]) -> [String] {
        let key = signalKey(model: model, signal: signal, data: data)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let entries = active[key] ?? []
        let live = entries.filter { $0.expiresAt > now }
        active[key] = live
        return live.map(\.senderUsername)
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

    /// Stream of active signalers, **by display name** — not by author device ID, whatever the
    /// name `authorDeviceId` on the payload suggests. `SignalStore.getActive` returns
    /// `senderUsername`. Polls every 300ms.
    ///
    /// Both defects this warning used to describe are fixed, and the fixes are what make the
    /// display name safe to emit:
    ///
    /// - The name no longer comes from the payload. `routeMessage`'s `.modelSignal` case looks
    ///   `sourceUserId` up in the local friend graph, so a peer can no longer choose how they are
    ///   labelled on screen (`obscura-proto/SPEC.md` §0.5).
    /// - `authorDeviceId` is no longer `sourceUserId`. It is the device UUID of the session that
    ///   decrypted, proven by the MAC (SPEC §0.10 rule 4, Phase 2) — which is what makes the
    ///   per-author dedupe in `SignalStore.receive` and `remove` correct rather than accidental.
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

// MARK: - Global Signal Store

/// Signal send throttle — prevents flooding.
public class SignalThrottle {
    public static let shared = SignalThrottle()
    var lastSent: [String: Date] = [:]
    private init() {}
}

/// Singleton signal store — shared across all models.
///
/// - Note: it carried a push-notification layer (`observe()` / `observers` / `notifyObservers()`)
///   whose only subscriber was the ORM's observation machinery, deleted in Phase 3. The two
///   surviving `notifyObservers()` calls in `routeMessage` iterated a permanently empty dictionary.
///   `SignalObservation.values` polls `SignalStore.getActive` directly and never used it.
public class SignalStoreRegistry {
    public static let shared = SignalStoreRegistry()
    public let store = SignalStore()

    private init() {}
}
