import XCTest
@testable import ObscuraKit

/// SYNC_BLOB transfer — existing device sends state to new device
/// Tests export/import of friends and messages, and delivery via encrypted message.
///
/// This kit exports the friend graph only. Import remains tolerant of messages
/// in a peer kit's blob.
final class SyncBlobTests: XCTestCase {

    // MARK: - Export and import round-trip

    func testSyncBlobExportImport() async throws {
        // Set up state on device 1
        let friendActor = try FriendActor()

        try await friendActor.add("alice-id", "alice", status: .accepted)
        try await friendActor.add("carol-id", "carol", status: .pendingReceived)

        // Export
        let friends = await friendActor.getAll()
        let exportData = SyncBlobExporter.export(friends: friends)
        XCTAssertFalse(exportData.isEmpty)

        // Parse on receiving side
        let parsed = SyncBlobExporter.parseExport(exportData)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.friends.count, 2)
        XCTAssertTrue(parsed!.messages.isEmpty,
                      "this kit's export carries the friend graph only; the key is still present so "
                      + "a peer kit's blob parses the same way")

        // Verify friend data
        let friendNames = parsed!.friends.compactMap { $0["username"] as? String }.sorted()
        XCTAssertEqual(friendNames, ["alice", "carol"])
    }

    // MARK: - Import into fresh stores

    /// The import half, against a blob shaped the way a PEER kit writes one — friends and messages.
    /// Built by hand because this kit's exporter does not emit messages, and asserting the import
    /// path against an exporter that cannot produce the input would prove nothing about what arrives
    /// off the wire.
    func testSyncBlobImportIntoFreshStores() async throws {
        // Explicitly typed: a `[String: Any]` literal with mixed value types cannot be inferred.
        let peerFriend: [String: Any] = [
            "userId": "bob-id", "username": "bob", "status": FriendStatus.accepted.rawValue,
        ]
        let peerMessage: [String: Any] = [
            "messageId": "m1", "conversationId": "bob", "content": "synced msg",
            "timestamp": 1_700_000_000_000, "isSent": true,
        ]
        let blob: [String: Any] = ["friends": [peerFriend], "messages": [peerMessage]]
        let exportData = try JSONSerialization.data(withJSONObject: blob)

        // Import into device 2 (fresh stores)
        let device2Friends = try FriendActor()
        let device2Messages = try MessageActor()

        let parsed = SyncBlobExporter.parseExport(exportData)!

        // Import friends
        for f in parsed.friends {
            let status = FriendStatus(rawValue: f["status"] as? String ?? "") ?? .pendingSent
            try await device2Friends.add(
                f["userId"] as! String,
                f["username"] as! String,
                status: status
            )
        }

        // Import messages
        for m in parsed.messages {
            let msg = Message(
                messageId: m["messageId"] as! String,
                conversationId: m["conversationId"] as! String,
                content: m["content"] as! String,
                isSent: m["isSent"] as? Bool ?? false
            )
            try await device2Messages.add(m["conversationId"] as! String, msg)
        }

        // Verify
        let friends = await device2Friends.getAccepted()
        XCTAssertEqual(friends.count, 1)
        XCTAssertEqual(friends[0].username, "bob")

        let messages = await device2Messages.getMessages("bob")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "synced msg")
    }

    // MARK: - SYNC_BLOB delivery via server

    func testSyncBlobDeliveryViaServer() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Alice has some state to sync
        try await alice.friends.add(bob.userId!, bob.username, status: .accepted)
        try await alice.messages.add(bob.username, Message(messageId: "m1", conversationId: bob.username, content: "test sync"))

        // Export state
        let friends = await alice.friends.getAll()
        let exportData = SyncBlobExporter.export(friends: friends)

        // Bob connects to receive
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends SYNC_BLOB to Bob (via encrypted message)

        var msg = Obscura_Client_V1_ClientMessage()
        var blob = Obscura_Client_V1_SyncBlob()
        blob.compressedData = exportData
        msg.syncBlob = blob
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await alice.sendRaw(to: bob.userId!, try msg.serializedData())
        await rateLimitDelay()

        // Bob receives SYNC_BLOB
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, "SYNC_BLOB", "Should be SYNC_BLOB (23)")
        XCTAssertEqual(received.sourceUserId, alice.userId!)

        bob.disconnectWebSocket()
    }
}
