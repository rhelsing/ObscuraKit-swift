import XCTest
@testable import ObscuraKit

/// Matches Kotlin's DeviceTakeoverTests.kt
/// Device takeover: replace identity key, verify server accepts, messaging resumes.
final class DeviceTakeoverTests: XCTestCase {

    func testTakeoverReplacesKeysOnServer() async throws {
        let alice = try await ObscuraTestClient.register()
        let oldRegId = alice.client.registrationId
        await rateLimitDelay()

        try await alice.client.takeoverDevice()
        await rateLimitDelay()

        XCTAssertNotEqual(oldRegId, alice.client.registrationId, "Registration ID should change after takeover")

        // New identity should be persisted in Signal store
        XCTAssertNotNil(alice.client.persistentSignalStore)
        XCTAssertTrue(alice.client.persistentSignalStore!.hasPersistedIdentity)

        // Server still lists 1 device (same device, new keys)
        let devices = try await alice.api.listDevices()
        XCTAssertEqual(devices.count, 1)
    }

    func testCanMessageNewUserAfterTakeover() async throws {
        // Alice takes over, then befriends a NEW user (clean session)
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.client.takeoverDevice()
        await rateLimitDelay()

        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice befriends Bob AFTER takeover — Bob fetches Alice's new keys
        try await alice.connectWebSocket()
        await rateLimitDelay()

        try await alice.befriend(bob.userId!, username: bob.username)
        let req = try await bob.waitForMessage(timeout: 15) // FRIEND_REQUEST
        XCTAssertEqual(req.type, 2)

        try await bob.acceptFriend(alice.userId!, username: alice.username)
        _ = try await alice.waitForMessage(timeout: 15) // FRIEND_RESPONSE

        // Verify friendship established
        let aliceFriend = await alice.friends.getFriend(bob.userId!)
        XCTAssertEqual(aliceFriend?.status, .accepted)

        try await alice.send(to: bob.userId!, "Post-takeover message")
        let msg = try await bob.waitForMessage(timeout: 15)
        XCTAssertEqual(msg.text, "Post-takeover message")

        // Verify message persisted in both stores
        let aliceMsgs = await alice.messages.getMessages(bob.userId!)
        XCTAssertEqual(aliceMsgs.count, 1)
        XCTAssertTrue(aliceMsgs[0].isSent)
        let bobMsgs = await bob.messages.getMessages(alice.userId!)
        XCTAssertEqual(bobMsgs.count, 1)
        XCTAssertFalse(bobMsgs[0].isSent)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
