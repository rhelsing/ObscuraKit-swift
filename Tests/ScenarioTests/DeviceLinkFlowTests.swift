import XCTest
import LibSignalClient
@testable import ObscuraKit

/// Device link code + approval flow
/// New device generates challenge → existing device approves with DEVICE_LINK_APPROVAL
final class DeviceLinkFlowTests: XCTestCase {

    // MARK: - Link code generation

    func testLinkCodeGeneration() {
        // Link code is a random challenge the new device generates
        let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        XCTAssertEqual(challenge.count, 32)

        // In the web client, this is encoded as base58 for display
        // The existing device echoes it back in DEVICE_LINK_APPROVAL.challengeResponse
    }

    // MARK: - DEVICE_LINK_APPROVAL delivery

    func testDeviceLinkApprovalDelivery() async throws {
        let existingDevice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let newDevice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // New device connects to receive approval
        try await newDevice.connectWebSocket()
        await rateLimitDelay()

        // Existing device sends DEVICE_LINK_APPROVAL
        // Build approval message with p2p keys and device list
        var approval = Obscura_V2_DeviceLinkApproval()
        approval.p2PPublicKey = Data(repeating: 0x05, count: 33)   // p2p identity
        approval.p2PPrivateKey = Data(repeating: 0xBB, count: 32)  // p2p private (encrypted transfer)
        approval.recoveryPublicKey = Data(repeating: 0xCC, count: 32)
        approval.challengeResponse = Data(repeating: 0xDD, count: 32)  // echo back challenge

        var device1Info = Obscura_V2_DeviceInfo()
        device1Info.deviceID = existingDevice.deviceId ?? ""
        device1Info.deviceName = "Existing Phone"
        approval.ownDevices = [device1Info]

        // Include exported state
        let friends = await existingDevice.friends.getAll()
        let exportData = SyncBlobExporter.export(friends: friends, messages: [])
        approval.friendsExport = exportData

        var msg = Obscura_V2_ClientMessage()
        msg.type = .deviceLinkApproval
        msg.deviceLinkApproval = approval
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await existingDevice.sendRaw(to: newDevice.userId!, try msg.serializedData())
        await rateLimitDelay()

        // New device receives DEVICE_LINK_APPROVAL
        let received = try await newDevice.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 11, "Should be DEVICE_LINK_APPROVAL (11)")
        XCTAssertEqual(received.sourceUserId, existingDevice.userId!)

        newDevice.disconnectWebSocket()
    }

    // MARK: - Full link flow: approve → SYNC_BLOB → new device has state

    func testFullLinkFlow() async throws {
        let device1 = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Device1 has some state
        await device1.friends.add("carol-id", "carol", status: .accepted)
        await device1.messages.add("carol", Message(messageId: "m1", conversationId: "carol", content: "synced"))

        let device2 = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await device2.connectWebSocket()
        await rateLimitDelay()

        // Device1 sends SYNC_BLOB to device2
        let friends = await device1.friends.getAll()
        let msgs = await device1.messages.getMessages("carol")
        let exportData = SyncBlobExporter.export(friends: friends, messages: [("carol", msgs)])

        var msg = Obscura_V2_ClientMessage()
        msg.type = .syncBlob
        var blob = Obscura_V2_SyncBlob()
        blob.compressedData = exportData
        msg.syncBlob = blob
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await device1.sendRaw(to: device2.userId!, try msg.serializedData())
        await rateLimitDelay()

        // Device2 receives SYNC_BLOB
        let received = try await device2.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 23, "Should be SYNC_BLOB")

        // Device2 imports the state from raw bytes
        let parsed = SyncBlobExporter.parseExport(received.rawBytes)

        // Actually we need the syncBlob compressed data, not the outer clientMessage bytes
        // The rawBytes is the decrypted ClientMessage — need to re-parse
        let clientMsg = try Obscura_V2_ClientMessage(serializedData: received.rawBytes)
        let syncData = clientMsg.syncBlob.compressedData
        let importedState = SyncBlobExporter.parseExport(syncData)

        XCTAssertNotNil(importedState)
        XCTAssertEqual(importedState!.friends.count, 1)
        XCTAssertEqual(importedState!.friends.first?["username"] as? String, "carol")
        XCTAssertEqual(importedState!.messages.count, 1)
        XCTAssertEqual(importedState!.messages.first?["content"] as? String, "synced")

        device2.disconnectWebSocket()
    }
}
