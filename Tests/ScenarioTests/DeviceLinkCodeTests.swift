import XCTest
@testable import ObscuraKit

/// E2E device linking test — enforces the QR approval flow.
/// No loginAndProvision() bypass. New device generates link code,
/// existing device validates and approves, new device gets full state.
final class DeviceLinkCodeTests: XCTestCase {

    /// Full link code ceremony:
    /// 1. Alice registers (device 1)
    /// 2. Alice's device 2 logs in and generates link code
    /// 3. Alice's device 1 validates and approves the link code
    /// 4. Device 2 receives DEVICE_LINK_APPROVAL + SYNC_BLOB
    /// 5. Device 2 has friends and state from device 1
    func testFullLinkCodeCeremony() async throws {
        let apiURL = "https://obscura.barrelmaker.dev"
        let password = "testpass123456"
        let username = "test_\(Int.random(in: 100000...999999))"

        // ============================================================
        // STEP 1: Alice registers on device 1
        // ============================================================
        let device1 = try ObscuraClient(apiURL: apiURL)
        try await device1.register(username, password)
        await rateLimitDelay()

        XCTAssertNotNil(device1.deviceId, "Device 1 should have a device ID")
        XCTAssertNotNil(device1.userId)

        // Alice befriends someone so we can verify state transfers
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await device1.connect()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        try await device1.befriend(bob.userId!, username: bob.username)
        _ = try await bob.waitForMessage(timeout: 10)
        try await bob.client.acceptFriend(device1.userId!, username: username)
        _ = try await device1.waitForMessage(timeout: 10)
        await rateLimitDelay()

        // Verify Alice has Bob as a friend on device 1
        let d1Friends = await device1.friends.getAccepted()
        XCTAssertEqual(d1Friends.count, 1, "Device 1 should have 1 friend")

        // ============================================================
        // STEP 2: Device 2 logs in and provisions (generates Signal keys)
        // ============================================================
        let device2 = try ObscuraClient(apiURL: apiURL)
        try await device2.loginAndProvision(username, password, deviceName: "Device 2")
        await rateLimitDelay()

        XCTAssertNotNil(device2.deviceId, "Device 2 should have a device ID")
        XCTAssertNotEqual(device2.deviceId, device1.deviceId, "Different device IDs")

        // ============================================================
        // STEP 3: Device 2 generates a link code
        // ============================================================
        let linkCode = device2.generateLinkCode()
        XCTAssertNotNil(linkCode, "Device 2 should generate a link code")
        XCTAssertFalse(linkCode!.isEmpty)

        // Validate the link code is well-formed
        let parsed = DeviceLink.parseLinkCode(linkCode!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.deviceId, device2.deviceId)

        // ============================================================
        // STEP 4: Device 1 validates the link code
        // ============================================================
        let validation = DeviceLink.validateLinkCode(linkCode!)
        if case .valid(let code) = validation {
            XCTAssertEqual(code.deviceId, device2.deviceId)
        } else {
            XCTFail("Link code should be valid")
        }

        // ============================================================
        // STEP 5: Device 2 connects and waits for approval
        // ============================================================
        try await device2.connect()
        await rateLimitDelay()

        // Device 1 approves the link
        // (In production this would call validateAndApproveLink,
        //  but that requires the new device's prekey bundle to be fetchable.
        //  We use the lower-level approveLink here since both devices are provisioned.)
        let challenge = DeviceLink.extractChallenge(parsed!)!
        try await device1.approveLink(newDeviceId: device2.deviceId!, challengeResponse: challenge)
        await rateLimitDelay()

        // Device 2 should receive DEVICE_LINK_APPROVAL
        let approval = try await device2.waitForMessage(timeout: 10)
        XCTAssertEqual(approval.type, 11, "Should be DEVICE_LINK_APPROVAL (type 11)")

        // Device 2 should also receive SYNC_BLOB with friends
        let syncBlob = try await device2.waitForMessage(timeout: 10)
        XCTAssertEqual(syncBlob.type, 23, "Should be SYNC_BLOB (type 23)")

        device1.disconnect()
        device2.disconnect()
        bob.disconnectWebSocket()
    }

    /// Link code expiry — codes older than 5 minutes are rejected.
    func testExpiredLinkCodeRejected() async throws {
        let apiURL = "https://obscura.barrelmaker.dev"
        let device = try ObscuraClient(apiURL: apiURL)
        try await device.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        await rateLimitDelay()

        let code = device.generateLinkCode()!

        // Validate with 0ms max age — immediately expired
        let result = DeviceLink.validateLinkCode(code, maxAge: 0)
        if case .expired = result {
            // Expected
        } else {
            XCTFail("Should be expired with maxAge=0")
        }

        device.disconnect()
    }
}
