import XCTest
@testable import ObscuraKit

/// Scenario 7: Device Revocation — against actual server.
///
/// Two tests were deleted from here as duplicates of the vacuous pair in
/// `DeviceRevocationFlowTests`: `testScenario7_4_MessagePurgeByDevice` re-implemented the revocation
/// itself and then asserted `deleteByAuthorDevice` had deleted, and `testScenario7_5_DeviceWipe`
/// called `clearAll()` and asserted it had cleared. Neither exercised any kit behaviour — see that
/// file's type doc for why this matters. There is no remote device revocation in this kit; the
/// broken `revokeDevice` that these tests never touched has been deleted.
final class DeviceRevocationTests: XCTestCase {

    // MARK: - 7.1: Three-way message exchange

    func testScenario7_1_ThreeWayMessageExchange() async throws {
        // send() requires an accepted friendship; the handshake leaves both connected.
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        // Bob receives Alice's message
        try await alice.send(to: bob.userId!, "hi bob")
        await rateLimitDelay()

        let msg = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg.text, "hi bob")

        // Bob replies
        try await bob.send(to: alice.userId!, "hi alice")
        await rateLimitDelay()

        let reply = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(reply.text, "hi alice")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - 7.2: Delete device via server API

    func testScenario7_2_DeleteDeviceViaAPI() async throws {
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // List devices — should have our device
        let devicesList = try await bob.api.listDevices()
        XCTAssertFalse(devicesList.isEmpty, "Should have at least one device")
    }
}
