import XCTest
import Foundation
@testable import ObscuraKit

final class ServerProtoTests: XCTestCase {

    func testWebSocketFrameRoundTrip() throws {
        // Build an EnvelopeBatch with one envelope
        var envelope = Obscura_V1_Envelope()
        envelope.id = Data(repeating: 0xAA, count: 16)
        envelope.senderID = Data(repeating: 0xBB, count: 16)
        envelope.timestamp = 1700000000000
        envelope.message = Data("encrypted-payload".utf8)

        var batch = Obscura_V1_EnvelopeBatch()
        batch.envelopes = [envelope]

        var frame = Obscura_V1_WebSocketFrame()
        frame.envelopeBatch = batch

        // Serialize
        let data = try frame.serializedData()
        XCTAssertFalse(data.isEmpty, "Serialized frame should not be empty")

        // Deserialize
        let decoded = try Obscura_V1_WebSocketFrame(serializedData: data)

        // Assert
        XCTAssertEqual(decoded.envelopeBatch.envelopes.count, 1)
        let e = decoded.envelopeBatch.envelopes[0]
        XCTAssertEqual(e.id, Data(repeating: 0xAA, count: 16))
        XCTAssertEqual(e.senderID, Data(repeating: 0xBB, count: 16))
        XCTAssertEqual(e.timestamp, 1700000000000)
        XCTAssertEqual(String(data: e.message, encoding: .utf8), "encrypted-payload")
    }

    func testEnvelopeByteLayout() throws {
        var envelope = Obscura_V1_Envelope()
        envelope.id = Data(repeating: 0x01, count: 16)
        envelope.senderID = Data(repeating: 0x02, count: 16)
        envelope.timestamp = 12345
        envelope.message = Data([0xFF, 0xFE, 0xFD])

        let data = try envelope.serializedData()
        let decoded = try Obscura_V1_Envelope(serializedData: data)

        XCTAssertEqual(decoded.id.count, 16)
        XCTAssertEqual(decoded.senderID.count, 16)
        XCTAssertEqual(decoded.timestamp, 12345)
        XCTAssertEqual(decoded.message, Data([0xFF, 0xFE, 0xFD]))
    }

    func testSendMessageRequestBatch() throws {
        var sub1 = Obscura_V1_SendMessageRequest.Submission()
        sub1.submissionID = Data(repeating: 0x01, count: 16)
        sub1.deviceID = Data(repeating: 0x02, count: 16)
        sub1.message = Data("msg1".utf8)

        var sub2 = Obscura_V1_SendMessageRequest.Submission()
        sub2.submissionID = Data(repeating: 0x03, count: 16)
        sub2.deviceID = Data(repeating: 0x04, count: 16)
        sub2.message = Data("msg2".utf8)

        var request = Obscura_V1_SendMessageRequest()
        request.messages = [sub1, sub2]

        let data = try request.serializedData()
        let decoded = try Obscura_V1_SendMessageRequest(serializedData: data)

        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(String(data: decoded.messages[0].message, encoding: .utf8), "msg1")
        XCTAssertEqual(String(data: decoded.messages[1].message, encoding: .utf8), "msg2")
    }

    func testAckMessageRoundTrip() throws {
        var ack = Obscura_V1_AckMessage()
        let id1 = Data(repeating: 0xAA, count: 16)
        let id2 = Data(repeating: 0xBB, count: 16)
        ack.messageIds = [id1, id2]

        // Wrap in frame
        var frame = Obscura_V1_WebSocketFrame()
        frame.ack = ack

        let data = try frame.serializedData()
        let decoded = try Obscura_V1_WebSocketFrame(serializedData: data)

        XCTAssertEqual(decoded.ack.messageIds.count, 2)
        XCTAssertEqual(decoded.ack.messageIds[0], id1)
        XCTAssertEqual(decoded.ack.messageIds[1], id2)
    }

    func testPreKeyStatusRoundTrip() throws {
        var status = Obscura_V1_PreKeyStatus()
        status.oneTimePreKeyCount = 47
        status.minThreshold = 10

        var frame = Obscura_V1_WebSocketFrame()
        frame.preKeyStatus = status

        let data = try frame.serializedData()
        let decoded = try Obscura_V1_WebSocketFrame(serializedData: data)

        XCTAssertEqual(decoded.preKeyStatus.oneTimePreKeyCount, 47)
        XCTAssertEqual(decoded.preKeyStatus.minThreshold, 10)
    }

    func testSendMessageResponseWithFailures() throws {
        var failed = Obscura_V1_SendMessageResponse.FailedSubmission()
        failed.submissionID = Data(repeating: 0x01, count: 16)
        failed.errorCode = .invalidDevice
        failed.errorMessage = "Device not found"

        var response = Obscura_V1_SendMessageResponse()
        response.failedSubmissions = [failed]

        let data = try response.serializedData()
        let decoded = try Obscura_V1_SendMessageResponse(serializedData: data)

        XCTAssertEqual(decoded.failedSubmissions.count, 1)
        XCTAssertEqual(decoded.failedSubmissions[0].errorCode, .invalidDevice)
        XCTAssertEqual(decoded.failedSubmissions[0].errorMessage, "Device not found")
    }
}
