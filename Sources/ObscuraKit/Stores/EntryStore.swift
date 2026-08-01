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
/// Ported from `ObscuraKit-Kotlin`'s `EntryStore.kt`. `InboxStore` is how messages arrive; this is
/// where the app keeps what it made of them. Together they are the whole data path.
///
/// ## Why it exists separately from the deleted `ModelStore`
///
/// **The table was kept; the engine above it was deleted.** `ORM/ModelStore` read and wrote these
/// same `model_entries` rows, but it was the bottom of a stack — CRDT merge, TTL, query DSL, schema
/// parser — that `HISTORY.md` removes entire. So the store the app keeps could not be that one; it had
/// to be a type that survives the deletion, over the same rows. Hence a separate file with no ORM
/// imports, rather than making `ModelStore` public.
///
/// The table is now two columns lighter (`ObscuraSchema` `v2`): `signature` held a keyless hash
/// nothing verified, and the separate `ttl` table went with `TTLManager`.
///
/// ## Three methods, and there is no fourth
///
/// `put` / `all` / `delete`. §9 is explicit that a query API is not part of this design, and names
/// the failure mode in advance: a table grows a filter, then an index abstraction, then observation,
/// and the deleted engine has been reimplemented in TypeScript and called a reset.
///
/// ## No merge, no CRDT, no TTL
///
/// `put` is a blind upsert. **The app decides who wins** — merge moved to obscura-pix's
/// `src/domain/merge.ts`. By the time a write reaches here the decision is made, so re-deciding it
/// would be a second implementation of the thing being deleted.
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
    /// A hard delete, not a tombstone. `HISTORY.md` establishes that the app never deletes an entry
    /// today and that the whole tombstone-ordering design was dead on arrival.
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
