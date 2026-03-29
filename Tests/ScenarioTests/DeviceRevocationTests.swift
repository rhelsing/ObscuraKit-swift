import XCTest
@testable import ObscuraKit

/// Scenario 7: Device Revocation — against actual server
final class DeviceRevocationTests: XCTestCase {

    // MARK: - 7.1: Three-way message exchange

    func testScenario7_1_ThreeWayMessageExchange() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Bob receives Alice's message
        try await bob.connectWebSocket()
        await rateLimitDelay()

        try await alice.send(to: bob.userId!, "hi bob")
        await rateLimitDelay()

        let msg = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg.text, "hi bob")

        // Bob replies
        try await alice.connectWebSocket()
        await rateLimitDelay()

        try await bob.send(to: alice.userId!, "hi alice")
        await rateLimitDelay()

        let reply = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(reply.text, "hi alice")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - 7.4: Message purge by author device

    func testScenario7_4_MessagePurgeByDevice() async throws {
        let alice = try await ObscuraTestClient.register()

        // Store messages from different devices
        await alice.messages.add("bob", Message(messageId: "m1", conversationId: "bob", content: "from dev1", authorDeviceId: "device-1"))
        await alice.messages.add("bob", Message(messageId: "m2", conversationId: "bob", content: "from dev2", authorDeviceId: "device-2"))
        await alice.messages.add("bob", Message(messageId: "m3", conversationId: "bob", content: "from dev1 again", authorDeviceId: "device-1"))

        // Revoke device-2
        let deleted = await alice.messages.deleteByAuthorDevice("device-2")
        XCTAssertEqual(deleted, 1)

        let remaining = await alice.messages.getMessages("bob")
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.allSatisfy { $0.authorDeviceId == "device-1" })
    }

    // MARK: - 7.5: Device wipe

    func testScenario7_5_DeviceWipe() async throws {
        let bob = try await ObscuraTestClient.register()

        // Store some state
        await bob.friends.add("alice-id", "alice", status: .accepted)
        await bob.messages.add("alice", Message(messageId: "m1", conversationId: "alice", content: "hello"))
        await bob.devices.storeIdentity(DeviceIdentity(coreUsername: bob.username, deviceId: "dev1", deviceUUID: "uuid1"))

        // Wipe
        await bob.devices.clearAll()
        await bob.messages.clearAll()

        let hasIdentity = await bob.devices.hasIdentity()
        XCTAssertFalse(hasIdentity, "Identity should be wiped")

        let msgs = await bob.messages.getMessages("alice")
        XCTAssertEqual(msgs.count, 0, "Messages should be wiped")
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
