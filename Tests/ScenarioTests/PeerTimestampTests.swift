import XCTest
import GRDB
@testable import ObscuraKit

/// Peer-supplied `uint64` timestamps, and the uncatchable crashes they used to cause.
///
/// GRDB binds `UInt64` through the **non-failable** `Int64(self)`
/// (`GRDB/Core/Support/StandardLibrary/StandardLibrary.swift`), so any value above `Int64.max`
/// TRAPS on the way into SQLite. A Swift trap is not an error — `processEnvelope`'s `do/catch`
/// cannot contain it — so a single message killed the process. Friendship is not required to deliver
/// a message, so this was a remote kill available to any authenticated user.
///
/// The same bug class was found and fixed once, in `Wire/ModelSignal.swift`, which still carries the
/// paragraph explaining it. The sweep stopped at that one call site; these are the rest.
///
/// Each test's real assertion is that it **completes**. A trap does not fail an XCTest case, it kills
/// the test process, so reaching the `XCTAssert` at all is the result being checked.
final class PeerTimestampTests: XCTestCase {

    /// One past `Int64.max` — the exact value that trapped.
    private static let aboveInt64Max = UInt64(Int64.max) + 1

    /// Mirrors `ObscuraClient.clampFutureTimestamp`, which is private. Kept identical on purpose: if
    /// the production clamp changes, this diverges and the tests below stop describing it.
    private func clamp(_ t: UInt64) -> UInt64 {
        min(t, UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
    }

    // MARK: - TEXT → MessageStore

    /// `routeMessage`'s `.text` arm passed `msg.timestamp` straight into `messages.add`, which binds
    /// it at `MessageStore.swift`'s INSERT. Reachable by any TEXT from anyone.
    func testAClampedTextTimestampIsStorableAndAHostileOneWouldNotHaveBeen() async throws {
        let messages = try MessageActor()

        XCTAssertGreaterThan(Self.aboveInt64Max, UInt64(Int64.max),
                             "the fixture value must actually be the one that traps")

        try await messages.add("bob", Message(
            messageId: "m1", conversationId: "bob",
            timestamp: clamp(Self.aboveInt64Max), content: "hostile clock", isSent: false))

        let stored = await messages.getMessages("bob")
        XCTAssertEqual(stored.count, 1)
        XCTAssertLessThanOrEqual(stored[0].timestamp, UInt64(Int64.max),
                                 "a stored timestamp must fit in the INTEGER column it lives in")
    }

    /// The clamp is an ordering fix as well as a crash fix: a far-future timestamp must not survive
    /// to win every later comparison.
    func testTheClampPullsAFarFutureTimestampBackToRoughlyNow() {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let clamped = clamp(Self.aboveInt64Max)

        XCTAssertLessThanOrEqual(clamped, now + 60_000)
        XCTAssertGreaterThan(clamped, now - 60_000)
    }

    /// A timestamp that is merely a little ahead — a peer whose clock is a few seconds fast — passes
    /// through untouched. Clamping toward now must not rewrite honest values.
    func testASlightlyFastClockIsNotRewritten() {
        let slightlyAhead = UInt64(Date().timeIntervalSince1970 * 1000) + 5_000
        XCTAssertEqual(clamp(slightlyAhead), slightlyAhead)
    }

    // MARK: - EntryStore

    /// `EntryStore.put` did `Int64(entry.sentAt)` and `all` did `UInt64(row["timestamp"] as Int64)`.
    /// Both trap, and both are reachable across the bridge: `sentAt` originates in a peer's
    /// `ModelSync.timestamp` and reaches here by way of the inbox and the app's merge.
    /// `InboxStore.peek` documents the read-end hazard in a five-line comment; its sibling had
    /// neither the guard nor the comment.
    func testEntryStoreSaturatesInsteadOfTrappingAtBothEnds() async throws {
        let db = try DatabaseQueue()
        let entries = try EntryStore(db: db)

        // Write end: above Int64.max.
        try await entries.put(model: "story", entry: StoredEntry(
            id: "s1", data: #"{"x":1}"#, sentAt: Self.aboveInt64Max, authorDeviceId: "dev-1"))

        let written = try await entries.all(model: "story")
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].sentAt, UInt64(Int64.max), "the write saturates rather than trapping")

        // Read end: a negative written by a peer kit, where proto3 uint64 is a signed Long.
        try await db.write { db in
            try db.execute(sql: "UPDATE model_entries SET timestamp = ? WHERE id = ?",
                           arguments: [Int64(-1), "s1"])
        }

        let read = try await entries.all(model: "story")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].sentAt, 0, "a negative timestamp must clamp to 0, never trap")
    }
}
