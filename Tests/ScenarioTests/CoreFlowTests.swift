import XCTest
@testable import ObscuraKit

/// Scenarios 1-4: Full state machine test — modeled after JS scenario-1-4.spec.js.
/// Every step verifies BOTH message delivery AND database state.
/// Uses file-backed storage to test persistence through "restart".
final class CoreFlowTests: XCTestCase {

    private func tempDir(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "obscura_core_\(label)_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dirs: String...) {
        for dir in dirs { try? FileManager.default.removeItem(atPath: dir) }
    }

    // MARK: - Scenario 1-4: Register → Friend → Message → Persist → Queued Delivery

    func testFullCoreFlow() async throws {
        let aliceDir = tempDir("alice")
        let bobDir = tempDir("bob")
        defer { cleanup(aliceDir, bobDir) }

        let apiURL = "https://obscura.barrelmaker.dev"
        let password = "testpass123456"
        let aliceUsername = "test_\(Int.random(in: 100000...999999))"
        let bobUsername = "test_\(Int.random(in: 100000...999999))"

        // ============================================================
        // PHASE 1: Register Alice (file-backed)
        // ============================================================

        let alice = try ObscuraClient(apiURL: apiURL, dataDirectory: aliceDir)
        try await alice.register(aliceUsername, password)
        await rateLimitDelay()

        XCTAssertTrue(alice.hasSession, "Alice should have session after register")
        XCTAssertNotNil(alice.userId)
        XCTAssertNotNil(alice.deviceId)
        XCTAssertNotNil(alice.persistentSignalStore)
        XCTAssertTrue(alice.persistentSignalStore!.hasPersistedIdentity, "Signal identity should be persisted")

        let aliceFriends0 = await alice.friends.getAccepted()
        XCTAssertEqual(aliceFriends0.count, 0, "Alice should have no friends initially")

        let aliceConvos0 = await alice.messages.getConversationIds()
        XCTAssertEqual(aliceConvos0.count, 0, "Alice should have no conversations initially")

        let aliceUserId = alice.userId!
        let aliceDeviceId = alice.deviceId!
        let aliceToken = alice.token!
        let aliceRefreshToken = alice.refreshToken

        // ============================================================
        // PHASE 2: Register Bob (file-backed)
        // ============================================================

        let bob = try ObscuraClient(apiURL: apiURL, dataDirectory: bobDir)
        try await bob.register(bobUsername, password)
        await rateLimitDelay()

        XCTAssertTrue(bob.hasSession)
        XCTAssertNotNil(bob.userId)
        XCTAssertTrue(bob.persistentSignalStore!.hasPersistedIdentity)

        let bobUserId = bob.userId!
        let bobDeviceId = bob.deviceId!
        let bobToken = bob.token!
        let bobRefreshToken = bob.refreshToken

        // ============================================================
        // PHASE 3: Friend Request — full state machine
        // ============================================================

        try await alice.connect()
        try await bob.connect()
        await rateLimitDelay()

        // Alice sends friend request to Bob
        try await alice.befriend(bobUserId, username: bobUsername)
        await rateLimitDelay()

        // Assert Alice's store: pendingSent with Bob's username
        let aliceFriendAfterBefriend = await alice.friends.getFriend(bobUserId)
        XCTAssertNotNil(aliceFriendAfterBefriend, "Alice should have Bob in friend store after befriend")
        XCTAssertEqual(aliceFriendAfterBefriend?.status, .pendingSent, "Alice's entry should be pendingSent")
        XCTAssertEqual(aliceFriendAfterBefriend?.username, bobUsername, "Alice should have Bob's username")

        // Bob receives FRIEND_REQUEST
        let friendReq = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(friendReq.type, 2, "Should be FRIEND_REQUEST (2)")
        XCTAssertEqual(friendReq.sourceUserId, aliceUserId)
        XCTAssertEqual(friendReq.username, aliceUsername, "Request should carry Alice's username")

        // Assert Bob's store: pendingReceived with Alice's username
        let bobFriendAfterReq = await bob.friends.getFriend(aliceUserId)
        XCTAssertNotNil(bobFriendAfterReq, "Bob should have Alice in friend store after receiving request")
        XCTAssertEqual(bobFriendAfterReq?.status, .pendingReceived)
        XCTAssertEqual(bobFriendAfterReq?.username, aliceUsername, "Bob should have Alice's username from the message")

        // Bob accepts
        try await bob.acceptFriend(aliceUserId, username: aliceUsername)
        await rateLimitDelay()

        // Assert Bob's store: accepted
        let bobFriendAfterAccept = await bob.friends.getFriend(aliceUserId)
        XCTAssertEqual(bobFriendAfterAccept?.status, .accepted, "Bob's entry should be accepted")

        // Alice receives FRIEND_RESPONSE
        let friendResp = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(friendResp.type, 3, "Should be FRIEND_RESPONSE (3)")
        XCTAssertTrue(friendResp.accepted)

        // Assert Alice's store: accepted
        let aliceFriendAfterAccept = await alice.friends.getFriend(bobUserId)
        XCTAssertEqual(aliceFriendAfterAccept?.status, .accepted, "Alice's entry should be accepted")

        // Both should have exactly 1 accepted friend
        let aliceAccepted = await alice.friends.getAccepted()
        let bobAccepted = await bob.friends.getAccepted()
        XCTAssertEqual(aliceAccepted.count, 1)
        XCTAssertEqual(bobAccepted.count, 1)

        // ============================================================
        // PHASE 4: Text Messaging — full state machine
        // ============================================================

        // Alice sends to Bob
        try await alice.send(to: bobUserId, "Hello from Alice!")
        await rateLimitDelay()

        // Assert Alice's store: sent message persisted
        let aliceMsgs1 = await alice.messages.getMessages(bobUserId)
        XCTAssertEqual(aliceMsgs1.count, 1, "Alice should have 1 message in store")
        XCTAssertTrue(aliceMsgs1[0].isSent, "Alice's message should be isSent=true")
        XCTAssertEqual(aliceMsgs1[0].content, "Hello from Alice!")

        // Bob receives
        let bobRecv1 = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(bobRecv1.text, "Hello from Alice!")
        XCTAssertEqual(bobRecv1.type, 0, "Should be TEXT (0)")

        // Assert Bob's store: received message persisted
        let bobMsgs1 = await bob.messages.getMessages(aliceUserId)
        XCTAssertEqual(bobMsgs1.count, 1, "Bob should have 1 message in store")
        XCTAssertFalse(bobMsgs1[0].isSent, "Bob's message should be isSent=false")
        XCTAssertEqual(bobMsgs1[0].content, "Hello from Alice!")

        // Bob replies
        try await bob.send(to: aliceUserId, "Hello from Bob!")
        await rateLimitDelay()

        // Assert Bob's store: 2 messages (1 received, 1 sent)
        let bobMsgs2 = await bob.messages.getMessages(aliceUserId)
        XCTAssertEqual(bobMsgs2.count, 2)
        let bobSent = bobMsgs2.filter { $0.isSent }
        let bobRecvd = bobMsgs2.filter { !$0.isSent }
        XCTAssertEqual(bobSent.count, 1)
        XCTAssertEqual(bobRecvd.count, 1)

        // Alice receives Bob's reply
        let aliceRecv2 = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(aliceRecv2.text, "Hello from Bob!")

        // Assert Alice's store: 2 messages (1 sent, 1 received)
        let aliceMsgs2 = await alice.messages.getMessages(bobUserId)
        XCTAssertEqual(aliceMsgs2.count, 2)
        let aliceSent = aliceMsgs2.filter { $0.isSent }
        let aliceRecvd = aliceMsgs2.filter { !$0.isSent }
        XCTAssertEqual(aliceSent.count, 1)
        XCTAssertEqual(aliceRecvd.count, 1)

        // Conversation list should have 1 entry on each side
        let aliceConvos = await alice.messages.getConversationIds()
        let bobConvos = await bob.messages.getConversationIds()
        XCTAssertEqual(aliceConvos.count, 1)
        XCTAssertEqual(bobConvos.count, 1)

        // ============================================================
        // PHASE 5: Persistence through "restart" (file-backed)
        // ============================================================

        alice.disconnect()
        bob.disconnect()

        // Create new clients from same directories — simulates app restart
        let alice2 = try ObscuraClient(apiURL: apiURL, dataDirectory: aliceDir)
        let bob2 = try ObscuraClient(apiURL: apiURL, dataDirectory: bobDir)

        // Signal identity should survive
        XCTAssertTrue(alice2.persistentSignalStore!.hasPersistedIdentity, "Alice identity should survive restart")
        XCTAssertTrue(bob2.persistentSignalStore!.hasPersistedIdentity, "Bob identity should survive restart")

        // Friends should survive
        let alice2Friends = await alice2.friends.getAccepted()
        let bob2Friends = await bob2.friends.getAccepted()
        XCTAssertEqual(alice2Friends.count, 1, "Alice should still have 1 friend after restart")
        XCTAssertEqual(alice2Friends[0].username, bobUsername, "Friend username should survive restart")
        XCTAssertEqual(bob2Friends.count, 1, "Bob should still have 1 friend after restart")
        XCTAssertEqual(bob2Friends[0].username, aliceUsername)

        // Messages should survive
        let alice2Msgs = await alice2.messages.getMessages(bobUserId)
        let bob2Msgs = await bob2.messages.getMessages(aliceUserId)
        XCTAssertEqual(alice2Msgs.count, 2, "Alice should still have 2 messages after restart")
        XCTAssertEqual(bob2Msgs.count, 2, "Bob should still have 2 messages after restart")

        // ============================================================
        // PHASE 6: Queued delivery after restart
        // ============================================================

        // Restore Alice's session and connect
        await alice2.restoreSession(
            token: aliceToken, refreshToken: aliceRefreshToken,
            userId: aliceUserId, deviceId: aliceDeviceId, username: aliceUsername
        )
        await alice2.ensureFreshToken()
        try await alice2.connect()
        await rateLimitDelay()

        // Alice sends while Bob is still "dead"
        try await alice2.send(to: bobUserId, "While you were away!")
        await rateLimitDelay()
        try await Task.sleep(nanoseconds: 1_000_000_000) // give server time to queue

        // Bob restarts and connects
        await bob2.restoreSession(
            token: bobToken, refreshToken: bobRefreshToken,
            userId: bobUserId, deviceId: bobDeviceId, username: bobUsername
        )
        await bob2.ensureFreshToken()
        try await bob2.connect()

        // Bob should receive the queued message
        let queuedMsg = try await bob2.waitForMessage(timeout: 15)
        XCTAssertEqual(queuedMsg.text, "While you were away!")
        XCTAssertEqual(queuedMsg.sourceUserId, aliceUserId)

        // Assert Bob's store: 3 messages now (2 from before + 1 queued)
        let bob2Msgs2 = await bob2.messages.getMessages(aliceUserId)
        XCTAssertEqual(bob2Msgs2.count, 3, "Bob should have 3 messages after queued delivery")

        alice2.disconnect()
        bob2.disconnect()
    }
}
