import XCTest
@testable import ObscuraKit

/// Smoke tests for connection resilience — reconnect, ping keepalive, message survival.
final class ReconnectTests: XCTestCase {

    /// Gateway disconnect triggers auto-reconnect. Messages flow after reconnect.
    func testAutoReconnect_messagesFlowAfterDrop() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        // Verify messaging works
        try await alice.send(to: bob.userId!, "before drop")
        let msg1 = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg1.text, "before drop")

        // Simulate gateway disconnect on Bob's side
        await bob.client.gateway.disconnect()
        await rateLimitDelay()

        // Bob's client should auto-reconnect
        // Wait for reconnect (backoff starts at 1s)
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Verify Bob is connected again
        XCTAssertEqual(bob.client.connectionState, .connected,
                       "Bob should auto-reconnect after gateway drop")

        // Alice sends another message — should arrive on reconnected Bob
        try await alice.send(to: bob.userId!, "after reconnect")
        let msg2 = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg2.text, "after reconnect")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    /// ORM content survives reconnect cycle.
    func testORM_survivesReconnect() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        let storyDef = ModelDefinition(name: "story", sync: .gset, syncScope: .friends,
                                       fields: ["content": .string])
        alice.client.schema([storyDef])
        bob.client.schema([storyDef])

        // Create story before disconnect
        _ = try await alice.client.model("story")!.create(["content": "before drop"])
        _ = try await bob.waitForMessage(timeout: 10)

        // Disconnect Bob
        await bob.client.gateway.disconnect()
        await rateLimitDelay()

        // Alice creates while Bob is reconnecting
        _ = try await alice.client.model("story")!.create(["content": "during reconnect"])
        await rateLimitDelay()

        // Wait for Bob to reconnect
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Bob should get the queued story
        let msg = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg.type, 30) // MODEL_SYNC

        let bobStories = await bob.client.model("story")!.all()
        XCTAssertEqual(bobStories.count, 2)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    /// Explicit disconnect() does NOT auto-reconnect.
    func testExplicitDisconnect_noReconnect() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        await rateLimitDelay()

        // Explicit disconnect
        alice.disconnectWebSocket()
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Should stay disconnected — no auto-reconnect
        XCTAssertEqual(alice.client.connectionState, .disconnected,
                       "Explicit disconnect should not trigger auto-reconnect")
    }

    /// Connection survives idle period (ping keepalive).
    func testPingKeepAlive_connectionSurvivesIdle() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        // Idle for 35 seconds (longer than ping interval of 30s)
        try await Task.sleep(nanoseconds: 35_000_000_000)

        // Connection should still be alive
        XCTAssertEqual(alice.client.connectionState, .connected)
        XCTAssertEqual(bob.client.connectionState, .connected)

        // Messages should still flow
        try await alice.send(to: bob.userId!, "still alive")
        let msg = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg.text, "still alive")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
