import XCTest
@testable import ObscuraKit

/// `send` — the outbox half of the thin kit (`obscura-proto/KIT_API.md` §5).
///
/// Mirrors `ObscuraKit-Kotlin`'s `EntrySendTests`. §5 names two properties and says to **prove them
/// with a test before building on this**, which is why they come first:
///
/// 1. the sending device must be excluded from its own fan-out;
/// 2. the sender gets no inbox row, so the app must write its own outgoing entry.
///
/// Both are load-bearing for obscura-pix's switch (§10 step 3): (1) decides whether the app has to
/// dedupe its own writes, and (2) decides whether "I sent it" and "it arrived" are one code path or
/// two.
final class EntrySendTests: XCTestCase {

    func testASentEntryArrivesInTheRecipientsInboxWithThePayloadUntouched() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await alice.befriend(bob.userId!)
        _ = try await bob.waitForMessage(timeout: 10)
        try await bob.acceptFriend(alice.userId!)
        _ = try await alice.waitForMessage(timeout: 10)

        let payload = Data(#"{"content":"opaque to the kit","expiresAt":123}"#.utf8)
        try await alice.client.send(
            to: [bob.userId!], modelKey: "directMessage", entryId: "dm_1", op: "CREATE", payload: payload
        )
        _ = try await bob.waitForMessage(timeout: 10)

        let rows = try await bob.client.inbox.peek()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.modelKey, "directMessage")
        XCTAssertEqual(rows.first?.entryId, "dm_1")
        XCTAssertEqual(rows.first?.op, "CREATE")
        XCTAssertEqual(rows.first?.payload, payload,
                       "the kit never opens the payload, so it must arrive byte-identical")
        XCTAssertEqual(rows.first?.senderUserId, alice.userId)

        alice.disconnectWebSocket(); bob.disconnectWebSocket()
    }

    /// **§5 property 1.** `getOwnDevices()` includes this device, so a send that does not filter
    /// would encrypt a copy to itself. The app would then see its own write arrive as an incoming
    /// row and have to dedupe it — a whole class of bug for no benefit.
    ///
    /// A single-device sender is the sharpest version: every own-device target IS this device, so an
    /// unfiltered fan-out has nowhere else to go and the echo is unmissable.
    func testTheSendingDeviceDoesNotReceiveItsOwnEntry() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await alice.befriend(bob.userId!)
        _ = try await bob.waitForMessage(timeout: 10)
        try await bob.acceptFriend(alice.userId!)
        _ = try await alice.waitForMessage(timeout: 10)

        let depthBefore = try await alice.client.inbox.depth()
        XCTAssertEqual(depthBefore, 0)

        try await alice.client.send(
            to: [bob.userId!], modelKey: "story", entryId: "story_1",
            payload: Data(#"{"content":"mine"}"#.utf8)
        )
        _ = try await bob.waitForMessage(timeout: 10)

        let aliceDepth = try await alice.client.inbox.depth()
        let bobDepth = try await bob.client.inbox.depth()
        XCTAssertEqual(aliceDepth, 0, "a device must not receive the entry it just sent — §5")
        XCTAssertEqual(bobDepth, 1, "...while the recipient still gets it")

        alice.disconnectWebSocket(); bob.disconnectWebSocket()
    }

    /// **§5 property 2, stated as a consequence rather than a mechanism.** Nothing loops back
    /// locally, so `send` alone leaves the sender with no record of what it sent. obscura-pix must
    /// write its own outgoing entry to `entries` — one write path in the kit, two in the app.
    ///
    /// The alternative design (the kit writes the sender's copy too) is the tempting one and would
    /// quietly re-import audience knowledge into the kit: to store it, the kit would have to decide
    /// which model and which id, from the payload.
    func testSendDoesNotStoreAnythingLocally() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await alice.befriend(bob.userId!)
        _ = try await bob.waitForMessage(timeout: 10)
        try await bob.acceptFriend(alice.userId!)
        _ = try await alice.waitForMessage(timeout: 10)

        try await alice.client.send(
            to: [bob.userId!], modelKey: "story", entryId: "story_1",
            payload: Data(#"{"content":"mine"}"#.utf8)
        )

        let stored = try await alice.client.entries.all(model: "story")
        XCTAssertTrue(stored.isEmpty,
                      "the kit stores nothing on send; the app writes its own outgoing entry")

        // ...and doing so is a one-liner, which is the point: the app already has the data.
        try await alice.client.entries.put(model: "story", entry: StoredEntry(
            id: "story_1", data: #"{"content":"mine"}"#,
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000),
            authorDeviceId: alice.client.deviceId ?? ""
        ))
        let after = try await alice.client.entries.all(model: "story")
        XCTAssertEqual(after.count, 1)

        alice.disconnectWebSocket(); bob.disconnectWebSocket()
    }

    /// An empty recipient list is "my own devices only", not an error. A self-scoped model wants
    /// exactly this, and the kit is not guessing an audience — the caller named one, and it was
    /// empty. Failing loud is reserved for an audience the kit was asked to invent (SPEC §1.2).
    func testAnEmptyRecipientListIsASelfSyncNotAFailure() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.connectWebSocket()
        await rateLimitDelay()

        try await alice.client.send(
            to: [], modelKey: "profile", entryId: "profile_1",
            payload: Data(#"{"displayName":"alice"}"#.utf8)
        )

        let depth = try await alice.client.inbox.depth()
        XCTAssertEqual(depth, 0, "single device, so there is nowhere to self-sync to")

        alice.disconnectWebSocket()
    }
}
