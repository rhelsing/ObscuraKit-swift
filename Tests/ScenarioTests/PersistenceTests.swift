import XCTest
@testable import ObscuraKit

/// Persistence tests — prove the data layer survives "app restart".
/// Each test creates a file-backed client, destroys it, creates a new client
/// from the same directory, and verifies state survived.
/// All tests run against the live server.
final class PersistenceTests: XCTestCase {

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "obscura_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Scenario A: Cold start — receive messages queued while "dead"

    func testColdStartReceivesQueuedMessages() async throws {
        let dir = tempDir()
        defer { cleanup(dir) }

        let apiURL = "https://obscura.barrelmaker.dev"
        let password = "testpass123456"

        // 1. Register Alice (in-memory, she's the sender)
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // 2. Register Bob with file-backed client
        let bobUsername = "test_\(Int.random(in: 100000...999999))"
        let bob1 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await bob1.register(bobUsername, password)
        let bobUserId = bob1.userId!
        let bobDeviceId = bob1.deviceId!
        let bobToken = bob1.token!
        let bobRefreshToken = bob1.refreshToken
        await rateLimitDelay()

        // 3. Both connect, complete full friend handshake
        try await alice.connectWebSocket()
        try await bob1.connect()
        await rateLimitDelay()

        try await alice.client.befriend(bobUserId, username: bobUsername)
        _ = try await bob1.waitForMessage(timeout: 10) // FRIEND_REQUEST
        try await bob1.acceptFriend(alice.userId!, username: alice.username)
        await rateLimitDelay()
        _ = try await alice.waitForMessage(timeout: 10) // FRIEND_RESPONSE

        // Verify friendship
        let aliceFriend = await alice.friends.getFriend(bobUserId)
        XCTAssertEqual(aliceFriend?.status, .accepted)

        // Now send a message to prove sessions work
        try await alice.send(to: bobUserId, "before restart")
        let msg1 = try await bob1.waitForMessage(timeout: 10)
        XCTAssertEqual(msg1.text, "before restart", "Should receive while connected")

        // 4. Bob disconnects (simulates app kill)
        bob1.disconnect()

        // 5. Alice sends while Bob is "dead"
        try await alice.send(to: bobUserId, "while you were dead")
        await rateLimitDelay()
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s for server to queue

        // 6. Simulate cold restart — new ObscuraClient from same directory
        let bob2 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)

        // Signal store should have been restored from DB
        XCTAssertNotNil(bob2.persistentSignalStore, "Signal store should be restored from disk")
        XCTAssertTrue(bob2.persistentSignalStore!.hasPersistedIdentity, "Identity should survive restart")

        // Restore session credentials (in production, from Keychain)
        await bob2.restoreSession(
            token: bobToken, refreshToken: bobRefreshToken,
            userId: bobUserId, deviceId: bobDeviceId,
            username: bobUsername
        )

        XCTAssertTrue(bob2.hasSession, "Should have session after restore")

        // 7. Bob reconnects — server should flush queued message
        // First ensure token is fresh
        await bob2.ensureFreshToken()
        try await bob2.connect()
        let msg2 = try await bob2.waitForMessage(timeout: 15)
        XCTAssertEqual(msg2.text, "while you were dead", "Should receive message queued while offline")

        bob2.disconnect()
        alice.disconnectWebSocket()
    }

    // MARK: - Scenario B: Friends survive restart

    func testFriendsSurviveRestart() async throws {
        let dir = tempDir()
        defer { cleanup(dir) }

        let apiURL = "https://obscura.barrelmaker.dev"

        // Register with file-backed client
        let client1 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await client1.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        await rateLimitDelay()

        // Add a friend locally
        await client1.friends.add("fake-user-id", "fakefriend", status: .accepted)

        let friends1 = await client1.friends.getAccepted()
        XCTAssertEqual(friends1.count, 1)

        // "Restart" — new client, same directory
        let client2 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        let friends2 = await client2.friends.getAccepted()
        XCTAssertEqual(friends2.count, 1, "Friends should survive restart")
        XCTAssertEqual(friends2.first?.username, "fakefriend")
    }

    // MARK: - Scenario C: Messages survive restart

    func testMessagesSurviveRestart() async throws {
        let dir = tempDir()
        defer { cleanup(dir) }

        let apiURL = "https://obscura.barrelmaker.dev"

        let client1 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await client1.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        await rateLimitDelay()

        // Store a message
        await client1.messages.add("conv-123", Message(
            messageId: "msg-1", conversationId: "conv-123",
            content: "persisted message", isSent: true
        ))

        // "Restart"
        let client2 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        let msgs = await client2.messages.getMessages("conv-123")
        XCTAssertEqual(msgs.count, 1, "Messages should survive restart")
        XCTAssertEqual(msgs.first?.content, "persisted message")
    }

    // MARK: - Scenario D: Signal identity survives restart

    func testSignalIdentitySurvivesRestart() async throws {
        let dir = tempDir()
        defer { cleanup(dir) }

        let apiURL = "https://obscura.barrelmaker.dev"

        let client1 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await client1.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        let originalRegId = client1.registrationId
        let originalIdentityKey = client1.identityKeyPair?.publicKey.serialize()
        await rateLimitDelay()

        // "Restart"
        let client2 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        XCTAssertNotNil(client2.persistentSignalStore)
        XCTAssertTrue(client2.persistentSignalStore!.hasPersistedIdentity)
        XCTAssertEqual(client2.registrationId, originalRegId, "Registration ID should survive restart")
        XCTAssertEqual(
            client2.identityKeyPair?.publicKey.serialize(),
            originalIdentityKey,
            "Identity key should survive restart"
        )
    }

    // MARK: - Scenario E: Logout preserves data

    func testLogoutPreservesData() async throws {
        let dir = tempDir()
        defer { cleanup(dir) }

        let apiURL = "https://obscura.barrelmaker.dev"

        let client1 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await client1.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        await rateLimitDelay()

        await client1.friends.add("friend-1", "alice", status: .accepted)
        await client1.messages.add("conv-1", Message(messageId: "m1", conversationId: "conv-1", content: "test"))

        // Logout — should NOT wipe data
        try await client1.logout()

        // "Restart"
        let client2 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        let friends = await client2.friends.getAccepted()
        let msgs = await client2.messages.getMessages("conv-1")
        XCTAssertEqual(friends.count, 1, "Friends should survive logout")
        XCTAssertEqual(msgs.count, 1, "Messages should survive logout")
        XCTAssertTrue(client2.persistentSignalStore?.hasPersistedIdentity ?? false, "Signal identity should survive logout")
    }

    // MARK: - Scenario E2: wipeDevice nukes everything

    func testWipeDeviceClearsPersistedState() async throws {
        let dir = tempDir()
        defer { cleanup(dir) }

        let apiURL = "https://obscura.barrelmaker.dev"

        let client1 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await client1.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        await rateLimitDelay()

        await client1.friends.add("friend-1", "alice", status: .accepted)
        await client1.messages.add("conv-1", Message(messageId: "m1", conversationId: "conv-1", content: "test"))

        // Wipe — should nuke everything
        try await client1.wipeDevice()

        // "Restart"
        let client2 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        let friends = await client2.friends.getAccepted()
        let msgs = await client2.messages.getMessages("conv-1")
        XCTAssertEqual(friends.count, 0, "Friends should be wiped")
        XCTAssertEqual(msgs.count, 0, "Messages should be wiped")
        XCTAssertFalse(client2.persistentSignalStore?.hasPersistedIdentity ?? false, "Signal identity should be wiped")
    }

    // MARK: - Scenario F: Friend request arrives while offline, visible after restart

    func testFriendRequestArrivesAfterRestart() async throws {
        let dir = tempDir()
        defer { cleanup(dir) }

        let apiURL = "https://obscura.barrelmaker.dev"
        let password = "testpass123456"

        // Alice (in-memory sender)
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Bob (file-backed)
        let bobUsername = "test_\(Int.random(in: 100000...999999))"
        let bob1 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await bob1.register(bobUsername, password)
        let bobUserId = bob1.userId!
        let bobDeviceId = bob1.deviceId!
        let bobToken = bob1.token!
        let bobRefreshToken = bob1.refreshToken
        await rateLimitDelay()

        // Bob goes offline immediately (never connected)
        // Alice sends friend request
        try await alice.befriend(bobUserId, username: bobUsername)
        await rateLimitDelay()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Bob "restarts" and connects
        let bob2 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        await bob2.restoreSession(
            token: bobToken, refreshToken: bobRefreshToken,
            userId: bobUserId, deviceId: bobDeviceId,
            username: bobUsername
        )
        await bob2.ensureFreshToken()
        try await bob2.connect()

        // Should receive the queued friend request
        let msg = try await bob2.waitForMessage(timeout: 15)
        XCTAssertEqual(msg.type, 2, "Should receive FRIEND_REQUEST (2)")
        XCTAssertEqual(msg.sourceUserId, alice.userId!)

        // Check it was routed to the friends store
        let pending = await bob2.friends.getPending()
        XCTAssertEqual(pending.count, 1, "Should have 1 pending friend request")

        bob2.disconnect()
    }
}
