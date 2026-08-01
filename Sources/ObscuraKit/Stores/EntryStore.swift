import Foundation
import GRDB

/// One stored entry. `data` is an opaque JSON string the kit never parses.
///
/// `sentAt` and `authorDeviceId` are carried because the app's merge needs them — REPLACE is a total
/// order on `(sentAt, authorDeviceId)` (`KIT_API.md` §8.2). They are metadata in columns beside the
/// payload, not fields the kit reads out of it.
public struct StoredEntry: Sendable, Equatable {
    public let id: String
    public let data: String
    public let sentAt: UInt64
    public let authorDeviceId: String

    public init(id: String, data: String, sentAt: UInt64, authorDeviceId: String) {
        self.id = id
        self.data = data
        self.sentAt = sentAt
        self.authorDeviceId = authorDeviceId
    }
}

/// Raw storage for application entries (`obscura-proto/KIT_API.md` §8.1).
///
/// `InboxStore` is how messages arrive; this is where the app keeps what it made of them. The API is
/// `put` / `all` / `delete`. `put` is a blind upsert; the app resolves merge before writing. This
/// store has no schema parser, query layer, merge engine, or expiry policy.
public actor EntryStore {
    private let db: DatabaseQueue

    public init(db: DatabaseQueue) throws {
        self.db = db
        try ObscuraSchema.migrate(db)
    }

    public init() throws {
        self.db = try DatabaseQueue()
        try db.write { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        try ObscuraSchema.migrate(db)
    }

    /// Write an entry, replacing any existing one with the same `(model, id)`.
    ///
    /// Blind by design — see the type doc. `data` is stored verbatim; the kit does not validate it as
    /// JSON, because validating a shape it may not read is a boundary violation dressed as
    /// defensiveness (SPEC §0.4).
    public func put(model: String, entry: StoredEntry) async throws {
        // Saturating, not `Int64(_:)`: that TRAPS above `Int64.max`, and a trap is not catchable.
        // `sentAt` reaches here from a peer's `ModelSync.timestamp` by way of the inbox and the
        // app's merge, so it is untrusted `uint64` that crossed a bridge. `InboxStore.peek`
        // documents the mirror image of this at the READ end (a negative `sent_at` from Kotlin's
        // signed Long); the write end was left un-hardened.
        let sentAt = Int64(clamping: entry.sentAt)
        try await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO model_entries
                    (model_name, id, data, timestamp, author_device_id)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [model, entry.id, entry.data, sentAt, entry.authorDeviceId])
        }
    }

    /// Every live entry for a model, in no guaranteed order.
    public func all(model: String) async throws -> [StoredEntry] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, data, timestamp, author_device_id FROM model_entries WHERE model_name = ?
            """, arguments: [model]).map { row in
                StoredEntry(
                    id: row["id"],
                    data: row["data"],
                    // `max(0, …)` before the conversion, for the same reason `InboxStore.peek`
                    // saturates: `UInt64(_:)` TRAPS on a negative, and a row written by a peer kit
                    // (Kotlin surfaces proto3 `uint64` as a signed Long) must never crash a read.
                    sentAt: UInt64(max(0, row["timestamp"] as Int64)),
                    authorDeviceId: row["author_device_id"]
                )
            }
        }
    }

    /// Remove an entry outright.
    ///
    /// A local hard delete, not a synchronized tombstone.
    ///
    /// - Note: Kotlin's `EntryStore.delete` soft-deletes, because that table carries a `deleted`
    ///   column and its `selectByModel` filters on it, while `model_entries` here has no such column.
    ///   The observable behaviour is identical — the entry stops appearing in `all` — and the app
    ///   cannot tell the difference through the bridge.
    public func delete(model: String, id: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM model_entries WHERE model_name = ? AND id = ?",
                           arguments: [model, id])
        }
    }
}
