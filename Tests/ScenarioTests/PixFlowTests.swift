import XCTest
@testable import ObscuraKit

/// Scenario 9: Pix Flow — against actual server
/// Temporary photo messaging with CONTENT_REFERENCE delivery
final class PixFlowTests: XCTestCase {

    // MARK: - 9.1: Send pix to recipient

    func testScenario9_1_SendPixToRecipient() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Upload "photo" (fake JPEG)
        var jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpegData.append(Data(repeating: 0x42, count: 2000))

        let uploadResult = try await alice.api.uploadAttachment(jpegData)
        let attachmentId = uploadResult.id
        await rateLimitDelay()

        // Bob connects
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends CONTENT_REFERENCE (pix) to Bob

        var msg = Obscura_V2_ClientMessage()
        msg.type = .contentReference
        var ref = Obscura_V2_ContentReference()
        ref.attachmentID = attachmentId
        ref.contentKey = Data(repeating: 0xAA, count: 32)
        ref.nonce = Data(repeating: 0xBB, count: 12)
        ref.contentType = "image/jpeg"
        ref.sizeBytes = UInt64(jpegData.count)
        msg.contentReference = ref
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await alice.sendRaw(to: bob.userId!, try msg.serializedData())
        await rateLimitDelay()

        // Bob receives
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 25, "Should be CONTENT_REFERENCE")
        XCTAssertEqual(received.sourceUserId, alice.userId!)

        bob.disconnectWebSocket()
    }

    // MARK: - 9.3: Download and verify JPEG

    func testScenario9_3_DownloadAndVerifyJPEG() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Upload JPEG
        var jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpegData.append(Data(repeating: 0x55, count: 500))

        let uploadResult = try await alice.api.uploadAttachment(jpegData)
        let attachmentId = uploadResult.id
        await rateLimitDelay()

        // Download
        let downloaded = try await alice.api.fetchAttachment(attachmentId)

        // Verify JPEG header
        XCTAssertEqual(downloaded[0], 0xFF, "JPEG SOI marker byte 1")
        XCTAssertEqual(downloaded[1], 0xD8, "JPEG SOI marker byte 2")
        XCTAssertEqual(downloaded.count, jpegData.count, "Size should match")
        XCTAssertEqual(downloaded, jpegData, "Content should match exactly")
    }
}
