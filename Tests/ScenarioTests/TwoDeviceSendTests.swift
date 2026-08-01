import XCTest
@testable import ObscuraKit

/// Swift counterpart to Kotlin's `TwoDeviceSendTests.kt` — `obscura-proto/HISTORY.md` Phase 0, task 0.1.
///
/// **Why this file exists.** Phase 2 moved Signal session addressing from `registrationId` to the
/// **device UUID** in both kits (`SPEC.md` §0.10). Kotlin proved that with a two-device integration
/// test; Swift had no equivalent, so its half of Phase 2 rested on code inspection and a standalone
/// libsignal probe. This closes that gap: the same invariant, pinned by a test, on both kits.
///
/// **The trap this test is built to avoid** (the Phase 2 acceptance criterion, `git show bb9259c:PLAN.md` §0.1): a two-device test that
/// does **not** reconnect the sender after the multi-device friend lands in its store passes
/// vacuously. `MultiDeviceFanOutTests` is exactly that shape — it sends while the device map is
/// fresh from the prekey fetch, so a broken addressing scheme still delivers. The F1 failure only
/// bites *after* a sender reconnect rebuilds the device map from the friend store. The reconnect in
/// `testBothDevicesDecryptAfterSenderReconnect` is therefore the load-bearing step, not ceremony.
///
/// Pre-Phase-2 Swift would fail these: `decrypt` defaulted `senderRegId: 1` while outbound sessions
/// were filed at `(userId, realRegId)`, so inbound and outbound used different addresses.
final class TwoDeviceSendTests: XCTestCase {

    /// The server genuinely has two devices for Alice — if this fails, nothing below means anything.
    func testServerListsTwoDevicesForAlice() async throws {
        let alice1 = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let alice2 = try await ObscuraTestClient.loginAndProvision(alice1.username, deviceName: "Alice Laptop")
        await rateLimitDelay()

        XCTAssertNotEqual(alice1.deviceId, alice2.deviceId, "Alice's two devices must have distinct UUIDs")
        let devices = try await alice1.api.listDevices()
        XCTAssertEqual(devices.count, 2, "Alice should have 2 devices on the server")
    }

    /// F9 guard: `announceDevices()` broadcasts whatever the own-device registry holds, so an empty
    /// registry makes device propagation silently inert — which is precisely what masked F1 for
    /// months. Assert it rather than assume it.
    func testOwnDeviceRegistryIsPopulated() async throws {
        let alice1 = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let alice2 = try await ObscuraTestClient.loginAndProvision(alice1.username, deviceName: "Alice Laptop")
        await rateLimitDelay()

        let own1 = await alice1.devices.getOwnDevices()
        let own2 = await alice2.devices.getOwnDevices()
        print("  alice1.getOwnDevices()=\(own1.count) alice2.getOwnDevices()=\(own2.count)")
        own1.forEach { print("    own(device1 view): \($0.deviceId) \($0.deviceName)") }
        own2.forEach { print("    own(device2 view): \($0.deviceId) \($0.deviceName)") }

        XCTAssertFalse(own1.isEmpty,
            "F9 regression: device 1's own-device registry is empty, so announceDevices() would broadcast nothing")
        XCTAssertFalse(own2.isEmpty,
            "F9 regression: device 2's own-device registry is empty, so announceDevices() would broadcast nothing")
        XCTAssertTrue(own1.contains { $0.deviceId == alice1.deviceId },
            "Device 1 must record itself in the own-device registry (register path)")
        XCTAssertTrue(own2.contains { $0.deviceId == alice2.deviceId },
            "Device 2 must record itself in the own-device registry (loginAndProvision path)")
    }

    /// The link-approval half of F9: after a real `validateAndApproveLink`, the **approver's**
    /// registry must list both devices — that list is what `approveLink` ships and what
    /// `announceDevices()` later broadcasts, so if it holds one device a friend can only ever learn
    /// one of them.
    ///
    /// **Known divergence from ObscuraKit-Kotlin — the approvee side is NOT asserted here because it
    /// does not work.** Kotlin routes an inbound `DEVICE_LINK_APPROVAL` to `handleLinkApproval`,
    /// which calls `setOwnDevices(approvedDevices)` and stores the identity keys. Swift's
    /// `routeMessage` has **no `case .deviceLinkApproval`** — it falls through `default: break`, so a
    /// newly-linked Swift device silently discards the approval: no p2p keypair, no recovery key, no
    /// friends export, and an own-device registry containing only itself. Swift *sends* approvals it
    /// cannot *receive*. Recorded in `obscura-proto/HISTORY.md` and this repo's `CLAUDE.md`; asserting
    /// the broken behaviour here would only lock it in.
    func testLinkApprovalPopulatesTheApproverRegistry() async throws {
        let alice1 = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let alice2 = try await ObscuraTestClient.loginAndProvision(alice1.username, deviceName: "Alice Laptop")
        await rateLimitDelay()

        try await alice2.connectWebSocket()
        await rateLimitDelay()

        let code = try XCTUnwrap(alice2.client.generateLinkCode(),
            "the pending device must be able to generate a link code")
        try await alice1.client.validateAndApproveLink(code)
        await rateLimitDelay()

        let approver = await alice1.devices.getOwnDevices()
        print("  approver registry after validateAndApproveLink: \(approver.map { $0.deviceId })")
        XCTAssertEqual(approver.count, 2,
            "the approver must record BOTH devices — this list is what approveLink ships and what "
            + "announceDevices() broadcasts (F9/F6)")
        XCTAssertTrue(approver.contains { $0.deviceId == alice1.deviceId },
            "approver registry must contain the approving device")
        XCTAssertTrue(approver.contains { $0.deviceId == alice2.deviceId },
            "approver registry must contain the newly-approved device")

        alice2.disconnectWebSocket()
    }

    /// **The Phase 2 acceptance criterion** (`git show bb9259c:PLAN.md` §0.1). Alice has two devices; Bob befriends her,
    /// **reconnects**, then sends. Both of Alice's devices must receive AND decrypt.
    ///
    /// The reconnect is what makes this test worth having: it forces the sender to rebuild its device
    /// map from the friend store rather than from the prekey fetch, which is the state in which F1
    /// collapsed two devices onto a single `(userId, 1)` session and fanned one ciphertext to both.
    func testBothDevicesDecryptAfterSenderReconnect() async throws {
        let alice1 = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let alice2 = try await ObscuraTestClient.loginAndProvision(alice1.username, deviceName: "Alice Laptop")
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice1.connectWebSocket()
        try await alice2.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Friendship both ways. Bob's befriend() fetches Alice's prekey bundles, enumerating both
        // of her devices into his device map.
        try await bob.befriend(alice1.userId!, username: alice1.username)
        _ = try await alice1.waitForMessage(timeout: 15)   // FRIEND_REQUEST on device 1
        _ = try? await alice2.waitForMessage(timeout: 10)  // ...and on device 2 (fan-out)
        try await alice1.acceptFriend(bob.userId!, username: bob.username)
        _ = try await bob.waitForMessage(timeout: 15)      // FRIEND_RESPONSE

        // (a) Fresh send — device map straight from the prekey fetch. This is the state in which
        //     even a broken addressing scheme works, so a pass here proves little on its own.
        try await bob.send(to: alice1.userId!, "swift-2dev-a-fresh")
        let a1 = try await alice1.waitForMessage(timeout: 15)
        let a2 = try await alice2.waitForMessage(timeout: 15)
        XCTAssertEqual(a1.text, "swift-2dev-a-fresh", "Alice device 1 must decrypt the fresh send")
        XCTAssertEqual(a2.text, "swift-2dev-a-fresh", "Alice device 2 must decrypt the fresh send")

        // (b) THE LOAD-BEARING STEP: the sender reconnects, rebuilding its device map from the
        //     friend store, then sends again. Pre-Phase-2 this is where the second device stopped
        //     being able to decrypt.
        bob.disconnectWebSocket()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await bob.connectWebSocket()
        await rateLimitDelay()

        try await bob.send(to: alice1.userId!, "swift-2dev-b-reconnect")
        let b1 = try await alice1.waitForMessage(timeout: 15)
        let b2 = try await alice2.waitForMessage(timeout: 15)
        print("  RESULT after sender reconnect: device1='\(b1.text)' device2='\(b2.text)'")
        XCTAssertEqual(b1.text, "swift-2dev-b-reconnect",
            "Alice device 1 must decrypt after the sender reconnected")
        XCTAssertEqual(b2.text, "swift-2dev-b-reconnect",
            "Alice device 2 must decrypt after the sender reconnected — a failure here is F1: "
            + "both devices encrypted under one session address")

        // Both devices persisted it (the ack is only legitimate if this is true — SPEC §0.9).
        let stored1 = await alice1.messages.getMessages(bob.userId!)
        let stored2 = await alice2.messages.getMessages(bob.userId!)
        XCTAssertTrue(stored1.contains { $0.content == "swift-2dev-b-reconnect" },
            "Device 1 must have persisted the message it acked")
        XCTAssertTrue(stored2.contains { $0.content == "swift-2dev-b-reconnect" },
            "Device 2 must have persisted the message it acked")

        alice1.disconnectWebSocket()
        alice2.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
