import XCTest
@testable import ObscuraKit

/// Recovery messaging: announce recovery to friends, resume messaging.
///
/// ## What this file does NOT cover
///
/// **There is no receive handler for `DEVICE_RECOVERY_ANNOUNCE`, in either kit.** `routeMessage`'s
/// `default: break` swallows it and the envelope is then acked, so a recovery announcement changes
/// nothing at all on the recipient: not the friend graph, not the device list, not the stored
/// recovery key.
///
/// These tests assert wire delivery only; they do not prove recovery works.
/// `announceRecovery` is a live public sender, although obscura-pix exposes no
/// recovery UI. Any receive handler must verify against the stored recovery
/// key, never the key carried inside the signed message.
final class RecoveryMessagingTests: XCTestCase {

    /// DELIVERY ONLY — see the type doc. Asserts the announcement reaches Bob's device, not that Bob
    /// does anything with it. Nothing does: there is no `DEVICE_RECOVERY_ANNOUNCE` handler.
    func testDeviceRecoveryAnnounceIsDeliveredToBobNoHandlerConsumesIt() async throws {
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
        // DEVICE_RECOVERY_ANNOUNCE = type 13. This is the wire arriving at Bob's device — it is NOT
        // evidence Bob acted on it, because no handler exists to act on it.
        XCTAssertEqual(msg.type, "DEVICE_RECOVERY_ANNOUNCE",
                       "Bob's device should receive the announcement off the wire")

        let clientMsg = try Obscura_Client_V1_ClientMessage(serializedBytes: msg.rawBytes)
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
