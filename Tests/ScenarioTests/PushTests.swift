import XCTest
@testable import ObscuraKit

/// Push notification integration tests — against live server.
///
/// These cover the kit's contract with the bridge layer: `registerPushToken(_:)` and
/// `processPendingMessages(timeout:)`. No APNS/FCM involvement — we simulate the
/// "silent push wakes the app" scenario by disconnecting Bob, sending from Alice,
/// then having Bob call `processPendingMessages()` to drain.
final class PushTests: XCTestCase {

    // MARK: - Token Registration

    /// `registerPushToken` must succeed against the live server with a valid device JWT.
    /// Server upserts by deviceId, so calling twice is safe.
    func testRegisterPushToken() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.connectWebSocket()
        await rateLimitDelay()

        let fakeToken = "test-apns-token-\(UUID().uuidString)"
        try await alice.client.registerPushToken(fakeToken)
        await rateLimitDelay()

        // Idempotent — second call with same token still 200
        try await alice.client.registerPushToken(fakeToken)
        await rateLimitDelay()

        // New token replaces old — server upserts by deviceId
        try await alice.client.registerPushToken("test-apns-token-\(UUID().uuidString)")

        alice.disconnectWebSocket()
    }

    // MARK: - processPendingMessages — the push wake drain

    /// Simulates the silent push wake flow. Bob disconnects (like an app going to
    /// background). Alice sends three opaque model entries. Bob calls
    /// `processPendingMessages()` which connects, drains the envelopes, and returns one total.
    func testProcessPendingMessagesDrainsOpaqueModels() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        // Bob goes offline — simulates app in background/killed
        bob.disconnectWebSocket()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Model keys and payloads are opaque to the kit.
        for i in 1...2 {
            try await alice.client.send(
                to: [bob.userId!], modelKey: "model-a", entryId: "entry-a-\(i)",
                payload: Data("opaque-a-\(i)".utf8))
            await rateLimitDelay()
        }
        try await alice.client.send(
            to: [bob.userId!], modelKey: "model-b", entryId: "entry-b-1",
            payload: Data("opaque-b".utf8))
        await rateLimitDelay()

        // Server queues envelopes. Bob calls processPendingMessages — simulates silent push wake.
        let processed = await bob.client.processPendingMessages(timeout: 15)
        XCTAssertEqual(processed, 3, "Should have processed exactly 3 opaque envelopes")
        var queuedModels: [String?] = []
        for _ in 0..<3 {
            queuedModels.append(try await bob.waitForMessage(timeout: 2).model)
        }
        XCTAssertEqual(
            queuedModels,
            ["model-a", "model-a", "model-b"],
            "Push draining must not consume the test event queue")

        // Kit must NOT have disconnected — OS will freeze the app when done
        XCTAssertEqual(bob.client.connectionState, ConnectionState.connected)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    /// Edge case: no pending envelopes. Should return zero quickly (idle detection).
    func testProcessPendingMessagesEmpty() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.connectWebSocket()

        let start = Date()
        let processed = await alice.client.processPendingMessages(timeout: 10)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(processed, 0)
        XCTAssertLessThan(elapsed, 2.0, "Should return within 500ms idle threshold + slack, not full 10s timeout")

        alice.disconnectWebSocket()
    }

    /// Connect-if-needed: kit must establish connection when called cold (post-wake, disconnected).
    func testProcessPendingMessagesConnectsIfNeeded() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        XCTAssertNotEqual(alice.client.connectionState, .connected, "Precondition: not connected")

        let processed = await alice.client.processPendingMessages(timeout: 10)
        XCTAssertEqual(processed, 0)
        XCTAssertEqual(alice.client.connectionState, ConnectionState.connected, "Should have connected during drain")

        alice.disconnectWebSocket()
    }
}
