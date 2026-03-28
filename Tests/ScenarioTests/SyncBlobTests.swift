import XCTest
@testable import ObscuraKit

/// SYNC_BLOB transfer — existing device sends state to new device
/// Tests export/import of friends and messages, and delivery via encrypted message.
final class SyncBlobTests: XCTestCase {

    // MARK: - Export and import round-trip

    func testSyncBlobExportImport() async throws {
        // Set up state on device 1
        let friendActor = try FriendActor()
        let messageActor = try MessageActor()

        await friendActor.add("alice-id", "alice", status: .accepted)
        await friendActor.add("carol-id", "carol", status: .pendingReceived)

        await messageActor.add("alice", Message(messageId: "m1", conversationId: "alice", content: "hello alice", isSent: true))
        await messageActor.add("alice", Message(messageId: "m2", conversationId: "alice", content: "hi back", isSent: false))

        // Export
        let friends = await friendActor.getAll()
        let aliceMessages = await messageActor.getMessages("alice")
        let exportData = SyncBlobExporter.export(
            friends: friends,
            messages: [("alice", aliceMessages)]
        )
        XCTAssertFalse(exportData.isEmpty)

        // Parse on receiving side
        let parsed = SyncBlobExporter.parseExport(exportData)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.friends.count, 2)
        XCTAssertEqual(parsed!.messages.count, 2)

        // Verify friend data
        let friendNames = parsed!.friends.compactMap { $0["username"] as? String }.sorted()
        XCTAssertEqual(friendNames, ["alice", "carol"])

        // Verify message data
        let messageContents = parsed!.messages.compactMap { $0["content"] as? String }.sorted()
        XCTAssertEqual(messageContents, ["hello alice", "hi back"])
    }

    // MARK: - Import into fresh stores

    func testSyncBlobImportIntoFreshStores() async throws {
        // Export from device 1
        let exportData = SyncBlobExporter.export(
            friends: [
                Friend(userId: "bob-id", username: "bob", status: .accepted),
            ],
            messages: [
                ("bob", [Message(messageId: "m1", conversationId: "bob", content: "synced msg", isSent: true)])
            ]
        )

        // Import into device 2 (fresh stores)
        let device2Friends = try FriendActor()
        let device2Messages = try MessageActor()

        let parsed = SyncBlobExporter.parseExport(exportData)!

        // Import friends
        for f in parsed.friends {
            let status = FriendStatus(rawValue: f["status"] as? String ?? "") ?? .pendingSent
            await device2Friends.add(
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
            await device2Messages.add(m["conversationId"] as! String, msg)
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
        await alice.friends.add(bob.userId!, bob.username, status: .accepted)
        await alice.messages.add(bob.username, Message(messageId: "m1", conversationId: bob.username, content: "test sync"))

        // Export state
        let friends = await alice.friends.getAll()
        let msgs = await alice.messages.getMessages(bob.username)
        let exportData = SyncBlobExporter.export(friends: friends, messages: [(bob.username, msgs)])

        // Bob connects to receive
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends SYNC_BLOB to Bob (via encrypted message)
        guard let messenger = alice.messenger else { throw ObscuraClient.ObscuraError.noMessenger }
        let bundles = try await messenger.fetchPreKeyBundles(bob.userId!)
        await rateLimitDelay()

        if let bundle = bundles.first {
            try await messenger.processServerBundle(bundle, userId: bob.userId!)
        }

        var msg = Obscura_V2_ClientMessage()
        msg.type = .syncBlob
        var blob = Obscura_V2_SyncBlob()
        blob.compressedData = exportData
        msg.syncBlob = blob
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let targetDeviceId = bundles.first?["deviceId"] as? String ?? bob.userId!
        try await messenger.queueMessage(
            targetDeviceId: targetDeviceId,
            clientMessageData: try msg.serializedData(),
            targetUserId: bob.userId!
        )
        _ = try await messenger.flushMessages()
        await rateLimitDelay()

        // Bob receives SYNC_BLOB
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 23, "Should be SYNC_BLOB (23)")
        XCTAssertEqual(received.sourceUserId, alice.userId!)

        bob.disconnectWebSocket()
    }
}
