import Foundation
import LibSignalClient
import SwiftProtobuf

/// Thin test wrapper around ObscuraClient.
/// Provides convenience methods for scenario tests.
/// Calls the same API that views would call.
public class ObscuraTestClient {
    public let client: ObscuraClient
    public let username: String
    public let password: String

    public var userId: String? { client.userId }
    public var deviceId: String? { client.deviceId }
    public var token: String? { client.token }

    // Convenience accessors
    public var friends: FriendActor { client.friends }
    public var messages: MessageActor { client.messages }
    public var devices: DeviceActor { client.devices }
    public var api: APIClient { client.api }
    public var messenger: MessengerActor? { client.messenger }
    public var gateway: GatewayConnection? { client.gateway }

    private init(client: ObscuraClient, username: String, password: String) {
        self.client = client
        self.username = username
        self.password = password
    }

    // MARK: - Registration

    /// Register a new test user with real Signal keys. Returns a ready-to-use test client.
    public static func register(
        _ username: String? = nil,
        _ password: String = "testpass123456",
        apiURL: String = "https://obscura.barrelmaker.dev"
    ) async throws -> ObscuraTestClient {
        let name = username ?? "test_\(Int.random(in: 100000...999999))"
        let client = try ObscuraClient(apiURL: apiURL)
        try await client.register(name, password)
        await rateLimitDelay()
        return ObscuraTestClient(client: client, username: name, password: password)
    }

    /// Login an existing user.
    public static func login(
        _ username: String,
        _ password: String = "testpass123456",
        deviceId: String? = nil,
        apiURL: String = "https://obscura.barrelmaker.dev"
    ) async throws -> ObscuraTestClient {
        let client = try ObscuraClient(apiURL: apiURL)
        try await client.login(username, password, deviceId: deviceId)
        await rateLimitDelay()
        return ObscuraTestClient(client: client, username: username, password: password)
    }

    // MARK: - WebSocket

    /// Connect to WebSocket gateway for receiving messages
    public func connectWebSocket() async throws {
        guard let gateway = gateway else { throw ObscuraClient.ObscuraError.noMessenger }
        try await gateway.connect()
    }

    /// Disconnect WebSocket
    public func disconnectWebSocket() {
        gateway?.disconnect()
    }

    // MARK: - Friend Requests

    /// Send a friend request to a target user via encrypted Signal message
    public func sendFriendRequest(to targetUserId: String) async throws {
        guard let messenger = messenger else { throw ObscuraClient.ObscuraError.noMessenger }

        // Fetch target's prekey bundles and establish session
        let bundles = try await messenger.fetchPreKeyBundles(targetUserId)
        await rateLimitDelay()

        guard let bundle = bundles.first else {
            throw TestClientError.noBundles(targetUserId)
        }

        try await messenger.processServerBundle(bundle, userId: targetUserId)

        // Build friend request message
        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendRequest
        msg.username = username
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        // Queue and send
        let targetDeviceId = bundle["deviceId"] as? String ?? targetUserId
        try await messenger.queueMessage(targetDeviceId: targetDeviceId, clientMessageData: try msg.serializedData(), targetUserId: targetUserId)
        _ = try await messenger.flushMessages()
    }

    /// Send a friend response (accept/decline)
    public func sendFriendResponse(to targetUserId: String, accepted: Bool) async throws {
        guard let messenger = messenger else { throw ObscuraClient.ObscuraError.noMessenger }

        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendResponse
        msg.username = username
        msg.accepted = accepted
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        // Need to find the target's device - use stored mapping from prior interaction
        let bundles = try await messenger.fetchPreKeyBundles(targetUserId)
        await rateLimitDelay()

        if let bundle = bundles.first {
            // Process bundle if no session exists
            try? await messenger.processServerBundle(bundle, userId: targetUserId)
            let targetDeviceId = bundle["deviceId"] as? String ?? targetUserId
            try await messenger.queueMessage(targetDeviceId: targetDeviceId, clientMessageData: try msg.serializedData(), targetUserId: targetUserId)
        }

        _ = try await messenger.flushMessages()
    }

    // MARK: - Text Messages

    /// Send a text message to a friend, with optional SENT_SYNC to own devices
    public func sendText(to targetUserId: String, _ text: String, sentSync: Bool = false) async throws {
        guard let messenger = messenger else { throw ObscuraClient.ObscuraError.noMessenger }

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let messageId = "msg_\(UUID().uuidString)"

        var msg = Obscura_V2_ClientMessage()
        msg.type = .text
        msg.text = text
        msg.timestamp = timestamp

        // Fetch bundles to ensure we have session + device mapping
        let bundles = try await messenger.fetchPreKeyBundles(targetUserId)
        await rateLimitDelay()

        // Determine conversation ID (friend username from bundles context)
        for bundle in bundles {
            try? await messenger.processServerBundle(bundle, userId: targetUserId)
            let targetDeviceId = bundle["deviceId"] as? String ?? targetUserId
            try await messenger.queueMessage(targetDeviceId: targetDeviceId, clientMessageData: try msg.serializedData(), targetUserId: targetUserId)
        }

        // SENT_SYNC: notify own devices of the sent message
        if sentSync {
            let ownDevices = await devices.getOwnDevices()
            if !ownDevices.isEmpty {
                var syncMsg = Obscura_V2_ClientMessage()
                syncMsg.type = .sentSync
                var sentSyncPayload = Obscura_V2_SentSync()
                sentSyncPayload.conversationID = targetUserId
                sentSyncPayload.messageID = messageId
                sentSyncPayload.timestamp = timestamp
                sentSyncPayload.content = Data(text.utf8)
                syncMsg.sentSync = sentSyncPayload
                syncMsg.timestamp = timestamp

                for device in ownDevices {
                    // Don't send to self
                    guard device.deviceId != self.deviceId else { continue }
                    // Need session with own device
                    let selfBundles = try await messenger.fetchPreKeyBundles(self.userId!)
                    await rateLimitDelay()
                    for bundle in selfBundles {
                        let bundleDeviceId = bundle["deviceId"] as? String ?? ""
                        if bundleDeviceId == device.deviceId {
                            try? await messenger.processServerBundle(bundle, userId: self.userId!)
                            try await messenger.queueMessage(
                                targetDeviceId: device.deviceId,
                                clientMessageData: try syncMsg.serializedData(),
                                targetUserId: self.userId!
                            )
                        }
                    }
                }
            }
        }

        _ = try await messenger.flushMessages()
    }

    // MARK: - Receiving Messages

    /// Wait for a message via WebSocket, decrypt it, return the ClientMessage
    /// Received message from WebSocket
    public struct ReceivedMessage {
        public let sourceUserId: String
        public let type: Int  // ClientMessage.Type raw value
        public let text: String
        public let username: String
        public let accepted: Bool
        public let timestamp: UInt64
        public let rawBytes: Data
    }

    public func waitForMessage(timeout: TimeInterval = 10) async throws -> ReceivedMessage {
        guard let gateway = gateway, let messenger = messenger else {
            throw ObscuraClient.ObscuraError.noMessenger
        }

        let raw = try await gateway.waitForRawEnvelope(timeout: timeout)

        // Parse sender ID from envelope bytes
        let sourceUserId = bytesToUuid(raw.senderID)

        // Decode EncryptedMessage from envelope
        let encMsg = try Obscura_V2_EncryptedMessage(serializedData: raw.message)

        // Decrypt
        let messageType = encMsg.type == .prekeyMessage ? 1 : 2
        let plaintext = try await messenger.decrypt(
            sourceUserId: sourceUserId,
            content: encMsg.content,
            messageType: messageType
        )

        // Decode ClientMessage
        let clientMessage = try Obscura_V2_ClientMessage(serializedData: Data(plaintext))

        // Ack
        try await gateway.acknowledge([raw.id])

        return ReceivedMessage(
            sourceUserId: sourceUserId,
            type: clientMessage.type.rawValue,
            text: clientMessage.text,
            username: clientMessage.username,
            accepted: clientMessage.accepted,
            timestamp: clientMessage.timestamp,
            rawBytes: Data(plaintext)
        )
    }

    /// Check if this user is friends with another
    public func isFriendsWith(_ userId: String) async -> Bool {
        await friends.isFriend(userId)
    }

    // MARK: - Helpers

    private func bytesToUuid(_ data: Data) -> String {
        guard data.count == 16 else { return data.map { String(format: "%02x", $0) }.joined() }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let i = hex.startIndex
        return "\(hex[i..<hex.index(i, offsetBy: 8)])-\(hex[hex.index(i, offsetBy: 8)..<hex.index(i, offsetBy: 12)])-\(hex[hex.index(i, offsetBy: 12)..<hex.index(i, offsetBy: 16)])-\(hex[hex.index(i, offsetBy: 16)..<hex.index(i, offsetBy: 20)])-\(hex[hex.index(i, offsetBy: 20)..<hex.index(i, offsetBy: 32)])"
    }

    public enum TestClientError: Error, LocalizedError {
        case noBundles(String)
        case noMessage

        public var errorDescription: String? {
            switch self {
            case .noBundles(let userId): return "No prekey bundles for user \(userId)"
            case .noMessage: return "No message received"
            }
        }
    }
}
