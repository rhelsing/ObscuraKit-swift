import XCTest
@testable import ObscuraKit

/// Friend state machine — verify every status transition in the DB, not just message delivery.
final class FriendStateMachineTests: XCTestCase {

    // MARK: - Sender sees pendingSent with username

    func testSenderStoresPendingSentWithUsername() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.befriend(bob.userId!, username: bob.username)
        await rateLimitDelay()

        let friend = await alice.friends.getFriend(bob.userId!)
        XCTAssertNotNil(friend, "Alice should have Bob in store")
        XCTAssertEqual(friend?.status, .pendingSent)
        XCTAssertEqual(friend?.username, bob.username, "Should store Bob's username, not empty string")
    }

    // MARK: - Receiver sees pendingReceived with sender's username

    func testReceiverStoresPendingReceivedWithUsername() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await bob.connectWebSocket()
        await rateLimitDelay()

        try await alice.befriend(bob.userId!, username: bob.username)
        _ = try await bob.waitForMessage(timeout: 10) // FRIEND_REQUEST

        let friend = await bob.friends.getFriend(alice.userId!)
        XCTAssertNotNil(friend)
        XCTAssertEqual(friend?.status, .pendingReceived)
        XCTAssertEqual(friend?.username, alice.username, "Should have Alice's username from the message, not empty")

        bob.disconnectWebSocket()
    }

    // MARK: - Accept updates both sides to accepted

    func testAcceptUpdatesBothSides() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        try await alice.befriend(bob.userId!, username: bob.username)
        _ = try await bob.waitForMessage(timeout: 10)

        try await bob.acceptFriend(alice.userId!, username: alice.username)
        _ = try await alice.waitForMessage(timeout: 10)

        // Both sides should be accepted
        let aliceFriend = await alice.friends.getFriend(bob.userId!)
        let bobFriend = await bob.friends.getFriend(alice.userId!)
        XCTAssertEqual(aliceFriend?.status, .accepted)
        XCTAssertEqual(bobFriend?.status, .accepted)

        // getAccepted should return exactly 1 on each side
        let aliceAccepted = await alice.friends.getAccepted()
        let bobAccepted = await bob.friends.getAccepted()
        XCTAssertEqual(aliceAccepted.count, 1)
        XCTAssertEqual(bobAccepted.count, 1)

        // getPending should be empty on both sides
        let alicePending = await alice.friends.getPending()
        let bobPending = await bob.friends.getPending()
        XCTAssertEqual(alicePending.count, 0)
        XCTAssertEqual(bobPending.count, 0)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Double befriend is idempotent

    func testDoubleBefriendIsIdempotent() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.befriend(bob.userId!, username: bob.username)
        await rateLimitDelay()
        try await alice.befriend(bob.userId!, username: bob.username)
        await rateLimitDelay()

        // Should still be exactly 1 entry, not 2
        let all = await alice.friends.getAll()
        let bobEntries = all.filter { $0.userId == bob.userId! }
        XCTAssertEqual(bobEntries.count, 1, "Double befriend should not create duplicates")
    }

    // MARK: - Friend request while offline arrives on connect

    func testFriendRequestArrivesAfterConnect() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Alice sends while Bob is NOT connected
        try await alice.befriend(bob.userId!, username: bob.username)
        await rateLimitDelay()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Bob connects — server should flush queued FRIEND_REQUEST
        try await bob.connectWebSocket()
        let msg = try await bob.waitForMessage(timeout: 15)
        XCTAssertEqual(msg.type, 2, "Should be FRIEND_REQUEST")

        // Bob's store should have the friend entry
        let friend = await bob.friends.getFriend(alice.userId!)
        XCTAssertNotNil(friend)
        XCTAssertEqual(friend?.status, .pendingReceived)

        bob.disconnectWebSocket()
    }
}
