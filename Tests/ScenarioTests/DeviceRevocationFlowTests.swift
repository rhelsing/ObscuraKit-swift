import XCTest
import LibSignalClient
@testable import ObscuraKit

/// Device revocation via recovery key — broadcast DeviceAnnounce, purge messages, self-brick
final class DeviceRevocationFlowTests: XCTestCase {

    // MARK: - DeviceAnnounce broadcast to friend

    func testDeviceAnnounceDelivery() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Alice connects to receive
        try await alice.connectWebSocket()
        await rateLimitDelay()

        // Bob sends DEVICE_ANNOUNCE to Alice (simulating device list change)
        guard let messenger = bob.messenger else { throw ObscuraClient.ObscuraError.noMessenger }
        let bundles = try await messenger.fetchPreKeyBundles(alice.userId!)
        await rateLimitDelay()

        if let bundle = bundles.first {
            try await messenger.processServerBundle(bundle, userId: alice.userId!)
        }

        var announce = Obscura_V2_DeviceAnnounce()
        var deviceInfo = Obscura_V2_DeviceInfo()
        deviceInfo.deviceID = bob.deviceId ?? ""
        deviceInfo.deviceName = "Bob's Phone"
        announce.devices = [deviceInfo]
        announce.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        announce.isRevocation = false

        var msg = Obscura_V2_ClientMessage()
        msg.type = .deviceAnnounce
        msg.deviceAnnounce = announce
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let targetDeviceId = bundles.first?["deviceId"] as? String ?? alice.userId!
        try await messenger.queueMessage(
            targetDeviceId: targetDeviceId,
            clientMessageData: try msg.serializedData(),
            targetUserId: alice.userId!
        )
        _ = try await messenger.flushMessages()
        await rateLimitDelay()

        // Alice receives DEVICE_ANNOUNCE
        let received = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 12, "Should be DEVICE_ANNOUNCE (12)")
        XCTAssertEqual(received.sourceUserId, bob.userId!)

        alice.disconnectWebSocket()
    }

    // MARK: - Revocation announce with is_revocation flag

    func testRevocationAnnounceDelivery() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        await rateLimitDelay()

        guard let messenger = bob.messenger else { throw ObscuraClient.ObscuraError.noMessenger }
        let bundles = try await messenger.fetchPreKeyBundles(alice.userId!)
        await rateLimitDelay()

        if let bundle = bundles.first {
            try await messenger.processServerBundle(bundle, userId: alice.userId!)
        }

        // Bob sends revocation announce (device removed)
        var announce = Obscura_V2_DeviceAnnounce()
        announce.devices = [] // empty — all devices revoked
        announce.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        announce.isRevocation = true
        announce.signature = Data(repeating: 0xAA, count: 64) // signed with recovery key

        var msg = Obscura_V2_ClientMessage()
        msg.type = .deviceAnnounce
        msg.deviceAnnounce = announce
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let targetDeviceId = bundles.first?["deviceId"] as? String ?? alice.userId!
        try await messenger.queueMessage(
            targetDeviceId: targetDeviceId,
            clientMessageData: try msg.serializedData(),
            targetUserId: alice.userId!
        )
        _ = try await messenger.flushMessages()
        await rateLimitDelay()

        let received = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 12, "Should be DEVICE_ANNOUNCE")

        alice.disconnectWebSocket()
    }

    // MARK: - Friend processes revocation (purges messages + updates devices)

    func testFriendProcessesRevocation() async throws {
        // Alice has messages from bob's two devices
        let alice = try await ObscuraTestClient.register()

        await alice.friends.add("bob-id", "bob", status: .accepted, devices: [
            ["deviceId": "bob-dev1", "deviceUUID": "uuid1"],
            ["deviceId": "bob-dev2", "deviceUUID": "uuid2"],
        ])

        await alice.messages.add("bob", Message(messageId: "m1", conversationId: "bob", content: "from dev1", authorDeviceId: "bob-dev1"))
        await alice.messages.add("bob", Message(messageId: "m2", conversationId: "bob", content: "from dev2", authorDeviceId: "bob-dev2"))
        await alice.messages.add("bob", Message(messageId: "m3", conversationId: "bob", content: "from dev1 again", authorDeviceId: "bob-dev1"))

        // Process revocation: bob-dev2 is revoked
        // 1. Delete messages from revoked device
        let deleted = await alice.messages.deleteByAuthorDevice("bob-dev2")
        XCTAssertEqual(deleted, 1)

        // 2. Update device list (remove revoked device)
        await alice.friends.updateDevices("bob-id", devices: [
            ["deviceId": "bob-dev1", "deviceUUID": "uuid1"],
        ])

        // Verify
        let remaining = await alice.messages.getMessages("bob")
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.allSatisfy { $0.authorDeviceId == "bob-dev1" })

        let friend = await alice.friends.getFriend("bob-id")
        XCTAssertEqual(friend?.devices.count, 1)
    }

    // MARK: - Revoked device self-bricks

    func testRevokedDeviceSelfBricks() async throws {
        let bob2 = try await ObscuraTestClient.register()

        // bob2 has state
        await bob2.friends.add("alice-id", "alice", status: .accepted)
        await bob2.messages.add("alice", Message(messageId: "m1", conversationId: "alice", content: "hello"))
        await bob2.devices.storeIdentity(DeviceIdentity(coreUsername: bob2.username, deviceId: "bob2-dev", deviceUUID: "bob2-uuid"))

        // Receive revocation → self-brick
        await bob2.devices.clearAll()
        await bob2.messages.clearAll()

        // All state wiped
        let hasIdentity = await bob2.devices.hasIdentity()
        XCTAssertFalse(hasIdentity)
        let msgs = await bob2.messages.getMessages("alice")
        XCTAssertEqual(msgs.count, 0)
        // Friends store is intentionally NOT wiped (per web client behavior)
        let friends = await bob2.friends.getAll()
        XCTAssertEqual(friends.count, 1, "Friends survive logout/brick")
    }
}
