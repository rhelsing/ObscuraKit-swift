import XCTest
@testable import ObscuraKit

/// Matches Kotlin's MultiDeviceFanOutTests.kt
/// Multi-device fan-out: Bob has 2 devices, Alice sends, both receive.
final class MultiDeviceFanOutTests: XCTestCase {

    func testServerShowsTwoDevicesForBob() async throws {
        let bob1 = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob2 = try await ObscuraTestClient.loginAndProvision(bob1.username)
        await rateLimitDelay()

        let devices = try await bob1.api.listDevices()
        XCTAssertEqual(devices.count, 2, "Bob should have 2 devices")
    }

    func testAliceSendsToBobBothDevicesReceive() async throws {
        let bob1 = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob2 = try await ObscuraTestClient.loginAndProvision(bob1.username)
        await rateLimitDelay()
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Connect all three
        try await bob1.connectWebSocket()
        try await bob2.connectWebSocket()
        try await alice.connectWebSocket()
        await rateLimitDelay()

        // Befriend — both bob devices should get FRIEND_REQUEST
        try await alice.befriend(bob1.userId!)
        let req1 = try await bob1.waitForMessage(timeout: 10)
        XCTAssertEqual(req1.type, 2, "Bob1 should get FRIEND_REQUEST")
        let req2 = try await bob2.waitForMessage(timeout: 10)
        XCTAssertEqual(req2.type, 2, "Bob2 should get FRIEND_REQUEST")

        try await bob1.acceptFriend(alice.userId!)
        _ = try await alice.waitForMessage(timeout: 10) // FRIEND_RESPONSE

        // Alice sends text — both Bob devices should receive
        try await alice.send(to: bob1.userId!, "Hello both Bobs!")
        let msg1 = try await bob1.waitForMessage(timeout: 10)
        XCTAssertEqual(msg1.type, 0, "Bob1 should get TEXT")
        XCTAssertEqual(msg1.text, "Hello both Bobs!")

        let msg2 = try await bob2.waitForMessage(timeout: 10)
        XCTAssertEqual(msg2.type, 0, "Bob2 should get TEXT")
        XCTAssertEqual(msg2.text, "Hello both Bobs!")

        alice.disconnectWebSocket()
        bob1.disconnectWebSocket()
        bob2.disconnectWebSocket()
    }
}
