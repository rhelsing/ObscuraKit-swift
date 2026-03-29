import XCTest
@testable import ObscuraKit

/// Scenario 10: Story Attachments — against actual server
/// Create story with image via ORM ModelSync, deliver to friend
final class StoryAttachmentTests: XCTestCase {

    // MARK: - 10.1: Image-only story via ORM

    func testScenario10_1_ImageStoryCreation() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let id = "story_\(UInt64(Date().timeIntervalSince1970 * 1000))_img"
        let entry = ModelEntry(
            id: id,
            data: [
                "mediaRef": "att_12345",
                "contentType": "image/jpeg",
            ],
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            signature: Data(),
            authorDeviceId: "dev1"
        )

        let result = await gset.add(entry)
        XCTAssertEqual(result.data["mediaRef"] as? String, "att_12345")
        XCTAssertEqual(result.data["contentType"] as? String, "image/jpeg")
        // No text content — image only
        XCTAssertNil(result.data["content"])
    }

    // MARK: - 10.2: Story syncs to friend via ModelSync

    func testScenario10_2_StorySyncToFriend() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Upload image
        var imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        imageData.append(Data(repeating: 0x99, count: 1000))
        let uploadResult = try await alice.api.uploadAttachment(imageData)
        let attachmentId = uploadResult.id
        await rateLimitDelay()

        // Bob connects
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends ModelSync + ContentReference for story

        // Build MODEL_SYNC with story data
        var sync = Obscura_V2_ModelSync()
        sync.model = "story"
        sync.id = "story_\(UInt64(Date().timeIntervalSince1970 * 1000))_media"
        sync.op = .create
        sync.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        sync.data = Data("{\"mediaRef\":\"\(attachmentId)\",\"contentType\":\"image/jpeg\"}".utf8)
        sync.authorDeviceID = alice.deviceId ?? "unknown"

        var msg = Obscura_V2_ClientMessage()
        msg.type = .modelSync
        msg.modelSync = sync
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await alice.sendRaw(to: bob.userId!, try msg.serializedData())
        await rateLimitDelay()

        // Bob receives MODEL_SYNC
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 30, "Should be MODEL_SYNC")
        XCTAssertEqual(received.sourceUserId, alice.userId!)

        bob.disconnectWebSocket()
    }

    // MARK: - 10.3: Receiver can download attachment

    func testScenario10_3_ReceiverDownloadsAttachment() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Alice uploads
        var imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        imageData.append(Data(repeating: 0x77, count: 800))
        let uploadResult = try await alice.api.uploadAttachment(imageData)
        let attachmentId = uploadResult.id
        await rateLimitDelay()

        // Bob downloads (both users can access after auth)
        let downloaded = try await bob.api.fetchAttachment(attachmentId)
        XCTAssertEqual(downloaded, imageData, "Downloaded should match uploaded")
    }

    // MARK: - 10.5: Story with text + image

    func testScenario10_5_StoryWithTextAndImage() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let id = "story_\(UInt64(Date().timeIntervalSince1970 * 1000))_both"
        let entry = ModelEntry(
            id: id,
            data: [
                "content": "check out this sunset",
                "mediaRef": "att_67890",
                "contentType": "image/jpeg",
            ],
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            signature: Data(),
            authorDeviceId: "dev1"
        )

        let result = await gset.add(entry)
        XCTAssertEqual(result.data["content"] as? String, "check out this sunset")
        XCTAssertEqual(result.data["mediaRef"] as? String, "att_67890")
    }
}
