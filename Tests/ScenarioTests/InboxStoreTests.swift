import XCTest
import GRDB
@testable import ObscuraKit

/// The durable inbox (`obscura-proto/KIT_API.md` §3).
///
/// Mirrors `ObscuraKit-Kotlin`'s `InboxDomainTest`, deliberately assertion-for-assertion: §10 has
/// Kotlin design the shape and Swift port the proven one, and the tests are part of what is being
/// ported. Where the two kits' tests disagree, one of the kits is wrong.
///
/// These check the properties the design is *for*, not the SQL. Each corresponds to a normative rule,
/// and most exist because getting the rule wrong loses messages permanently — the row is the only
/// copy once the kit has acked, because **an ACK is a DELETE**.
final class InboxStoreTests: XCTestCase {

    private func makeInbox(onDiscard: (@Sendable ([Int64], String) -> Void)? = nil) throws -> InboxStore {
        try InboxStore(db: try DatabaseQueue(), onDiscard: onDiscard)
    }

    private func record(
        _ envelopeId: String,
        kind: String = "MODEL_SYNC",
        payload: Data = Data("{}".utf8),
        modelKey: String? = "directMessage"
    ) -> InboxRecord {
        InboxRecord(
            envelopeId: envelopeId,
            kind: kind,
            receivedAt: 1_700_000_000_000,
            senderUserId: "user_peer",
            senderDeviceId: "device_peer",
            senderDisplayName: "alice",
            modelKey: modelKey,
            entryId: "entry_1",
            op: "OP_CREATE",
            sentAt: 1_700_000_000_000,
            payload: payload
        )
    }

    // MARK: - §3.3 rule 8: idempotence

    /// The rule the whole design leans on. Persist-then-ack **guarantees** redelivery: the ack is
    /// best-effort and its failure is swallowed, so the server's per-connection cursor re-sends on
    /// the next connection. That is correct behaviour — losing the message would be worse.
    ///
    /// The deleted engine absorbed redelivery **by accident**: `ModelStore.put` was
    /// `INSERT OR REPLACE` keyed on `(model, id)`, so a re-delivered entry overwrote itself. The
    /// inbox is keyed on a monotonic `id` instead, so nothing about its primary key would collide —
    /// without `envelope_id UNIQUE` and `INSERT OR IGNORE` (§3.3 rule 8) the same redelivery would
    /// insert a SECOND row, and the replacement would be strictly *less* idempotent than what it
    /// replaced.
    func testRedeliveredEnvelopeDoesNotCreateASecondRow() async throws {
        let inbox = try makeInbox()

        let first = try await inbox.put(record("env_1"))
        let second = try await inbox.put(record("env_1"))

        XCTAssertTrue(first, "first insert should create a row")
        XCTAssertFalse(second, "redelivery must be absorbed, not duplicated")
        let depth = try await inbox.depth()
        XCTAssertEqual(depth, 1)
    }

    /// `put` returning false is a *successful* absorption, not a failure — the message is already
    /// durably held. The caller must still ack, because acking is what stops the server sending it a
    /// third time. This pins the contract that makes that safe to rely on.
    func testRedeliveryKeepsTheOriginallyStoredRow() async throws {
        let inbox = try makeInbox()

        try await inbox.put(record("env_1", payload: Data("original".utf8)))
        try await inbox.put(record("env_1", payload: Data("tampered".utf8)))

        let rows = try await inbox.peek()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(String(decoding: rows[0].payload, as: UTF8.self), "original",
                       "INSERT OR IGNORE keeps the first write; a later copy of the same envelope cannot overwrite it")
    }

    /// **`put` must never report "stored" for a message it did not store.** This is the precondition
    /// the entire feature rests on: the caller acks on a successful `put`, and an ack is a DELETE, so
    /// a `put` that lies destroys the message.
    ///
    /// The subtle version of that lie is why this exists. `INSERT OR IGNORE` suppresses EVERY
    /// constraint, not just the `envelope_id UNIQUE` it is written for — so `changesCount`, the
    /// obvious "did a row get added?" implementation, reports a NOT NULL or CHECK violation exactly
    /// as it reports a harmless redelivery. The caller acks on a redelivery.
    ///
    /// Dropping the table is a blunt way to make the write fail, and that is the point: whatever the
    /// reason, "the row is not there" must reach the caller as a throw and never as `false`.
    func testPutThrowsRatherThanReportingStoredWhenTheRowIsNotThere() async throws {
        let db = try DatabaseQueue()
        let inbox = try InboxStore(db: db)
        try await db.write { db in try db.execute(sql: "DROP TABLE inbox_rows") }

        do {
            _ = try await inbox.put(record("env_1"))
            XCTFail("put must throw when the row cannot be stored, never return false")
        } catch {
            // expected
        }
    }

    // MARK: - §3.3 rule 3: peek is side-effect free

    /// The crash-safety property, stated as a test because it reads like a bug otherwise: draining
    /// twice without consuming returns the same rows. An app that dies between peek and consume
    /// reprocesses them, and the merge rules downstream are idempotent so that converges.
    func testPeekingTwiceWithoutConsumingReturnsTheSameRows() async throws {
        let inbox = try makeInbox()
        try await inbox.put(record("env_1"))
        try await inbox.put(record("env_2"))

        let first = try await inbox.peek()
        let second = try await inbox.peek()

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first, second)
        let depth = try await inbox.depth()
        XCTAssertEqual(depth, 2, "peek must not consume")
    }

    /// Drain order is oldest-first, because the app processes in arrival order.
    func testPeekReturnsRowsInInsertionOrderAndRespectsTheLimit() async throws {
        let inbox = try makeInbox()
        for i in 0..<5 { try await inbox.put(record("env_\(i)")) }

        let rows = try await inbox.peek(limit: 3)

        XCTAssertEqual(rows.map(\.envelopeId), ["env_0", "env_1", "env_2"])
    }

    /// `id` must be monotonic across the whole install, and that is why the column is AUTOINCREMENT.
    /// A plain INTEGER PRIMARY KEY aliases rowid, which SQLite **reuses after deletion** — so a
    /// drained-then-refilled inbox would hand out ids that go backwards, and `peek` orders by id.
    func testIdsKeepIncreasingAfterRowsAreConsumed() async throws {
        let inbox = try makeInbox()
        try await inbox.put(record("env_1"))
        try await inbox.put(record("env_2"))
        let firstBatch = try await inbox.peek()
        try await inbox.consume(firstBatch.map(\.id))

        try await inbox.put(record("env_3"))
        let afterDrain = try await inbox.peek()

        XCTAssertEqual(afterDrain.count, 1)
        XCTAssertGreaterThan(afterDrain[0].id, firstBatch.map(\.id).max()!,
                             "rowid reuse would make drain order go backwards; AUTOINCREMENT prevents it")
    }

    // MARK: - §3.3 rules 2, 4, 5: removal

    func testConsumeIsIdempotentAndAcceptsASubset() async throws {
        let inbox = try makeInbox()
        for i in 0..<3 { try await inbox.put(record("env_\(i)")) }
        let rows = try await inbox.peek()

        try await inbox.consume([rows[0].id])
        try await inbox.consume([rows[0].id]) // again — partial progress is normal, not an error

        let depth = try await inbox.depth()
        XCTAssertEqual(depth, 2)
        let remaining = try await inbox.peek()
        XCTAssertEqual(remaining.map(\.envelopeId), ["env_1", "env_2"])
    }

    func testConsumeOfAnEmptyListIsANoOp() async throws {
        let inbox = try makeInbox()
        try await inbox.put(record("env_1"))

        try await inbox.consume([])

        let depth = try await inbox.depth()
        XCTAssertEqual(depth, 1)
    }

    /// A discard is data loss the app chose — the server's copy is already gone, so nothing else
    /// holds these bytes. §3.3 rule 5 requires it be logged as a security-relevant event, and this
    /// pins that the hook actually fires. It is the entire reason discard is a separate method from
    /// consume rather than a flag: the SQL is identical, the accountability is not.
    func testDiscardRemovesRowsAndReportsThemForTheSecurityLog() async throws {
        let box = DiscardBox()
        let inbox = try makeInbox { ids, reason in box.record(ids: ids, reason: reason) }
        try await inbox.put(record("env_1"))
        try await inbox.put(record("env_2"))

        let rows = try await inbox.peek()
        try await inbox.discard([rows[0].id], reason: "unknown modelKey from a newer peer")

        let depth = try await inbox.depth()
        XCTAssertEqual(depth, 1)
        XCTAssertEqual(box.reasons, ["unknown modelKey from a newer peer"])
    }

    func testDiscardingNothingDoesNotLogASecurityEvent() async throws {
        let box = DiscardBox()
        let inbox = try makeInbox { ids, reason in box.record(ids: ids, reason: reason) }

        try await inbox.discard([], reason: "nothing to do")

        XCTAssertTrue(box.reasons.isEmpty,
                      "an empty discard is not a data-loss event and must not read as one")
    }

    // MARK: - §3.3 rule 7: depth

    func testDepthReflectsWhatIsWaiting() async throws {
        let inbox = try makeInbox()
        var depth = try await inbox.depth()
        XCTAssertEqual(depth, 0)

        for i in 0..<4 { try await inbox.put(record("env_\(i)")) }
        depth = try await inbox.depth()
        XCTAssertEqual(depth, 4)

        let batch = try await inbox.peek(limit: 2)
        try await inbox.consume(batch.map(\.id))

        depth = try await inbox.depth()
        XCTAssertEqual(depth, 2)
    }

    // MARK: - §3.1: the record

    func testEveryFieldSurvivesARoundTripIncludingOpaquePayloadBytes() async throws {
        let inbox = try makeInbox()
        // Deliberately not valid UTF-8: the payload is opaque bytes and must not be re-encoded.
        let payload = Data([0, 1, 2, 255, 127, 128])
        try await inbox.put(record("env_1", payload: payload))

        let rows = try await inbox.peek()
        let row = try XCTUnwrap(rows.first)

        XCTAssertEqual(row.envelopeId, "env_1")
        XCTAssertEqual(row.kind, "MODEL_SYNC")
        XCTAssertEqual(row.senderUserId, "user_peer")
        XCTAssertEqual(row.senderDeviceId, "device_peer")
        XCTAssertEqual(row.senderDisplayName, "alice")
        XCTAssertEqual(row.modelKey, "directMessage")
        XCTAssertEqual(row.entryId, "entry_1")
        XCTAssertEqual(row.op, "OP_CREATE")
        XCTAssertEqual(row.payload, payload)
    }

    /// An unknown arm has no ModelSync to derive from, so those columns are null (§4.1). The row
    /// still exists, which is the point — the message is preserved rather than destroyed.
    func testAnUnknownArmIsStoredWithNilModelSyncFields() async throws {
        let inbox = try makeInbox()
        try await inbox.put(
            InboxRecord(
                envelopeId: "env_1",
                kind: "UNKNOWN_ARM",
                receivedAt: 1_700_000_000_000,
                senderUserId: "user_peer",
                senderDeviceId: "device_peer",
                payload: Data([9, 9, 9])
            )
        )

        // The await is hoisted: XCTUnwrap takes an autoclosure, which cannot contain one.
        let rows = try await inbox.peek()
        let row = try XCTUnwrap(rows.first)

        XCTAssertEqual(row.kind, "UNKNOWN_ARM")
        XCTAssertNil(row.modelKey)
        XCTAssertNil(row.entryId)
        XCTAssertNil(row.op)
        XCTAssertNil(row.sentAt)
    }

    // MARK: - §3.3 rule 2 carve-out

    /// A device wipe or remote revocation must be able to destroy decrypted plaintext. Note it takes
    /// no selector: destroying the whole store is what keeps this a security operation rather than
    /// "drop the oldest when things get tight", which is the policy §3.4 refuses to add.
    func testWipeDestroysEverything() async throws {
        let inbox = try makeInbox()
        for i in 0..<3 { try await inbox.put(record("env_\(i)")) }

        try await inbox.wipe()

        let depth = try await inbox.depth()
        XCTAssertEqual(depth, 0)
    }
}

/// Collects discard callbacks. A plain captured array would need `nonisolated(unsafe)` or trip
/// Sendable checking, and a class with a lock says what it is.
private final class DiscardBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _reasons: [String] = []

    var reasons: [String] {
        lock.lock(); defer { lock.unlock() }
        return _reasons
    }

    func record(ids: [Int64], reason: String) {
        lock.lock(); defer { lock.unlock() }
        _reasons.append(reason)
    }
}
