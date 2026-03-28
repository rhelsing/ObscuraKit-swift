import XCTest
import Foundation
@testable import ObscuraKit

final class ClientProtoTests: XCTestCase {

    // MARK: - EncryptedMessage

    func testEncryptedMessageRoundTrip() throws {
        var msg = Obscura_V2_EncryptedMessage()
        msg.type = .prekeyMessage
        msg.content = Data("signal-ciphertext".utf8)

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_EncryptedMessage(serializedData: data)

        XCTAssertEqual(decoded.type, .prekeyMessage)
        XCTAssertEqual(String(data: decoded.content, encoding: .utf8), "signal-ciphertext")
    }

    // MARK: - ClientMessage TEXT

    func testClientMessageText() throws {
        var msg = Obscura_V2_ClientMessage()
        msg.type = .text
        msg.timestamp = 1700000000000
        msg.text = "hello from swift"

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_ClientMessage(serializedData: data)

        XCTAssertEqual(decoded.type, .text)
        XCTAssertEqual(decoded.text, "hello from swift")
        XCTAssertEqual(decoded.timestamp, 1700000000000)
    }

    func testClientMessageWrappedInEncryptedMessage() throws {
        // This is the actual wire format: ClientMessage -> serialize -> encrypt -> EncryptedMessage.content
        var clientMsg = Obscura_V2_ClientMessage()
        clientMsg.type = .text
        clientMsg.timestamp = 1700000000000
        clientMsg.text = "wrapped message"

        let clientBytes = try clientMsg.serializedData()

        var encrypted = Obscura_V2_EncryptedMessage()
        encrypted.type = .encryptedMessage
        encrypted.content = clientBytes

        let wireBytes = try encrypted.serializedData()
        let decodedEncrypted = try Obscura_V2_EncryptedMessage(serializedData: wireBytes)
        let decodedClient = try Obscura_V2_ClientMessage(serializedData: decodedEncrypted.content)

        XCTAssertEqual(decodedClient.type, .text)
        XCTAssertEqual(decodedClient.text, "wrapped message")
    }

    // MARK: - Friend Request / Response

    func testFriendRequest() throws {
        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendRequest
        msg.timestamp = 1700000000000
        msg.username = "alice"

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_ClientMessage(serializedData: data)

        XCTAssertEqual(decoded.type, .friendRequest)
        XCTAssertEqual(decoded.username, "alice")
    }

    func testFriendResponse() throws {
        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendResponse
        msg.timestamp = 1700000000000
        msg.username = "bob"
        msg.accepted = true

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_ClientMessage(serializedData: data)

        XCTAssertEqual(decoded.type, .friendResponse)
        XCTAssertEqual(decoded.username, "bob")
        XCTAssertTrue(decoded.accepted)
    }

    // MARK: - DeviceInfo

    func testDeviceInfo() throws {
        var device = Obscura_V2_DeviceInfo()
        device.deviceUuid = "550e8400-e29b-41d4-a716-446655440000"
        device.deviceID = "device-123"
        device.deviceName = "iPhone"
        device.signalIdentityKey = Data(repeating: 0x05, count: 1) + Data(repeating: 0xAA, count: 32)

        let data = try device.serializedData()
        let decoded = try Obscura_V2_DeviceInfo(serializedData: data)

        XCTAssertEqual(decoded.deviceUuid, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(decoded.deviceName, "iPhone")
        XCTAssertEqual(decoded.signalIdentityKey.count, 33)
        XCTAssertEqual(decoded.signalIdentityKey[0], 0x05)
    }

    // MARK: - ModelSync (ORM layer)

    func testModelSyncCreate() throws {
        var sync = Obscura_V2_ModelSync()
        sync.model = "story"
        sync.id = "story_1706389200_abc123"
        sync.op = .create
        sync.timestamp = 1706389200000
        sync.data = Data("{\"content\":\"hello world\"}".utf8)
        sync.authorDeviceID = "device-1"

        let data = try sync.serializedData()
        let decoded = try Obscura_V2_ModelSync(serializedData: data)

        XCTAssertEqual(decoded.model, "story")
        XCTAssertEqual(decoded.id, "story_1706389200_abc123")
        XCTAssertEqual(decoded.op, .create)
        XCTAssertEqual(decoded.authorDeviceID, "device-1")

        let jsonStr = String(data: decoded.data, encoding: .utf8)!
        XCTAssertTrue(jsonStr.contains("hello world"))
    }

    func testModelSyncUpdate() throws {
        var sync = Obscura_V2_ModelSync()
        sync.model = "streak"
        sync.id = "streak_001"
        sync.op = .update
        sync.timestamp = 1706389300000
        sync.data = Data("{\"count\":5}".utf8)

        let data = try sync.serializedData()
        let decoded = try Obscura_V2_ModelSync(serializedData: data)

        XCTAssertEqual(decoded.op, .update)
        XCTAssertEqual(decoded.model, "streak")
    }

    func testModelSyncDelete() throws {
        var sync = Obscura_V2_ModelSync()
        sync.model = "story"
        sync.id = "story_old"
        sync.op = .delete
        sync.timestamp = 1706389400000

        let data = try sync.serializedData()
        let decoded = try Obscura_V2_ModelSync(serializedData: data)

        XCTAssertEqual(decoded.op, .delete)
    }

    // MARK: - ClientMessage with ModelSync payload

    func testClientMessageWithModelSync() throws {
        var sync = Obscura_V2_ModelSync()
        sync.model = "story"
        sync.id = "story_123"
        sync.op = .create
        sync.timestamp = 1706389200000
        sync.data = Data("{\"content\":\"test\"}".utf8)

        var msg = Obscura_V2_ClientMessage()
        msg.type = .modelSync
        msg.timestamp = 1706389200000
        msg.modelSync = sync

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_ClientMessage(serializedData: data)

        XCTAssertEqual(decoded.type, .modelSync)
        XCTAssertEqual(decoded.modelSync.model, "story")
        XCTAssertEqual(decoded.modelSync.op, .create)
    }

    // MARK: - ContentReference

    func testContentReference() throws {
        var ref = Obscura_V2_ContentReference()
        ref.attachmentID = "att-001"
        ref.contentKey = Data(repeating: 0xCC, count: 32)
        ref.nonce = Data(repeating: 0xDD, count: 12)
        ref.contentHash = Data(repeating: 0xEE, count: 32)
        ref.contentType = "image/jpeg"
        ref.sizeBytes = 1024000
        ref.fileName = "photo.jpg"

        var msg = Obscura_V2_ClientMessage()
        msg.type = .contentReference
        msg.contentReference = ref

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_ClientMessage(serializedData: data)

        XCTAssertEqual(decoded.contentReference.attachmentID, "att-001")
        XCTAssertEqual(decoded.contentReference.contentKey.count, 32)
        XCTAssertEqual(decoded.contentReference.nonce.count, 12)
        XCTAssertEqual(decoded.contentReference.contentType, "image/jpeg")
        XCTAssertEqual(decoded.contentReference.sizeBytes, 1024000)
    }

    // MARK: - SyncBlob + SentSync

    func testSyncBlob() throws {
        var blob = Obscura_V2_SyncBlob()
        blob.compressedData = Data("fake-gzipped-json".utf8)

        var msg = Obscura_V2_ClientMessage()
        msg.type = .syncBlob
        msg.syncBlob = blob

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_ClientMessage(serializedData: data)

        XCTAssertEqual(decoded.type, .syncBlob)
        XCTAssertEqual(String(data: decoded.syncBlob.compressedData, encoding: .utf8), "fake-gzipped-json")
    }

    func testSentSync() throws {
        var sync = Obscura_V2_SentSync()
        sync.conversationID = "bob"
        sync.messageID = "msg-001"
        sync.timestamp = 1700000000000
        sync.content = Data("hello bob".utf8)

        var msg = Obscura_V2_ClientMessage()
        msg.type = .sentSync
        msg.sentSync = sync

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_ClientMessage(serializedData: data)

        XCTAssertEqual(decoded.sentSync.conversationID, "bob")
        XCTAssertEqual(decoded.sentSync.messageID, "msg-001")
    }

    // MARK: - FriendSync

    func testFriendSync() throws {
        var device = Obscura_V2_DeviceInfo()
        device.deviceID = "dev-1"
        device.deviceName = "Phone"

        var sync = Obscura_V2_FriendSync()
        sync.username = "carol"
        sync.action = "add"
        sync.status = "accepted"
        sync.devices = [device]
        sync.timestamp = 1700000000000

        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendSync
        msg.friendSync = sync

        let data = try msg.serializedData()
        let decoded = try Obscura_V2_ClientMessage(serializedData: data)

        XCTAssertEqual(decoded.friendSync.username, "carol")
        XCTAssertEqual(decoded.friendSync.action, "add")
        XCTAssertEqual(decoded.friendSync.devices.count, 1)
    }
}
