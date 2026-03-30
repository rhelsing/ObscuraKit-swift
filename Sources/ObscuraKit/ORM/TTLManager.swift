import Foundation

/// Manages ephemeral content expiration for ORM models.
/// Mirrors src/v2/orm/sync/TTLManager.js
///
/// Usage: TTLManager schedules expiry when models with `.ttl` are created.
/// Call `cleanup()` periodically (or on reconnect) to delete expired entries.
public class TTLManager {
    private let store: ModelStore
    private var getModel: ((String) -> Model?)?

    public init(store: ModelStore) {
        self.store = store
    }

    /// Set the model resolver — called by SchemaBuilder/SyncManager.
    public func setModelResolver(_ resolver: @escaping (String) -> Model?) {
        self.getModel = resolver
    }

    // MARK: - Schedule

    /// Schedule expiration for an entry based on its model's TTL.
    public func schedule(modelName: String, id: String, ttl: TTL) async {
        let expiresAt = UInt64(Date().timeIntervalSince1970 * 1000) + ttl.milliseconds
        await store.setTTL(modelName: modelName, id: id, expiresAt: expiresAt)
    }

    // MARK: - Cleanup

    /// Delete all expired entries. LWW models get tombstoned, GSet entries get removed from storage.
    /// Returns count of cleaned entries.
    @discardableResult
    public func cleanup() async -> Int {
        let expired = await store.getExpired()
        var count = 0

        for (modelName, id) in expired {
            guard let model = getModel?(modelName) else {
                // Unknown model — just remove the TTL entry
                await store.delete(modelName, id)
                count += 1
                continue
            }

            if model.definition.sync == .lwwMap {
                // LWW: create tombstone
                _ = try? await model.delete(id)
            } else {
                // GSet: can't delete (immutable), just remove from storage
                await store.delete(modelName, id)
            }

            count += 1
        }

        return count
    }

    // MARK: - Query

    /// Check if an entry is expired.
    public func isExpired(modelName: String, id: String) async -> Bool {
        guard let expiresAt = await store.getTTL(modelName: modelName, id: id) else {
            return false
        }
        return UInt64(Date().timeIntervalSince1970 * 1000) >= expiresAt
    }

    /// Get time remaining in milliseconds, or nil if no TTL set.
    public func timeRemaining(modelName: String, id: String) async -> UInt64? {
        guard let expiresAt = await store.getTTL(modelName: modelName, id: id) else {
            return nil
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if now >= expiresAt { return 0 }
        return expiresAt - now
    }
}
