import XCTest
@testable import ObscuraKit

/// Matches Kotlin's SessionResetTests.kt
/// Session reset sends SESSION_RESET, bulk reset completes without error.
final class SessionResetTests: XCTestCase {

    func testSessionResetSendsToFriend() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Establish friendship (creates Signal sessions)
        try await alice.befriend(bob.userId!)
        _ = try await bob.waitForMessage(timeout: 10)
        try await bob.acceptFriend(alice.userId!)
        _ = try await alice.waitForMessage(timeout: 10)

        // Alice resets session with Bob
        try await alice.client.resetSessionWith(bob.userId!, reason: "test reset")
        await rateLimitDelay()

        let msg = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg.type, 4, "Should be SESSION_RESET (4)")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    func testResetAllSessionsCompletesWithoutError() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Establish friendship
        try await alice.befriend(bob.userId!)
        _ = try await bob.waitForMessage(timeout: 10)
        try await bob.acceptFriend(alice.userId!)

        try await alice.connectWebSocket()
        _ = try await alice.waitForMessage(timeout: 10)

        // Should not throw — resets sessions for all friends
        try await alice.client.resetAllSessions(reason: "test bulk reset")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
