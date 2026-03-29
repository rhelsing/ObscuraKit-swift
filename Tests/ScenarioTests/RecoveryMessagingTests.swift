import XCTest
@testable import ObscuraKit

/// Matches Kotlin's RecoveryMessagingTests.kt
/// Recovery messaging: announce recovery to friends, resume messaging.
final class RecoveryMessagingTests: XCTestCase {

    func testAliceAnnouncesRecoveryBobReceives() async throws {
        let alice = try await ObscuraTestClient.register()
        let recoveryPhrase = alice.client.generateRecoveryPhrase()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Establish friendship
        try await alice.befriend(bob.userId!)
        _ = try await bob.waitForMessage(timeout: 10) // FRIEND_REQUEST
        try await bob.acceptFriend(alice.userId!)
        _ = try await alice.waitForMessage(timeout: 10) // FRIEND_RESPONSE

        // Alice announces recovery
        try await alice.client.announceRecovery(recoveryPhrase)
        await rateLimitDelay()

        let msg = try await bob.waitForMessage(timeout: 10)
        // DEVICE_RECOVERY_ANNOUNCE = type 13
        XCTAssertEqual(msg.type, 13, "Should be DEVICE_RECOVERY_ANNOUNCE")

        let clientMsg = try Obscura_V2_ClientMessage(serializedBytes: msg.rawBytes)
        XCTAssertTrue(clientMsg.deviceRecoveryAnnounce.isFullRecovery)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    func testMessagingContinuesAfterRecoveryAnnouncement() async throws {
        let alice = try await ObscuraTestClient.register()
        let recoveryPhrase = alice.client.generateRecoveryPhrase()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Establish friendship
        try await alice.befriend(bob.userId!)
        _ = try await bob.waitForMessage(timeout: 10)
        try await bob.acceptFriend(alice.userId!)
        _ = try await alice.waitForMessage(timeout: 10)

        // Announce recovery
        try await alice.client.announceRecovery(recoveryPhrase)
        _ = try await bob.waitForMessage(timeout: 10) // drain recovery announce

        // Messaging should still work
        try await alice.send(to: bob.userId!, "I recovered my account!")
        let msg = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg.text, "I recovered my account!")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
