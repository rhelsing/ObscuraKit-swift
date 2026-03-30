import XCTest
@testable import ObscuraKit

/// Proves the ORM can handle message-like content — conversation-scoped,
/// queryable by conversationId, ordered by timestamp.
/// Uses a "directMessage" ORM model instead of the hardcoded MessageActor.
final class ORMMessageTests: XCTestCase {

    private let messageDef = ModelDefinition(
        name: "directMessage",
        sync: .gset,
        syncScope: .friends,
        fields: [
            "conversationId": .string,
            "content": .string,
            "senderUsername": .string
        ]
    )

    /// Alice sends a message via ORM, Bob queries it by conversationId.
    func testORM_messageQueryByConversation() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        alice.client.schema([messageDef])
        bob.client.schema([messageDef])

        let aliceMessages = alice.client.model("directMessage")!
        let bobMessages = bob.client.model("directMessage")!

        // Alice sends 2 messages in one conversation
        let convId = "conv_\(alice.userId!)_\(bob.userId!)"
        _ = try await aliceMessages.create([
            "conversationId": convId,
            "content": "hello bob",
            "senderUsername": alice.username
        ])
        _ = try await aliceMessages.create([
            "conversationId": convId,
            "content": "how are you?",
            "senderUsername": alice.username
        ])

        // Bob receives both
        _ = try await bob.waitForMessage(timeout: 10)
        _ = try await bob.waitForMessage(timeout: 10)

        // Bob queries by conversationId
        let results = await bobMessages.where(["data.conversationId": convId]).orderBy("timestamp", .asc).exec()
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].data["content"] as? String, "hello bob")
        XCTAssertEqual(results[1].data["content"] as? String, "how are you?")
    }

    /// Messages survive offline — Bob is offline, Alice sends, Bob reconnects and queries.
    func testORM_messageOfflineDeliveryAndQuery() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        alice.client.schema([messageDef])
        bob.client.schema([messageDef])

        let convId = "conv_offline_test"

        // Bob goes offline
        bob.disconnectWebSocket()
        await rateLimitDelay()

        // Alice sends while Bob is offline
        let aliceMessages = alice.client.model("directMessage")!
        _ = try await aliceMessages.create([
            "conversationId": convId,
            "content": "sent while offline",
            "senderUsername": alice.username
        ])
        await rateLimitDelay()

        // Bob reconnects
        try await bob.connectWebSocket()
        await rateLimitDelay()
        _ = try await bob.waitForMessage(timeout: 10)

        // Bob can query the message
        let bobMessages = bob.client.model("directMessage")!
        let results = await bobMessages.where(["data.conversationId": convId]).exec()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].data["content"] as? String, "sent while offline")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    /// Bidirectional message exchange via ORM — both sides send and receive.
    func testORM_bidirectionalMessages() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        alice.client.schema([messageDef])
        bob.client.schema([messageDef])

        let convId = "conv_bidir"
        let aliceModel = alice.client.model("directMessage")!
        let bobModel = bob.client.model("directMessage")!

        // Alice sends
        _ = try await aliceModel.create([
            "conversationId": convId,
            "content": "from alice",
            "senderUsername": alice.username
        ])
        _ = try await bob.waitForMessage(timeout: 10)

        // Bob replies
        _ = try await bobModel.create([
            "conversationId": convId,
            "content": "from bob",
            "senderUsername": bob.username
        ])
        _ = try await alice.waitForMessage(timeout: 10)

        // Both should have both messages, queryable by conversation
        let aliceResults = await aliceModel.where(["data.conversationId": convId]).orderBy("timestamp", .asc).exec()
        let bobResults = await bobModel.where(["data.conversationId": convId]).orderBy("timestamp", .asc).exec()

        XCTAssertEqual(aliceResults.count, 2)
        XCTAssertEqual(bobResults.count, 2)

        // Both see same conversation in same order
        let aliceContents = aliceResults.map { $0.data["content"] as? String }
        let bobContents = bobResults.map { $0.data["content"] as? String }
        XCTAssertEqual(aliceContents, ["from alice", "from bob"])
        XCTAssertEqual(bobContents, ["from alice", "from bob"])

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
