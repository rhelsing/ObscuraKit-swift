import Foundation
import GRDB

/// One drained inbox row, as the app sees it (`obscura-proto/KIT_API.md` §3.1).
///
/// `payload` is opaque bytes the kit never parsed. The `ModelSync`-derived fields are `nil` for every
/// other kind, including an unknown arm — there is no `ModelSync` to derive them from.
public struct InboxRecord: Sendable, Equatable {
    public let id: Int64
    public let envelopeId: String
    public let kind: String
    public let receivedAt: UInt64
    public let senderUserId: String
    public let senderDeviceId: String?
    public let senderDisplayName: String?
    public let modelKey: String?
    public let entryId: String?
    public let op: String?
    public let sentAt: UInt64?
    public let payload: Data

    public init(
        id: Int64 = 0,
        envelopeId: String,
        kind: String,
        receivedAt: UInt64,
        senderUserId: String,
        senderDeviceId: String? = nil,
        senderDisplayName: String? = nil,
        modelKey: String? = nil,
        entryId: String? = nil,
        op: String? = nil,
        sentAt: UInt64? = nil,
        payload: Data
    ) {
        self.id = id
        self.envelopeId = envelopeId
        self.kind = kind
        self.receivedAt = receivedAt
        self.senderUserId = senderUserId
        self.senderDeviceId = senderDeviceId
        self.senderDisplayName = senderDisplayName
        self.modelKey = modelKey
        self.entryId = entryId
        self.op = op
        self.sentAt = sentAt
        self.payload = payload
    }
}

/// The durable inbox (`obscura-proto/KIT_API.md` §3).
///
/// The kit is a durable, authenticated inbox for **opaque payloads**: it stores bytes it cannot read,
/// addressed to and from identities it can prove. This actor is that store.
///
/// Ported from `ObscuraKit-Kotlin`'s `InboxDomain.kt` (PR #49), which is where the shape was designed
/// and proven against a real server. §10 orders it that way on purpose.
///
/// ## Why an inbox and not an event stream
///
/// The reset takes application data away from the kit. If the thin kit instead handed each payload
/// to the app — an event, a callback, a bridge emit — and then acked, the ordering becomes:
///
/// ```
/// decrypt → emit to app → ACK (server DELETEs) → ...app writes to its store, maybe, later
/// ```
///
/// That is the Phase 1 data-loss bug rebuilt across a process boundary, in both kits at once, on a
/// path where the app may not be running. The React Native bridge is asynchronous and lossy under
/// backpressure, and the iOS push path has no JS runtime at all. **So the kit must persist before it
/// acks, and therefore needs somewhere durable to put bytes it does not understand.**
///
/// ## Four methods, and there is no fifth
///
/// `peek` / `consume` / `discard` / `depth`. In particular there is **no insert**: the inbox is
/// kit-write, app-read-and-delete (§3.3 rule 9). The only candidate for an app-side write was
/// self-sync, and it does not need one — a send fans out to the user's *other* devices via the
/// server, which receive it through the ordinary envelope path. The originating device is never
/// echoed to and writes its own store directly.
public actor InboxStore {
    private let db: DatabaseQueue

    /// Reports a discard to the security log. Taken at construction rather than set afterwards: a
    /// store that is reachable before its hook is wired can lose a discard silently, which is the
    /// quiet path §3.3 rule 5 forbids.
    private let onDiscard: (@Sendable ([Int64], String) -> Void)?

    public init(db: DatabaseQueue, onDiscard: (@Sendable ([Int64], String) -> Void)? = nil) throws {
        self.db = db
        self.onDiscard = onDiscard
        try ObscuraSchema.migrate(db)
    }

    public init(onDiscard: (@Sendable ([Int64], String) -> Void)? = nil) throws {
        self.db = try DatabaseQueue()
        self.onDiscard = onDiscard
        try db.write { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        try ObscuraSchema.migrate(db)
    }

    /// Persist a decrypted message. **Kit-internal**: called from the receive loop before the ack,
    /// never by the app.
    ///
    /// Throws if the write fails, which is the point — the caller must not ack what is not stored.
    ///
    /// Returns `true` if a row was inserted, `false` if `envelopeId` was already present. A `false`
    /// is a *successful* redelivery absorption, not an error: the message is already durably held,
    /// so the caller should ack exactly as it would after a fresh insert. Acking is what stops the
    /// server sending it a third time.
    @discardableResult
    func put(_ record: InboxRecord) async throws -> Bool {
        try await db.write { db in
            let existedBefore = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM inbox_rows WHERE envelope_id = ?)",
                arguments: [record.envelopeId]) ?? false

            try db.execute(sql: """
                INSERT OR IGNORE INTO inbox_rows (
                    envelope_id, kind, received_at, sender_user_id, sender_device_id,
                    sender_display_name, model_key, entry_id, op, sent_at, payload
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                record.envelopeId, record.kind, Int64(record.receivedAt), record.senderUserId,
                record.senderDeviceId, record.senderDisplayName, record.modelKey, record.entryId,
                record.op, record.sentAt.map { Int64($0) }, record.payload,
            ])

            // Assert the postcondition the ack depends on, rather than inferring it from a row
            // count. `changesCount` tells you "did OR IGNORE suppress something" — and OR IGNORE
            // suppresses EVERY constraint, not just the `envelope_id UNIQUE` it is documented
            // against. A NOT NULL or CHECK violation would report exactly like a redelivery, and the
            // caller ACKS on a redelivery, so the server would delete a message never stored.
            let existsNow = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM inbox_rows WHERE envelope_id = ?)",
                arguments: [record.envelopeId]) ?? false
            guard existsNow else {
                throw DatabaseError(message: "inbox row for envelope \(record.envelopeId) is absent "
                    + "after insert; refusing to report it as stored")
            }
            return !existedBefore
        }
    }

    /// The next rows to process, in drain order, oldest first.
    ///
    /// **Side-effect free.** Peeking twice without consuming returns the same rows — that is the
    /// crash-safety property, not a bug: an app that dies mid-drain reprocesses, and the merge rules
    /// downstream are idempotent so that reprocessing converges.
    public func peek(limit: Int = 50) async throws -> [InboxRecord] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM inbox_rows ORDER BY id ASC LIMIT ?
            """, arguments: [limit]).map { row in
                InboxRecord(
                    id: row["id"],
                    envelopeId: row["envelope_id"],
                    kind: row["kind"],
                    receivedAt: UInt64(row["received_at"] as Int64),
                    senderUserId: row["sender_user_id"],
                    senderDeviceId: row["sender_device_id"],
                    senderDisplayName: row["sender_display_name"],
                    modelKey: row["model_key"],
                    entryId: row["entry_id"],
                    op: row["op"],
                    // Saturating, not `UInt64(_:)`: that TRAPS on a negative value, which would be a
                    // hard crash in `peek` — and a negative `sent_at` is reachable, because
                    // `ModelSync.timestamp` is proto3 `uint64` and Kotlin's protobuf surfaces it as
                    // a signed Long. A row written by a peer kit must never be able to crash a drain.
                    sentAt: (row["sent_at"] as Int64?).map { $0 < 0 ? 0 : UInt64($0) },
                    payload: row["payload"]
                )
            }
        }
    }

    /// Drop rows the app has durably processed.
    ///
    /// Idempotent, and a subset is fine — partial progress is normal, not an error path.
    public func consume(_ ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        // Chunked because each id binds one SQL variable and SQLite caps that at 999 on older
        // builds. The app chooses the batch size, so a large `peek` followed by `consume` would
        // throw "too many SQL variables" — exactly when a backlog exists, i.e. the one situation
        // where the drain must not stall (§3.5).
        for chunk in stride(from: 0, to: ids.count, by: deleteChunk).map({
            Array(ids[$0..<min($0 + deleteChunk, ids.count)])
        }) {
            try await db.write { db in
                try db.execute(
                    sql: "DELETE FROM inbox_rows WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
                    arguments: StatementArguments(chunk))
            }
        }
    }

    /// Comfortably under SQLite's 999-variable floor.
    private let deleteChunk = 500

    /// Drop rows the app declares it can **never** process.
    ///
    /// This is data loss, chosen deliberately: the server's copy is already gone, so nothing else
    /// holds these bytes. It is therefore logged as a security-relevant event and must never be the
    /// quiet path (§3.3 rule 5) — which is the entire reason it is a separate method from
    /// ``consume(_:)`` rather than a flag on it. The SQL is identical; the accountability is not.
    public func discard(_ ids: [Int64], reason: String) async throws {
        guard !ids.isEmpty else { return }
        try await consume(ids)
        onDiscard?(ids, reason)
    }

    /// How many rows are waiting.
    ///
    /// Exposed because it MUST be (§3.3 rule 7): unbounded growth means the app has stopped draining.
    /// §3.5 traces where that ends — inbox grows, disk pressure, the durable write throws, the kit
    /// correctly refuses to ack, the message stays on the server, the *server's* queue hits 1000, and
    /// it evicts oldest-first and silently. **A number nobody reads is not observability**: the app is
    /// expected to surface this past a threshold, not merely be able to ask.
    public func depth() async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_rows") ?? 0
        }
    }

    /// Destroy every row.
    ///
    /// The §3.3 rule 2 carve-out, and **not** an eviction policy: a device wipe or a remote
    /// revocation has to be able to destroy decrypted plaintext, and that is a security requirement.
    /// Note it takes no selector — destroying the whole store is what keeps it from becoming "drop
    /// the oldest when things get tight", which is the rule this design exists to refuse.
    func wipe() async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM inbox_rows")
        }
    }
}

/// `?, ?, ?` for an `IN` clause. GRDB has no variadic binding for `IN`, and string-interpolating the
/// ids themselves would be an injection site even for integers.
private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
