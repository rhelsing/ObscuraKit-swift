import XCTest
@testable import ObscuraKit

/// Message state machine — verify store state at every step.
/// Every test goes through the full chain: register → register → befriend → accept → send.
final class MessageStateMachineTests: XCTestCase {

    // MARK: - Sent message appears in sender's store

    func testSentMessageAppearsInSenderStore() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        try await alice.send(to: bob.userId!, "test message")
        _ = try await bob.waitForMessage(timeout: 10)

        let msgs = await alice.messages.getMessages(bob.userId!)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertTrue(msgs[0].isSent, "Sender's copy should be isSent=true")
        XCTAssertEqual(msgs[0].content, "test message")
        XCTAssertEqual(msgs[0].conversationId, bob.userId!)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Received message appears in receiver's store

    func testReceivedMessageAppearsInReceiverStore() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        try await alice.send(to: bob.userId!, "hello bob")
        _ = try await bob.waitForMessage(timeout: 10)

        let msgs = await bob.messages.getMessages(alice.userId!)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertFalse(msgs[0].isSent, "Receiver's copy should be isSent=false")
        XCTAssertEqual(msgs[0].content, "hello bob")
        XCTAssertEqual(msgs[0].conversationId, alice.userId!)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Conversation list updates

    func testConversationListUpdatesOnMessage() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        let convos0 = await alice.messages.getConversationIds()
        XCTAssertEqual(convos0.count, 0, "No conversations initially")

        try await alice.send(to: bob.userId!, "first convo")
        _ = try await bob.waitForMessage(timeout: 10)

        let convos1 = await alice.messages.getConversationIds()
        XCTAssertEqual(convos1.count, 1, "Should have 1 conversation after first send")
        XCTAssertEqual(convos1[0], bob.userId!)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Messages ordered by timestamp

    func testMessagesOrderedByTimestamp() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        try await alice.send(to: bob.userId!, "first")
        _ = try await bob.waitForMessage(timeout: 10)
        try await alice.send(to: bob.userId!, "second")
        _ = try await bob.waitForMessage(timeout: 10)
        try await alice.send(to: bob.userId!, "third")
        _ = try await bob.waitForMessage(timeout: 10)

        let msgs = await bob.messages.getMessages(alice.userId!)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].content, "first")
        XCTAssertEqual(msgs[1].content, "second")
        XCTAssertEqual(msgs[2].content, "third")
        XCTAssertLessThanOrEqual(msgs[0].timestamp, msgs[1].timestamp)
        XCTAssertLessThanOrEqual(msgs[1].timestamp, msgs[2].timestamp)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Bidirectional messaging

    func testBidirectionalMessaging() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        try await alice.send(to: bob.userId!, "from alice")
        _ = try await bob.waitForMessage(timeout: 10)
        try await bob.send(to: alice.userId!, "from bob")
        _ = try await alice.waitForMessage(timeout: 10)

        // Alice's store: 1 sent, 1 received
        let aliceMsgs = await alice.messages.getMessages(bob.userId!)
        XCTAssertEqual(aliceMsgs.count, 2)
        XCTAssertEqual(aliceMsgs.filter { $0.isSent }.count, 1)
        XCTAssertEqual(aliceMsgs.filter { !$0.isSent }.count, 1)

        // Bob's store: 1 received, 1 sent
        let bobMsgs = await bob.messages.getMessages(alice.userId!)
        XCTAssertEqual(bobMsgs.count, 2)
        XCTAssertEqual(bobMsgs.filter { $0.isSent }.count, 1)
        XCTAssertEqual(bobMsgs.filter { !$0.isSent }.count, 1)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Sending to non-friend throws

    func testSendToNonFriendThrows() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // No friendship established — send should throw
        do {
            try await alice.send(to: bob.userId!, "should fail")
            XCTFail("Should have thrown notFriends")
        } catch let error as ObscuraClient.ObscuraError {
            if case .notFriends = error {} else {
                XCTFail("Expected notFriends error, got \(error)")
            }
        }
    }
}
