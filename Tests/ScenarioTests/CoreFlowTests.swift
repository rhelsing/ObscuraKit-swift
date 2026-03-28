import XCTest
@testable import ObscuraKit

/// Scenario 1-4: Core Flow
/// Register → Login → Friend Request → Messaging → Persistence
///
/// These tests use ObscuraTestClient which calls ObscuraClient — the same API views use.
final class CoreFlowTests: XCTestCase {

    // MARK: - Scenario 1: Register + Token + Persistence

    func testScenario1_RegisterAndTokenValid() async throws {
        let alice = try await ObscuraTestClient.register()

        // Token should exist and be parseable
        XCTAssertNotNil(alice.token)
        XCTAssertNotNil(alice.userId)
        XCTAssertFalse(alice.userId!.isEmpty)

        // JWT should decode
        let payload = APIClient.decodeJWT(alice.token!)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?["sub"] as? String, alice.userId)
    }

    func testScenario1_RegisterCreatesStores() async throws {
        let alice = try await ObscuraTestClient.register()

        // Friends store should be empty but accessible
        let friends = await alice.friends.getAll()
        XCTAssertEqual(friends.count, 0)

        // Messages store should be empty
        let conversations = await alice.messages.getConversationIds()
        XCTAssertEqual(conversations.count, 0)
    }

    // MARK: - Scenario 2: Logout + Login + Identity Restored

    func testScenario2_LogoutAndLogin() async throws {
        let alice = try await ObscuraTestClient.register()
        let originalUserId = alice.userId!
        await rateLimitDelay()

        // Login again (simulating logout + login)
        try await alice.relogin()

        // Identity should be restored
        XCTAssertEqual(alice.userId, originalUserId)
        XCTAssertNotNil(alice.token)
    }

    // MARK: - Scenario 3: Friend Request Flow

    func testScenario3_FriendRequestAndAccept() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Alice adds Bob as pending_sent
        await alice.friends.add(bob.userId!, bob.username, status: .pendingSent)

        // Bob adds Alice as pending_received
        await bob.friends.add(alice.userId!, alice.username, status: .pendingReceived)

        // Verify pending states
        let alicePending = await alice.friends.getFriend(bob.userId!)
        XCTAssertEqual(alicePending?.status, .pendingSent)

        let bobPending = await bob.friends.getPending()
        XCTAssertEqual(bobPending.count, 1)
        XCTAssertEqual(bobPending[0].username, alice.username)

        // Bob accepts
        await bob.friends.updateStatus(alice.userId!, .accepted)
        // Alice updates too
        await alice.friends.updateStatus(bob.userId!, .accepted)

        // Both should see each other as accepted
        let aliceAccepted = await alice.friends.getAccepted()
        XCTAssertEqual(aliceAccepted.count, 1)
        XCTAssertEqual(aliceAccepted[0].username, bob.username)

        let bobAccepted = await bob.friends.getAccepted()
        XCTAssertEqual(bobAccepted.count, 1)
        XCTAssertEqual(bobAccepted[0].username, alice.username)

        // isFriend should be true
        let aliceIsFriend = await alice.friends.isFriend(bob.userId!)
        XCTAssertTrue(aliceIsFriend)
    }

    // MARK: - Scenario 4: Send Message + Persistence

    func testScenario4_MessagePersistence() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()

        // Set up friendship
        await alice.friends.add(bob.userId!, bob.username, status: .accepted)
        await bob.friends.add(alice.userId!, alice.username, status: .accepted)

        // Alice sends a message (persisted locally)
        let msg = Message(
            messageId: "msg_\(UUID().uuidString)",
            conversationId: bob.username,
            content: "hello from alice",
            isSent: true
        )
        await alice.messages.add(bob.username, msg)

        // Message should be retrievable
        let aliceMessages = await alice.messages.getMessages(bob.username)
        XCTAssertEqual(aliceMessages.count, 1)
        XCTAssertEqual(aliceMessages[0].content, "hello from alice")
        XCTAssertTrue(aliceMessages[0].isSent)

        // Bob receives the message (persisted on his side)
        let received = Message(
            messageId: msg.messageId,
            conversationId: alice.username,
            content: "hello from alice",
            isSent: false,
            authorDeviceId: "alice-device-1"
        )
        await bob.messages.add(alice.username, received)

        let bobMessages = await bob.messages.getMessages(alice.username)
        XCTAssertEqual(bobMessages.count, 1)
        XCTAssertEqual(bobMessages[0].content, "hello from alice")
        XCTAssertFalse(bobMessages[0].isSent)
    }

    func testScenario4_MessageIdempotent() async throws {
        let alice = try await ObscuraTestClient.register()

        let msg = Message(
            messageId: "msg_dup",
            conversationId: "bob",
            content: "hello"
        )

        // Add same message twice
        await alice.messages.add("bob", msg)
        await alice.messages.add("bob", msg)

        // Should only have one copy
        let messages = await alice.messages.getMessages("bob")
        XCTAssertEqual(messages.count, 1)
    }

    func testScenario4_MultipleConversations() async throws {
        let alice = try await ObscuraTestClient.register()

        await alice.messages.add("bob", Message(messageId: "m1", conversationId: "bob", content: "hi bob"))
        await alice.messages.add("carol", Message(messageId: "m2", conversationId: "carol", content: "hi carol"))

        let convos = await alice.messages.getConversationIds()
        XCTAssertEqual(convos.count, 2)
        XCTAssertTrue(convos.contains("bob"))
        XCTAssertTrue(convos.contains("carol"))
    }
}
