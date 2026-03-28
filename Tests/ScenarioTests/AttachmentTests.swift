import XCTest
@testable import ObscuraKit

/// Scenario 6: Attachments — against actual server
/// Upload, download, integrity check
final class AttachmentTests: XCTestCase {

    // MARK: - 6.1: Upload attachment

    func testScenario6_1_UploadAttachment() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Create a small JPEG-like blob (just header bytes for testing)
        var blob = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG magic bytes
        blob.append(Data(repeating: 0xAA, count: 1000))

        let result = try await alice.api.uploadAttachment(blob)
        let attachmentId = result["id"] as? String
        XCTAssertNotNil(attachmentId, "Server should return attachment ID")
    }

    // MARK: - 6.3: Download + integrity check

    func testScenario6_3_DownloadAndVerify() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Upload
        let originalData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let result = try await alice.api.uploadAttachment(originalData)
        let attachmentId = result["id"] as! String
        await rateLimitDelay()

        // Download
        let downloaded = try await alice.api.fetchAttachment(attachmentId)

        // Verify integrity
        XCTAssertEqual(downloaded, originalData, "Downloaded data should match uploaded")

        // Verify JPEG header
        XCTAssertEqual(downloaded[0], 0xFF)
        XCTAssertEqual(downloaded[1], 0xD8)
    }

    // MARK: - 6.2: Send CONTENT_REFERENCE to friend via server

    func testScenario6_2_ContentReferenceDelivery() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Upload attachment
        let blob = Data(repeating: 0xBB, count: 500)
        let uploadResult = try await alice.api.uploadAttachment(blob)
        let attachmentId = uploadResult["id"] as! String
        await rateLimitDelay()

        // Bob connects to receive
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends CONTENT_REFERENCE message
        guard let messenger = alice.messenger else { throw ObscuraClient.ObscuraError.noMessenger }
        let bundles = try await messenger.fetchPreKeyBundles(bob.userId!)
        await rateLimitDelay()

        if let bundle = bundles.first {
            try await messenger.processServerBundle(bundle, userId: bob.userId!)
        }

        var msg = Obscura_V2_ClientMessage()
        msg.type = .contentReference
        var ref = Obscura_V2_ContentReference()
        ref.attachmentID = attachmentId
        ref.contentKey = Data(repeating: 0xCC, count: 32) // Fake AES key
        ref.nonce = Data(repeating: 0xDD, count: 12)
        ref.contentType = "application/octet-stream"
        ref.sizeBytes = 500
        msg.contentReference = ref
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let targetDeviceId = bundles.first?["deviceId"] as? String ?? bob.userId!
        try await messenger.queueMessage(
            targetDeviceId: targetDeviceId,
            clientMessageData: try msg.serializedData(),
            targetUserId: bob.userId!
        )
        _ = try await messenger.flushMessages()
        await rateLimitDelay()

        // Bob receives
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 25, "Type should be CONTENT_REFERENCE (25)")
        XCTAssertEqual(received.sourceUserId, alice.userId!)

        bob.disconnectWebSocket()
    }
}
