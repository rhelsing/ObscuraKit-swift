import XCTest
@testable import ObscuraKit

/// Offline message queuing — disconnect → server queues → reconnect → receive
/// Tests that the server holds messages for offline devices and delivers on reconnect.
final class OfflineQueueTests: XCTestCase {

    func testOfflineMessageDelivery() async throws {
        // send() requires an accepted friendship; the handshake leaves both connected.
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        // Bob goes offline
        bob.disconnectWebSocket()
        await rateLimitDelay()

        // Alice sends a message while Bob is offline
        // Server should queue it
        try await alice.send(to: bob.userId!, "you there?")
        await rateLimitDelay()

        // Bob reconnects
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Bob should receive the queued message
        let msg = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg.text, "you there?")
        XCTAssertEqual(msg.sourceUserId, alice.userId!)
        XCTAssertEqual(msg.type, 0, "Should be TEXT")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    func testMultipleOfflineMessages() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        // Bob goes offline
        bob.disconnectWebSocket()
        await rateLimitDelay()

        // Alice sends multiple messages while Bob is offline
        try await alice.send(to: bob.userId!, "message 1")
        await rateLimitDelay()
        try await alice.send(to: bob.userId!, "message 2")
        await rateLimitDelay()

        // Bob reconnects
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Bob should receive both queued messages
        let msg1 = try await bob.waitForMessage(timeout: 10)
        let msg2 = try await bob.waitForMessage(timeout: 10)

        let texts = [msg1.text, msg2.text].sorted()
        XCTAssertEqual(texts, ["message 1", "message 2"])

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    func testSessionSurvivesReconnect() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        // Exchange a message to establish session
        try await alice.send(to: bob.userId!, "before disconnect")
        await rateLimitDelay()

        let first = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(first.text, "before disconnect")

        // Bob disconnects and reconnects
        bob.disconnectWebSocket()
        await rateLimitDelay()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends another message (session should still work — Whisper, not PreKey)
        try await alice.send(to: bob.userId!, "after reconnect")
        await rateLimitDelay()

        let second = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(second.text, "after reconnect")
        XCTAssertEqual(second.sourceUserId, alice.userId!)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
