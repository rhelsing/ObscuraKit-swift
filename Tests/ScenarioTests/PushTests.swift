import XCTest
@testable import ObscuraKit

/// Push notification integration tests — against live server.
///
/// These cover the kit's contract with the bridge layer: `registerPushToken(_:)` and
/// `processPendingMessages(timeout:)`. No APNS/FCM involvement — we simulate the
/// "silent push wakes the app" scenario by disconnecting Bob, sending from Alice,
/// then having Bob call `processPendingMessages()` to drain and classify.
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
    /// background). Alice sends 2 pix + 1 directMessage. Bob calls
    /// `processPendingMessages()` which connects, drains the envelopes, and returns counts.
    /// Bridge would use these to post "New pix" (pix wins on tie).
    func testProcessPendingMessagesCategorizes() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        // Both must define the same ORM schema so sync decoding works
        let pixDef = ModelDefinition(
            name: "pix",
            sync: .lwwMap,
            syncScope: .friends,
            fields: ["recipientUsername": .string, "senderUsername": .string, "mediaRef": .string]
        )
        let dmDef = ModelDefinition(
            name: "directMessage",
            sync: .gset,
            syncScope: .friends,
            fields: ["conversationId": .string, "content": .string, "senderUsername": .string]
        )
        alice.client.schema([pixDef, dmDef])
        bob.client.schema([pixDef, dmDef])

        // Bob goes offline — simulates app in background/killed
        bob.disconnectWebSocket()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Alice sends 2 pix + 1 directMessage while Bob is offline
        let alicePix = alice.client.model("pix")!
        let aliceDM = alice.client.model("directMessage")!

        _ = try await alicePix.create([
            "recipientUsername": bob.username,
            "senderUsername": alice.username,
            "mediaRef": "fake-attachment-1"
        ])
        await rateLimitDelay()
        _ = try await alicePix.create([
            "recipientUsername": bob.username,
            "senderUsername": alice.username,
            "mediaRef": "fake-attachment-2"
        ])
        await rateLimitDelay()
        _ = try await aliceDM.create([
            "conversationId": [alice.userId!, bob.userId!].sorted().joined(separator: ":"),
            "content": "hello",
            "senderUsername": alice.username
        ])
        await rateLimitDelay()

        // Server queues envelopes. Bob calls processPendingMessages — simulates silent push wake.
        let counts = await bob.client.processPendingMessages(timeout: 15)

        XCTAssertEqual(counts.pixCount, 2, "Should have drained 2 pix envelopes")
        XCTAssertEqual(counts.messageCount, 1, "Should have drained 1 directMessage envelope")
        XCTAssertEqual(counts.otherCount, 0, "No non-ORM envelopes expected in this scenario")

        // Kit must NOT have disconnected — OS will freeze the app when done
        XCTAssertEqual(bob.client.connectionState, ConnectionState.connected)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    /// Edge case: no pending envelopes. Should return zero counts quickly (idle detection).
    func testProcessPendingMessagesEmpty() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.connectWebSocket()

        let start = Date()
        let counts = await alice.client.processPendingMessages(timeout: 10)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(counts.pixCount, 0)
        XCTAssertEqual(counts.messageCount, 0)
        XCTAssertEqual(counts.otherCount, 0)
        XCTAssertLessThan(elapsed, 2.0, "Should return within 500ms idle threshold + slack, not full 10s timeout")

        alice.disconnectWebSocket()
    }

    /// Connect-if-needed: kit must establish connection when called cold (post-wake, disconnected).
    func testProcessPendingMessagesConnectsIfNeeded() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        XCTAssertNotEqual(alice.client.connectionState, .connected, "Precondition: not connected")

        let counts = await alice.client.processPendingMessages(timeout: 10)
        XCTAssertEqual(counts.pixCount, 0)
        XCTAssertEqual(alice.client.connectionState, ConnectionState.connected, "Should have connected during drain")

        alice.disconnectWebSocket()
    }
}
