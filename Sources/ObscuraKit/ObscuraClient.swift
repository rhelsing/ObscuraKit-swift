import Foundation
import GRDB
import LibSignalClient
import SwiftProtobuf

// MARK: - Public Types

public enum ConnectionState: String, Sendable {
    case disconnected, connecting, connected, reconnecting
}

public enum AuthState: String, Sendable {
    case loggedOut, authenticated
}

public struct ReceivedMessage: Sendable {
    public let type: Int  // ClientMessage.Type raw value (0=TEXT, 2=FRIEND_REQUEST, etc.)
    public let text: String
    public let username: String
    public let accepted: Bool
    public let sourceUserId: String
    public let senderDeviceId: String?
    public let timestamp: UInt64
    public let rawBytes: Data
}

// MARK: - ObscuraClient

/// ObscuraClient — the unified facade.
/// This is the public API that both SwiftUI views and XCTests call.
/// All high-level operations live here. Views never touch messenger/gateway directly.
public class ObscuraClient {

    // MARK: - Domain Actors (always initialized, never nil)

    public let api: APIClient
    public let friends: FriendActor
    public let messages: MessageActor
    public let devices: DeviceActor
    public let signalStore: GRDBSignalStore
    public let gateway: GatewayConnection

    // Messenger is initialized after register/login with real keys
    private var _messenger: MessengerActor?
    private var signalProtocolStore: InMemorySignalProtocolStore?

    // MARK: - Observable State

    private var _connectionState: ConnectionState = .disconnected
    private var _authState: AuthState = .loggedOut

    /// Connection state stream — views bind to this
    public var connectionState: ConnectionState { _connectionState }
    public var authState: AuthState { _authState }

    /// Buffered message queue for waitForMessage
    private var messageQueue: [ReceivedMessage] = []
    private var messageWaiters: [CheckedContinuation<ReceivedMessage, Error>] = []

    /// Events stream — every received message after routing (multi-observer)
    private var eventContinuations: [AsyncStream<ReceivedMessage>.Continuation] = []

    public func events() -> AsyncStream<ReceivedMessage> {
        AsyncStream { continuation in
            eventContinuations.append(continuation)
            continuation.onTermination = { [weak self] _ in
                self?.eventContinuations.removeAll { $0 as AnyObject === continuation as AnyObject }
            }
        }
    }

    private func emit(_ message: ReceivedMessage) {
        // Push to stream subscribers
        for c in eventContinuations { c.yield(message) }
        // Push to waitForMessage waiters
        if !messageWaiters.isEmpty {
            let waiter = messageWaiters.removeFirst()
            waiter.resume(returning: message)
        } else {
            messageQueue.append(message)
        }
    }

    // MARK: - Auth State

    public private(set) var token: String?
    public private(set) var refreshToken: String?
    public private(set) var userId: String?
    public private(set) var username: String?
    public private(set) var deviceId: String?
    public private(set) var identityKeyPair: IdentityKeyPair?
    public private(set) var registrationId: UInt32?

    // Background tasks
    private var envelopeTask: Task<Void, Never>?
    private var tokenRefreshTask: Task<Void, Never>?

    // MARK: - Init

    public init(apiURL: String) throws {
        self.api = APIClient(baseURL: apiURL)
        self.friends = try FriendActor()
        self.messages = try MessageActor()
        self.devices = try DeviceActor()
        self.signalStore = try GRDBSignalStore()
        self.gateway = GatewayConnection(api: api)
    }

    // MARK: - Register

    public func register(_ username: String, _ password: String) async throws {
        // 1. Register user account
        let result = try await api.registerUser(username, password)
        guard let token = result["token"] as? String else { throw ObscuraError.missingToken }

        self.token = token
        self.refreshToken = result["refreshToken"] as? String
        self.userId = APIClient.extractUserId(token)
        self.username = username
        await api.setToken(token)
        await rateLimitDelay()

        // 2. Generate Signal keys
        let identity = IdentityKeyPair.generate()
        let regId = UInt32.random(in: 1...16380)
        self.identityKeyPair = identity
        self.registrationId = regId

        let signedPreKeyPrivate = PrivateKey.generate()
        let signedPreKeySignature = identity.privateKey.generateSignature(
            message: signedPreKeyPrivate.publicKey.serialize()
        )

        var oneTimePreKeys: [[String: Any]] = []
        var preKeyRecords: [(id: UInt32, privateKey: PrivateKey)] = []
        for i: UInt32 in 1...100 {
            let pk = PrivateKey.generate()
            oneTimePreKeys.append([
                "keyId": Int(i),
                "publicKey": Data(pk.publicKey.serialize()).base64EncodedString(),
            ])
            preKeyRecords.append((id: i, privateKey: pk))
        }

        // 3. Provision device
        let deviceResult = try await api.provisionDevice(
            name: "ObscuraKit-device",
            identityKey: Data(identity.publicKey.serialize()).base64EncodedString(),
            registrationId: Int(regId),
            signedPreKey: [
                "keyId": 1,
                "publicKey": Data(signedPreKeyPrivate.publicKey.serialize()).base64EncodedString(),
                "signature": Data(signedPreKeySignature).base64EncodedString(),
            ],
            oneTimePreKeys: oneTimePreKeys
        )

        guard let deviceToken = deviceResult["token"] as? String else {
            throw ObscuraError.provisionFailed("no device token")
        }

        self.token = deviceToken
        self.deviceId = APIClient.extractDeviceId(deviceToken)
        await api.setToken(deviceToken)

        // 4. Signal protocol store
        let protocolStore = InMemorySignalProtocolStore(identity: identity, registrationId: regId)
        try protocolStore.storeSignedPreKey(
            SignedPreKeyRecord(id: 1, timestamp: UInt64(Date().timeIntervalSince1970), privateKey: signedPreKeyPrivate, signature: signedPreKeySignature),
            id: 1, context: NullContext()
        )
        for record in preKeyRecords {
            try protocolStore.storePreKey(
                PreKeyRecord(id: record.id, publicKey: record.privateKey.publicKey, privateKey: record.privateKey),
                id: record.id, context: NullContext()
            )
        }
        self.signalProtocolStore = protocolStore

        // 5. Messenger
        self._messenger = MessengerActor(api: api, store: protocolStore, ownUserId: self.userId!)
        self._authState = .authenticated
    }

    // MARK: - Login

    public func login(_ username: String, _ password: String, deviceId: String? = nil) async throws {
        let result = try await api.loginWithDevice(username, password, deviceId: deviceId)
        guard let token = result["token"] as? String else { throw ObscuraError.missingToken }

        self.token = token
        self.refreshToken = result["refreshToken"] as? String
        self.userId = APIClient.extractUserId(token)
        self.username = username
        self.deviceId = APIClient.extractDeviceId(token) ?? deviceId
        await api.setToken(token)
        self._authState = .authenticated
    }

    // MARK: - Connect (WebSocket + envelope loop + token refresh)

    public func connect() async throws {
        _connectionState = .connecting
        try await gateway.connect()
        _connectionState = .connected
        startEnvelopeLoop()
        startTokenRefresh()
    }

    public func disconnect() {
        envelopeTask?.cancel()
        tokenRefreshTask?.cancel()
        gateway.disconnect()
        _connectionState = .disconnected
    }

    // MARK: - High-Level Operations

    /// Send a text message to a friend
    public func send(to friendUserId: String, _ text: String) async throws {
        let messenger = try requireMessenger()
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let messageId = "msg_\(UUID().uuidString)"

        var msg = Obscura_V2_ClientMessage()
        msg.type = .text
        msg.text = text
        msg.timestamp = timestamp

        try await sendToAllDevices(friendUserId, msg)

        // Persist locally
        await messages.add(friendUserId, Message(messageId: messageId, conversationId: friendUserId, timestamp: timestamp, content: text, isSent: true))

        // SENT_SYNC to own devices
        try await sendSentSync(conversationId: friendUserId, messageId: messageId, timestamp: timestamp, content: text)
    }

    /// Send a friend request
    public func befriend(_ targetUserId: String) async throws {
        let messenger = try requireMessenger()

        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendRequest
        msg.username = username ?? ""
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        try await sendToAllDevices(targetUserId, msg)
        await friends.add(targetUserId, "", status: .pendingSent)

        // FRIEND_SYNC to own devices
        try await sendFriendSync(username: "", action: "add", status: "pending_sent", userId: targetUserId)
    }

    /// Accept a friend request
    public func acceptFriend(_ targetUserId: String) async throws {
        let messenger = try requireMessenger()

        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendResponse
        msg.username = username ?? ""
        msg.accepted = true
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        try await sendToAllDevices(targetUserId, msg)
        await friends.updateStatus(targetUserId, .accepted)

        try await sendFriendSync(username: "", action: "add", status: "accepted", userId: targetUserId)
    }

    /// Send a MODEL_SYNC message to a friend (pass pre-serialized ClientMessage data)
    public func sendRawMessage(to friendUserId: String, clientMessageData: Data) async throws {
        let messenger = try requireMessenger()
        let bundles = try await messenger.fetchPreKeyBundles(friendUserId)
        await rateLimitDelay()

        for bundle in bundles {
            try? await messenger.processServerBundle(bundle, userId: friendUserId)
            let targetDeviceId = bundle["deviceId"] as? String ?? friendUserId
            try await messenger.queueMessage(targetDeviceId: targetDeviceId, clientMessageData: clientMessageData, targetUserId: friendUserId)
        }
        _ = try await messenger.flushMessages()
    }

    /// Announce device list to all friends
    public func announceDevices(isRevocation: Bool = false, signature: Data = Data()) async throws {
        let ownDevices = await devices.getOwnDevices()
        var announce = Obscura_V2_DeviceAnnounce()
        announce.devices = ownDevices.map { dev in
            var info = Obscura_V2_DeviceInfo()
            info.deviceID = dev.deviceId
            info.deviceName = dev.deviceName
            return info
        }
        announce.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        announce.isRevocation = isRevocation
        announce.signature = signature

        var msg = Obscura_V2_ClientMessage()
        msg.type = .deviceAnnounce
        msg.deviceAnnounce = announce

        let accepted = await friends.getAccepted()
        for friend in accepted {
            try await sendToAllDevices(friend.userId, msg)
        }
    }

    // MARK: - Recovery

    /// Generate a 12-word recovery phrase. Store it securely — it's the only way to recover.
    public var recoveryPhrase: String?
    public var recoveryPublicKey: Data?

    public func generateRecoveryPhrase() -> String {
        let phrase = RecoveryKeys.generatePhrase()
        self.recoveryPhrase = phrase
        self.recoveryPublicKey = RecoveryKeys.getPublicKey(from: phrase)
        return phrase
    }

    /// Revoke a device — delete from server, purge messages, broadcast signed DeviceAnnounce.
    public func revokeDevice(_ recoveryPhrase: String, targetDeviceId: String) async throws {
        try await api.deleteDevice(targetDeviceId)
        await rateLimitDelay()

        _ = await messages.deleteByAuthorDevice(targetDeviceId)

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let remainingDevices = await devices.getOwnDevices().filter { $0.deviceId != targetDeviceId }
        let remainingIds = remainingDevices.map(\.deviceId)

        let announceData = RecoveryKeys.serializeAnnounceForSigning(
            deviceIds: remainingIds, timestamp: timestamp, isRevocation: true
        )
        let signature = RecoveryKeys.sign(phrase: recoveryPhrase, data: announceData)
        let recoveryPubKey = RecoveryKeys.getPublicKey(from: recoveryPhrase)

        try await announceDevices(isRevocation: true, signature: signature)
    }

    /// Announce recovery to all friends (new device replacing old ones).
    public func announceRecovery(_ recoveryPhrase: String) async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let announceData = RecoveryKeys.serializeAnnounceForSigning(
            deviceIds: [deviceId ?? ""], timestamp: timestamp, isRevocation: false
        )
        let signature = RecoveryKeys.sign(phrase: recoveryPhrase, data: announceData)
        let recoveryPubKey = RecoveryKeys.getPublicKey(from: recoveryPhrase)

        var announce = Obscura_V2_DeviceRecoveryAnnounce()
        var deviceInfo = Obscura_V2_DeviceInfo()
        deviceInfo.deviceID = deviceId ?? ""
        announce.newDevices = [deviceInfo]
        announce.timestamp = timestamp
        announce.signature = signature
        announce.isFullRecovery = true
        announce.recoveryPublicKey = recoveryPubKey

        var msg = Obscura_V2_ClientMessage()
        msg.type = .deviceRecoveryAnnounce
        msg.deviceRecoveryAnnounce = announce

        let accepted = await friends.getAccepted()
        for friend in accepted {
            try await sendToAllDevices(friend.userId, msg)
        }
    }

    // MARK: - Backup

    private var backupEtag: String?

    /// Upload encrypted backup to server.
    public func uploadBackup() async throws -> String? {
        let friendsData = await friends.getAll()
        let exportData = SyncBlobExporter.export(friends: friendsData, messages: [])
        let etag = try await api.uploadBackup(exportData, etag: backupEtag)
        backupEtag = etag
        return etag
    }

    /// Download backup from server.
    public func downloadBackup() async throws -> Data? {
        guard let result = try await api.downloadBackup(etag: backupEtag) else { return nil }
        backupEtag = result.etag
        return result.data
    }

    /// Wait for next incoming message. Uses buffered queue — messages processed by
    /// the envelope loop are queued here, so timing doesn't matter.
    public func waitForMessage(timeout: TimeInterval = 10) async throws -> ReceivedMessage {
        // Check buffer first
        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }

        // Wait with timeout
        return try await withThrowingTaskGroup(of: ReceivedMessage.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.messageWaiters.append(continuation)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ObscuraError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Logout

    public func logout() async throws {
        disconnect()
        if let rt = refreshToken { try? await api.logout(rt) }
        token = nil
        refreshToken = nil
        userId = nil
        _authState = .loggedOut
        await api.clearToken()
    }

    // MARK: - Internal: Send to all devices of a user

    private func sendToAllDevices(_ targetUserId: String, _ msg: Obscura_V2_ClientMessage) async throws {
        let messenger = try requireMessenger()
        let bundles = try await messenger.fetchPreKeyBundles(targetUserId)
        await rateLimitDelay()

        let msgData = try msg.serializedData()
        for bundle in bundles {
            try? await messenger.processServerBundle(bundle, userId: targetUserId)
            let targetDeviceId = bundle["deviceId"] as? String ?? targetUserId
            try await messenger.queueMessage(targetDeviceId: targetDeviceId, clientMessageData: msgData, targetUserId: targetUserId)
        }
        _ = try await messenger.flushMessages()
    }

    // MARK: - Internal: Envelope Loop

    private func startEnvelopeLoop() {
        envelopeTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                do {
                    let raw = try await self.gateway.waitForRawEnvelope(timeout: 60)
                    await self.processEnvelope(raw)
                } catch {
                    if Task.isCancelled { break }
                    // Timeout — just loop again
                }
            }
        }
    }

    private func processEnvelope(_ raw: (id: Data, senderID: Data, timestamp: UInt64, message: Data)) async {
        guard let messenger = _messenger else { return }

        let sourceUserId = bytesToUuid(raw.senderID)

        do {
            let encMsg = try Obscura_V2_EncryptedMessage(serializedData: raw.message)
            let messageType = encMsg.type == .prekeyMessage ? 1 : 2
            let plaintext = try await messenger.decrypt(
                sourceUserId: sourceUserId, content: encMsg.content, messageType: messageType
            )
            let clientMsg = try Obscura_V2_ClientMessage(serializedData: Data(plaintext))

            // Route by message type
            await routeMessage(clientMsg, sourceUserId: sourceUserId)

            // Emit to event subscribers
            let received = ReceivedMessage(
                type: clientMsg.type.rawValue,
                text: clientMsg.text,
                username: clientMsg.username,
                accepted: clientMsg.accepted,
                sourceUserId: sourceUserId,
                senderDeviceId: nil,
                timestamp: clientMsg.timestamp,
                rawBytes: Data(plaintext)
            )
            emit(received)

            // Ack
            try? gateway.acknowledge([raw.id])
        } catch {
            // Decrypt failed — skip envelope
        }
    }

    // MARK: - Internal: Message Routing

    private func routeMessage(_ msg: Obscura_V2_ClientMessage, sourceUserId: String) async {
        switch msg.type {
        case .friendRequest:
            await friends.add(sourceUserId, msg.username, status: .pendingReceived)

        case .friendResponse:
            if msg.accepted {
                await friends.updateStatus(sourceUserId, .accepted)
            }

        case .text, .image, .video, .audio, .file:
            let messageData = Message(
                messageId: "msg_\(UUID().uuidString)",
                conversationId: sourceUserId,
                timestamp: msg.timestamp,
                content: msg.text,
                isSent: false
            )
            await messages.add(sourceUserId, messageData)

        case .deviceAnnounce:
            let deviceInfos = msg.deviceAnnounce.devices.map { dev -> [String: String] in
                ["deviceId": dev.deviceID, "deviceName": dev.deviceName]
            }
            await friends.updateDevices(sourceUserId, devices: deviceInfos, timestamp: msg.deviceAnnounce.timestamp)

            if msg.deviceAnnounce.isRevocation {
                // Purge messages from revoked devices
                let currentDeviceIds = Set(deviceInfos.compactMap { $0["deviceId"] })
                // Would need to know which device was removed to purge its messages
            }

        case .modelSync:
            // ORM would handle this: orm.handleSync(msg.modelSync, from: sourceUserId)
            break

        case .syncBlob:
            // Import state from linked device
            if let parsed = SyncBlobExporter.parseExport(msg.syncBlob.compressedData) {
                for f in parsed.friends {
                    let status = FriendStatus(rawValue: f["status"] as? String ?? "") ?? .pendingSent
                    await friends.add(f["userId"] as? String ?? "", f["username"] as? String ?? "", status: status)
                }
                for m in parsed.messages {
                    let message = Message(
                        messageId: m["messageId"] as? String ?? UUID().uuidString,
                        conversationId: m["conversationId"] as? String ?? "",
                        content: m["content"] as? String ?? ""
                    )
                    await messages.add(m["conversationId"] as? String ?? "", message)
                }
            }

        case .sentSync:
            let ss = msg.sentSync
            let messageData = Message(
                messageId: ss.messageID,
                conversationId: ss.conversationID,
                timestamp: ss.timestamp,
                content: String(data: ss.content, encoding: .utf8) ?? "",
                isSent: true
            )
            await messages.add(ss.conversationID, messageData)

        case .friendSync:
            let fs = msg.friendSync
            if fs.action == "add" {
                let status = FriendStatus(rawValue: fs.status) ?? .pendingSent
                await friends.add(sourceUserId, fs.username, status: status)
            } else if fs.action == "remove" {
                await friends.remove(sourceUserId)
            }

        case .sessionReset:
            // Delete all sessions for this user
            break

        default:
            break
        }
    }

    // MARK: - Internal: SENT_SYNC

    private func sendSentSync(conversationId: String, messageId: String, timestamp: UInt64, content: String) async throws {
        let ownDevices = await devices.getOwnDevices()
        guard !ownDevices.isEmpty else { return }

        var syncMsg = Obscura_V2_ClientMessage()
        syncMsg.type = .sentSync
        var payload = Obscura_V2_SentSync()
        payload.conversationID = conversationId
        payload.messageID = messageId
        payload.timestamp = timestamp
        payload.content = Data(content.utf8)
        syncMsg.sentSync = payload

        for device in ownDevices where device.deviceId != self.deviceId {
            try? await sendToAllDevices(self.userId!, syncMsg)
        }
    }

    // MARK: - Internal: FRIEND_SYNC

    private func sendFriendSync(username: String, action: String, status: String, userId targetUserId: String) async throws {
        let ownDevices = await devices.getOwnDevices()
        guard !ownDevices.isEmpty else { return }

        var syncMsg = Obscura_V2_ClientMessage()
        syncMsg.type = .friendSync
        var payload = Obscura_V2_FriendSync()
        payload.username = username
        payload.action = action
        payload.status = status
        payload.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        syncMsg.friendSync = payload

        for device in ownDevices where device.deviceId != self.deviceId {
            try? await sendToAllDevices(self.userId!, syncMsg)
        }
    }

    // MARK: - Internal: Token Refresh

    private func startTokenRefresh() {
        tokenRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let token = self.token else {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continue
                }

                let delayMs = self.getTokenRefreshDelay(token)
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)

                if let rt = self.refreshToken {
                    if let result = try? await self.api.refreshSession(rt) {
                        if let newToken = result["token"] as? String {
                            self.token = newToken
                            await self.api.setToken(newToken)
                        }
                        if let newRefresh = result["refreshToken"] as? String {
                            self.refreshToken = newRefresh
                        }
                    }
                }
            }
        }
    }

    private func getTokenRefreshDelay(_ token: String) -> UInt64 {
        guard let payload = APIClient.decodeJWT(token),
              let exp = payload["exp"] as? Double else { return 30000 }
        let now = Date().timeIntervalSince1970
        let ttl = exp - now
        let delay = max(ttl * 0.8, 5) * 1000
        return UInt64(delay)
    }

    // MARK: - Helpers

    private func requireMessenger() throws -> MessengerActor {
        guard let m = _messenger else { throw ObscuraError.noMessenger }
        return m
    }

    private func bytesToUuid(_ data: Data) -> String {
        guard data.count == 16 else { return data.map { String(format: "%02x", $0) }.joined() }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let i = hex.startIndex
        return "\(hex[i..<hex.index(i, offsetBy: 8)])-\(hex[hex.index(i, offsetBy: 8)..<hex.index(i, offsetBy: 12)])-\(hex[hex.index(i, offsetBy: 12)..<hex.index(i, offsetBy: 16)])-\(hex[hex.index(i, offsetBy: 16)..<hex.index(i, offsetBy: 20)])-\(hex[hex.index(i, offsetBy: 20)..<hex.index(i, offsetBy: 32)])"
    }

    public enum ObscuraError: Error, LocalizedError {
        case missingToken
        case notAuthenticated
        case provisionFailed(String)
        case noMessenger
        case noMessage
        case timeout

        public var errorDescription: String? {
            switch self {
            case .missingToken: return "No token in server response"
            case .notAuthenticated: return "Not authenticated"
            case .provisionFailed(let msg): return "Device provisioning failed: \(msg)"
            case .noMessenger: return "Messenger not initialized (call register first)"
            case .noMessage: return "No message received"
            case .timeout: return "Operation timed out"
            }
        }
    }
}
