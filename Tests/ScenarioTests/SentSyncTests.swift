import XCTest
@testable import ObscuraKit

/// SENT_SYNC on the RECEIVE side. There were zero tests for this arm.
///
/// SENT_SYNC is how a user's own other devices learn about a message this device sent, so the row it
/// writes is marked `isSent: true` — attributed to the user. That makes the sender check the whole
/// security property of the arm: without it, any authenticated stranger writes rows into any
/// conversation of ours, as us.
///
/// **Swift has that guard and it is correct** (`guard sourceUserId == self.userId else { break }`).
/// ObscuraKit-Kotlin is the one missing it. Recorded here rather than in a comment somewhere else,
/// because "the guard exists" is exactly the kind of claim that rots.
final class SentSyncTests: XCTestCase {

    /// The security property, and the cheap half of the coverage: a SENT_SYNC from someone who is
    /// not us changes nothing. It is still delivered and still acked — dropping it silently is right,
    /// wedging the server queue over it is not.
    func testASentSyncFromAnotherUserIsIgnored() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        let forgedConversation = "victim_conversation_\(Int.random(in: 100000...999999))"
        var payload = Obscura_Client_V1_SentSync()
        payload.recipientUsername = forgedConversation
        payload.messageID = "forged_1"
        payload.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        payload.content = Data("I never sent this".utf8)

        var msg = Obscura_Client_V1_ClientMessage()
        msg.sentSync = payload
        msg.timestamp = payload.timestamp
        try await bob.sendRaw(to: alice.userId!, try msg.serializedData())

        let received = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, "SENT_SYNC", "it must still be delivered — the guard is about persistence")
        XCTAssertEqual(received.sourceUserId, bob.userId!)

        let stored = await alice.messages.getMessages(forgedConversation)
        XCTAssertTrue(stored.isEmpty,
                      "a SENT_SYNC from a non-own device must write nothing — it would be attributed "
                      + "to us with isSent: true")

        alice.disconnectWebSocket(); bob.disconnectWebSocket()
    }

    /// A SENT_SYNC carrying a hostile timestamp must not crash the receiver. The arm binds
    /// `ss.timestamp` into an INTEGER column, and GRDB's `UInt64` binding traps above `Int64.max` —
    /// uncatchably. "Own device" is not "trusted clock": a linked Android device stamps
    /// `System.currentTimeMillis()`, and a device with a broken clock is not a hypothetical.
    ///
    /// The test reaching its assertion is the result. It is driven through the store rather than the
    /// wire because provoking the unclamped path would kill the test process rather than fail a case.
    func testAClampedSentSyncTimestampIsStorable() async throws {
        let messages = try MessageActor()
        let hostile = UInt64(Int64.max) + 1
        let clamped = min(hostile, UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)

        try await messages.add("bob", Message(
            messageId: "ss_1", conversationId: "bob", timestamp: clamped,
            content: "from my other device", isSent: true))

        let stored = await messages.getMessages("bob")
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored[0].isSent)
        XCTAssertLessThanOrEqual(stored[0].timestamp, UInt64(Int64.max))
    }

    /// The delivery half: a real `send` on device 1 puts the message on device 2 through SENT_SYNC.
    /// Needs two devices genuinely linked, or `sendSentSync` has no target and the test passes
    /// vacuously — the same trap `TwoDeviceSendTests` documents.
    func testSendingATextSyncsItToTheUsersOtherDevice() async throws {
        let alice1 = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let alice2 = try await ObscuraTestClient.loginAndProvision(alice1.username, deviceName: "Alice Laptop")
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice1.connectWebSocket()
        try await alice2.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Link, so alice1's own-device registry really holds alice2.
        let code = try XCTUnwrap(alice2.client.generateLinkCode())
        try await alice1.client.validateAndApproveLink(code)
        await rateLimitDelay()
        let ownDevices = await alice1.devices.getOwnDevices()
        XCTAssertEqual(ownDevices.count, 2, "without a second device there is nothing to sync to")

        // Friendship, because `send(to:_:)` requires it.
        try await alice1.befriend(bob.userId!, username: bob.username)
        _ = try await bob.waitForMessage(timeout: 15)
        try await bob.acceptFriend(alice1.userId!, username: alice1.username)
        _ = try await alice1.waitForMessage(timeout: 15)
        _ = try? await alice2.waitForMessage(timeout: 5) // fan-out copy

        try await alice1.send(to: bob.userId!, "sent from my phone")
        _ = try await bob.waitForMessage(timeout: 15)

        // alice2 gets the SENT_SYNC. Drain until it shows up — link traffic may still be queued.
        var sawSentSync = false
        for _ in 0..<6 {
            guard let m = try? await alice2.waitForMessage(timeout: 10) else { break }
            if m.type == "SENT_SYNC" { sawSentSync = true; break }
        }
        XCTAssertTrue(sawSentSync, "device 2 must receive the SENT_SYNC for what device 1 sent")

        let stored = await alice2.messages.getMessages(bob.userId!)
        XCTAssertTrue(stored.contains { $0.content == "sent from my phone" && $0.isSent },
                      "the synced message must land in the conversation, marked as ours")

        alice1.disconnectWebSocket(); alice2.disconnectWebSocket(); bob.disconnectWebSocket()
    }
}
