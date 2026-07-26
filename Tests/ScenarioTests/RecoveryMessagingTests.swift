import XCTest
@testable import ObscuraKit

/// Matches Kotlin's RecoveryMessagingTests.kt
/// Recovery messaging: announce recovery to friends, resume messaging.
///
/// ## What this file does NOT cover
///
/// **There is no receive handler for `DEVICE_RECOVERY_ANNOUNCE`, in either kit.** `routeMessage`'s
/// `default: break` swallows it and the envelope is then acked, so a recovery announcement changes
/// nothing at all on the recipient: not the friend graph, not the device list, not the stored
/// recovery key.
///
/// These tests assert only that the **wire message is delivered** — they would pass unchanged if the
/// handler were deleted, which is to say they pass because it never existed. Do not read a green run
/// here as "recovery works". Naming the first test for delivery rather than for the feature is
/// deliberate: `obscura-proto/PLAN.md`'s F-findings are largely about green ticks over behaviour
/// nobody implemented, and this was one of them.
///
/// The gap is a **deliberate deferral, not a bug** (`obscura-proto/KIT_API.md` §4.2): the sender is
/// gated behind `enableRecoveryPhrase`, which defaults to `false` and which obscura-pix never sets,
/// so nothing in the running app can emit this message. When the handler is built, extend the first
/// test to assert the recipient's device list actually changed — and verify the signature against
/// the **stored** recovery key, never the `recovery_public_key` carried inside the message it
/// authenticates.
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
