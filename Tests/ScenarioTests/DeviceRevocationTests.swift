import XCTest
@testable import ObscuraKit

/// Scenario 7: Device Revocation
/// Three-way messaging → revoke device → messages purged → device bricked
final class DeviceRevocationTests: XCTestCase {

    // MARK: - 7.1: Three-way message exchange

    func testScenario7_1_ThreeWayMessages() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()

        // Set up friendship
        await alice.friends.add(bob.userId!, bob.username, status: .accepted)
        await bob.friends.add(alice.userId!, alice.username, status: .accepted)

        // Bob has 2 devices (bob1 implicit, bob2 added)
        await bob.devices.addOwnDevice(OwnDevice(deviceUUID: "bob2-uuid", deviceId: "bob2-dev", deviceName: "iPad"))

        // Alice sends to Bob
        await alice.messages.add(bob.username, Message(messageId: "m1", conversationId: bob.username, content: "hi bob", isSent: true))

        // Bob1 sends to Alice
        await bob.messages.add(alice.username, Message(messageId: "m2", conversationId: alice.username, content: "hi alice", isSent: true, authorDeviceId: "bob1-dev"))

        // Bob2 sends to Alice
        await bob.messages.add(alice.username, Message(messageId: "m3", conversationId: alice.username, content: "hi from ipad", isSent: true, authorDeviceId: "bob2-dev"))

        // Alice receives both from Bob
        await alice.messages.add(bob.username, Message(messageId: "m2", conversationId: bob.username, content: "hi alice", authorDeviceId: "bob1-dev"))
        await alice.messages.add(bob.username, Message(messageId: "m3", conversationId: bob.username, content: "hi from ipad", authorDeviceId: "bob2-dev"))

        let aliceMessages = await alice.messages.getMessages(bob.username)
        XCTAssertEqual(aliceMessages.count, 3, "Alice has 3 messages (1 sent + 2 received)")
    }

    // MARK: - 7.4: Revoked device messages purged

    func testScenario7_4_RevokedDeviceMessagesPurged() async throws {
        let alice = try await ObscuraTestClient.register()

        // Alice has messages from bob1 and bob2
        await alice.messages.add("bob", Message(messageId: "m1", conversationId: "bob", content: "from bob1", authorDeviceId: "bob1-dev"))
        await alice.messages.add("bob", Message(messageId: "m2", conversationId: "bob", content: "from bob2", authorDeviceId: "bob2-dev"))
        await alice.messages.add("bob", Message(messageId: "m3", conversationId: "bob", content: "from bob1 again", authorDeviceId: "bob1-dev"))

        // Bob2 gets revoked — delete all messages from that device
        let deleted = await alice.messages.deleteByAuthorDevice("bob2-dev")
        XCTAssertEqual(deleted, 1, "1 message from bob2 deleted")

        let remaining = await alice.messages.getMessages("bob")
        XCTAssertEqual(remaining.count, 2, "Only bob1 messages remain")
        XCTAssertTrue(remaining.allSatisfy { $0.authorDeviceId == "bob1-dev" })
    }

    // MARK: - 7.5: Device self-bricks (data wiped)

    func testScenario7_5_DeviceSelfBricks() async throws {
        let bob2 = try await ObscuraTestClient.register()

        // Bob2 has some state
        await bob2.friends.add("alice-id", "alice", status: .accepted)
        await bob2.messages.add("alice", Message(messageId: "m1", conversationId: "alice", content: "hello"))
        await bob2.devices.storeIdentity(DeviceIdentity(coreUsername: bob2.username, deviceId: "bob2-dev", deviceUUID: "bob2-uuid"))

        // Verify state exists
        let friendsBefore = await bob2.friends.getAll()
        XCTAssertEqual(friendsBefore.count, 1)
        let hasIdentity = await bob2.devices.hasIdentity()
        XCTAssertTrue(hasIdentity)

        // Self-brick: wipe everything
        await bob2.devices.clearAll()
        await bob2.messages.clearAll()

        // Verify wiped
        let hasIdentityAfter = await bob2.devices.hasIdentity()
        XCTAssertFalse(hasIdentityAfter, "Identity wiped")
        let messagesAfter = await bob2.messages.getMessages("alice")
        XCTAssertEqual(messagesAfter.count, 0, "Messages wiped")
    }
}
