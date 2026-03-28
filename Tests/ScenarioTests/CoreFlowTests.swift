import XCTest
@testable import ObscuraKit

/// Scenario 1-4: Core Flow — ALL against actual server
/// Register with real Signal keys → Friend request via encrypted message → Text messaging via WebSocket
final class CoreFlowTests: XCTestCase {

    // MARK: - Scenario 1: Register with real keys

    func testScenario1_RegisterWithRealKeys() async throws {
        let alice = try await ObscuraTestClient.register()

        XCTAssertNotNil(alice.token, "Should have auth token")
        XCTAssertNotNil(alice.userId, "Should have userId from JWT")
        XCTAssertNotNil(alice.deviceId, "Should have deviceId (device-scoped token)")
        XCTAssertFalse(alice.userId!.isEmpty)
        XCTAssertFalse(alice.deviceId!.isEmpty)

        // JWT should decode correctly
        let payload = APIClient.decodeJWT(alice.token!)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?["sub"] as? String, alice.userId)
    }

    // MARK: - Scenario 2: Logout + Login

    func testScenario2_LogoutAndLogin() async throws {
        let alice = try await ObscuraTestClient.register()
        let originalUserId = alice.userId!
        let originalDeviceId = alice.deviceId!
        await rateLimitDelay()

        // Login again with stored deviceId
        let alice2 = try await ObscuraTestClient.login(
            alice.username,
            deviceId: originalDeviceId
        )

        XCTAssertEqual(alice2.userId, originalUserId, "UserId should be preserved")
    }

    // MARK: - Scenario 3: Friend Request via server

    func testScenario3_FriendRequestE2E() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Bob connects WebSocket to receive messages
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends friend request to Bob (encrypted via Signal, through server)
        try await alice.sendFriendRequest(to: bob.userId!)
        await rateLimitDelay()

        // Bob receives the friend request via WebSocket
        let received = try await bob.waitForMessage(timeout: 10)

        XCTAssertEqual(received.sourceUserId, alice.userId!, "Sender should be Alice")
        XCTAssertEqual(received.type, 2, "Type should be FRIEND_REQUEST (2)")
        XCTAssertEqual(received.username, alice.username, "Username should match")

        // Bob sends acceptance back
        // Alice needs to connect to receive the response
        try await alice.connectWebSocket()
        await rateLimitDelay()

        try await bob.sendFriendResponse(to: alice.userId!, accepted: true)
        await rateLimitDelay()

        // Alice receives the response
        let response = try await alice.waitForMessage(timeout: 10)

        XCTAssertEqual(response.sourceUserId, bob.userId!)
        XCTAssertEqual(response.type, 3, "Type should be FRIEND_RESPONSE (3)")
        XCTAssertTrue(response.accepted)

        // Cleanup
        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Scenario 4: Text message delivery via server

    func testScenario4_TextMessageE2E() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Bob connects WebSocket
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends text to Bob
        try await alice.sendText(to: bob.userId!, "hello from swift!")
        await rateLimitDelay()

        // Bob receives it
        let received = try await bob.waitForMessage(timeout: 10)

        XCTAssertEqual(received.sourceUserId, alice.userId!)
        XCTAssertEqual(received.type, 0, "Type should be TEXT (0)")
        XCTAssertEqual(received.text, "hello from swift!")

        // Bob replies
        try await alice.connectWebSocket()
        await rateLimitDelay()

        try await bob.sendText(to: alice.userId!, "hello back!")
        await rateLimitDelay()

        let reply = try await alice.waitForMessage(timeout: 10)

        XCTAssertEqual(reply.sourceUserId, bob.userId!)
        XCTAssertEqual(reply.text, "hello back!")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
