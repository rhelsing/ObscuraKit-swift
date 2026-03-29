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
    public let gateway: GatewayConnection

    // Messenger is initialized after register/login with real keys
    private var _messenger: MessengerActor?
    public private(set) var persistentSignalStore: PersistentSignalStore?

    /// Security logger — set your own implementation or use the default PrintLogger.
    public var logger: ObscuraLogger = PrintLogger()

    // MARK: - Observable State

    private var _connectionState: ConnectionState = .disconnected
    private var _authState: AuthState = .loggedOut

    /// Connection state stream — views bind to this
    public var connectionState: ConnectionState { _connectionState }
    public var authState: AuthState { _authState }

    /// Buffered message queue for waitForMessage
    private var messageQueue: [ReceivedMessage] = []
    // messageWaiters removed — waitForMessage now polls messageQueue directly

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
        // Push to queue — waitForMessage polls this
        if messageQueue.count >= 1000 { messageQueue.removeFirst() }
        messageQueue.append(message)
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

    // Decrypt rate limiting: track failures per sender
    private var decryptFailures: [String: (count: Int, windowStart: Date)] = [:]
    private let maxDecryptFailures = 10
    private let decryptFailureWindow: TimeInterval = 60

    // Prekey replenishment (matches Kotlin pattern)
    private let prekeyMinCount = 20
    private let prekeyReplenishCount: UInt32 = 50

    // Signal key generation constants (shared by register, loginAndProvision, takeoverDevice)
    private static let initialPreKeyCount: UInt32 = 100
    private static let maxRegistrationId: UInt32 = 16380
    private static let signedPreKeyId: UInt32 = 1

    // Token refresh buffer — refresh if expiring within this many seconds
    private static let tokenExpiryBufferSeconds: Double = 60

    // XEdDSA empty signature placeholder size (bytes)
    private static let emptySignatureSize = 64

    // MARK: - Init

    /// The shared database — nil for in-memory (tests), file-backed for production.
    private let sharedDb: DatabaseQueue?

    /// In-memory client (tests). All state lost on dealloc.
    public init(apiURL: String, logger: ObscuraLogger = PrintLogger()) throws {
        self.logger = logger
        self.sharedDb = nil
        self.api = APIClient(baseURL: apiURL)
        self.friends = try FriendActor()
        self.messages = try MessageActor()
        self.devices = try DeviceActor()
        self.gateway = GatewayConnection(api: api, logger: logger)
    }

    /// File-backed client (production). All state persists to `dataDirectory/obscura.sqlite`.
    /// On init, restores Signal identity from DB if one exists.
    public init(apiURL: String, dataDirectory: String, logger: ObscuraLogger = PrintLogger()) throws {
        self.logger = logger

        // Ensure directory exists
        try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
        let dbPath = (dataDirectory as NSString).appendingPathComponent("obscura.sqlite")

        let db = try DatabaseQueue(path: dbPath)
        try db.write { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        self.sharedDb = db

        self.api = APIClient(baseURL: apiURL)
        self.friends = try FriendActor(db: db)
        self.messages = try MessageActor(db: db)
        self.devices = try DeviceActor(db: db)
        self.gateway = GatewayConnection(api: api, logger: logger)

        // Restore Signal store from persisted DB if identity exists
        let store = try PersistentSignalStore(db: db)
        store.logger = logger
        if store.hasPersistedIdentity {
            self.persistentSignalStore = store
            self.identityKeyPair = try store.identityKeyPair(context: NullContext())
            self.registrationId = try store.localRegistrationId(context: NullContext())
        }
    }

    deinit {
        envelopeTask?.cancel()
        tokenRefreshTask?.cancel()
        gateway.disconnect()
    }

    // MARK: - Session State

    /// Quick check if authenticated (has token + userId)
    public var hasSession: Bool { token != nil && userId != nil }

    /// Restore a previously saved session without re-authenticating.
    /// If a PersistentSignalStore exists (file-backed client), rebuilds the MessengerActor
    /// so decrypt/encrypt work immediately. Call `connect()` after this.
    public func restoreSession(token: String, refreshToken: String?, userId: String,
                               deviceId: String?, username: String?, registrationId: UInt32 = 0) async {
        self.token = token
        self.refreshToken = refreshToken
        self.userId = userId
        self.deviceId = deviceId
        self.username = username
        await api.setToken(token)

        // Rebuild messenger from persisted Signal store if available
        if let store = persistentSignalStore, store.hasPersistedIdentity {
            self.identityKeyPair = try? store.identityKeyPair(context: NullContext())
            self.registrationId = (try? store.localRegistrationId(context: NullContext())) ?? registrationId
            self._messenger = MessengerActor(api: api, store: store, ownUserId: userId)
        } else {
            self.registrationId = registrationId
        }

        if let deviceId = deviceId, let regId = self.registrationId {
            await _messenger?.mapDevice(deviceId, userId: userId, registrationId: regId)
        }
        _authState = .authenticated
    }

    /// Ensure the current token is fresh; refresh if expiring within buffer.
    /// Returns true if a valid token is available after the call.
    @discardableResult
    public func ensureFreshToken() async -> Bool {
        guard let token = token else { return false }
        guard let payload = APIClient.decodeJWT(token),
              let exp = payload["exp"] as? Double else { return false }
        let now = Date().timeIntervalSince1970
        guard (exp - now) <= Self.tokenExpiryBufferSeconds else { return true }
        guard let rt = refreshToken else { return false }
        do {
            let result = try await api.refreshSession(rt)
            self.token = result.token
            await api.setToken(result.token)
            if let newRT = result.refreshToken { self.refreshToken = newRT }
            return true
        } catch {
            logger.tokenRefreshFailed(attempt: 1, error: "\(error)")
            return false
        }
    }

    // MARK: - Register

    public func register(_ username: String, _ password: String) async throws {
        // 1. Register user account
        let result = try await api.registerUser(username, password)
        let token = result.token

        self.token = token
        self.refreshToken = result.refreshToken
        self.userId = APIClient.extractUserId(token)
        self.username = username
        await api.setToken(token)
        await rateLimitDelay()

        // 2. Generate Signal keys
        let (identity, regId) = generateSignalIdentity()
        let (spkPrivate, spkSig) = generateSignedPreKey(identity: identity)
        let (otpKeys, preKeyRecords) = generateOneTimePreKeys()

        // 3. Provision device
        let deviceResult = try await api.provisionDevice(
            name: "ObscuraKit-device",
            identityKey: Data(identity.publicKey.serialize()).base64EncodedString(),
            registrationId: Int(regId),
            signedPreKey: SignedPreKeyUpload(
                keyId: Int(Self.signedPreKeyId),
                publicKey: Data(spkPrivate.publicKey.serialize()).base64EncodedString(),
                signature: Data(spkSig).base64EncodedString()
            ),
            oneTimePreKeys: otpKeys
        )

        let deviceToken = deviceResult.token

        self.token = deviceToken
        self.deviceId = APIClient.extractDeviceId(deviceToken)
        await api.setToken(deviceToken)

        // 4. Persistent Signal protocol store (survives app restart)
        let store = try initializeSignalStore(identity: identity, regId: regId, spkPrivate: spkPrivate, spkSig: spkSig, preKeyRecords: preKeyRecords)

        // 5. Messenger
        self._messenger = MessengerActor(api: api, store: store, ownUserId: self.userId!)
        self._authState = .authenticated
    }

    // MARK: - Login

    public func login(_ username: String, _ password: String, deviceId: String? = nil) async throws {
        let result = try await api.loginWithDevice(username, password, deviceId: deviceId)
        let token = result.token

        self.token = token
        self.refreshToken = result.refreshToken
        self.userId = APIClient.extractUserId(token)
        self.username = username
        self.deviceId = APIClient.extractDeviceId(token) ?? deviceId
        await api.setToken(token)
        self._authState = .authenticated
    }

    // MARK: - Login + Provision (device linking)

    /// Combined login + new device provisioning for device linking.
    /// Logs in with user credentials, generates fresh Signal keys, provisions a new device.
    public func loginAndProvision(_ username: String, _ password: String, deviceName: String = "Device 2") async throws {
        self.username = username
        let loginResult = try await api.loginWithDevice(username, password, deviceId: nil)
        self.token = loginResult.token
        self.userId = APIClient.extractUserId(loginResult.token)
        await api.setToken(loginResult.token)
        await rateLimitDelay()

        let (identity, regId) = generateSignalIdentity()
        let (spkPrivate, spkSig) = generateSignedPreKey(identity: identity)
        let (otpKeys, preKeyRecords) = generateOneTimePreKeys()

        let deviceResult = try await api.provisionDevice(
            name: deviceName,
            identityKey: Data(identity.publicKey.serialize()).base64EncodedString(),
            registrationId: Int(regId),
            signedPreKey: SignedPreKeyUpload(
                keyId: Int(Self.signedPreKeyId),
                publicKey: Data(spkPrivate.publicKey.serialize()).base64EncodedString(),
                signature: Data(spkSig).base64EncodedString()
            ),
            oneTimePreKeys: otpKeys
        )

        self.token = deviceResult.token
        self.refreshToken = deviceResult.refreshToken
        self.deviceId = APIClient.extractDeviceId(deviceResult.token) ?? deviceResult.deviceId
        await api.setToken(deviceResult.token)

        let store = try initializeSignalStore(identity: identity, regId: regId, spkPrivate: spkPrivate, spkSig: spkSig, preKeyRecords: preKeyRecords)
        self._messenger = MessengerActor(api: api, store: store, ownUserId: self.userId!)

        await devices.storeIdentity(DeviceIdentity(
            coreUsername: username, deviceId: self.deviceId ?? "", deviceUUID: self.deviceId ?? ""
        ))
        _authState = .authenticated
        await rateLimitDelay()
    }

    // MARK: - Connect (WebSocket + envelope loop + token refresh)

    public func connect() async throws {
        // Cancel any existing loops from a previous connection
        envelopeTask?.cancel()
        envelopeTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil

        _connectionState = .connecting
        // Listen for PreKeyStatus frames from server
        gateway.onPreKeyStatus = { [weak self] count, threshold in
            if count < threshold {
                Task { [weak self] in await self?.replenishPreKeys() }
            }
        }
        NSLog("[ObscuraKit] connecting gateway...")
        try await gateway.connect()
        NSLog("[ObscuraKit] gateway connected, starting envelope loop")
        _connectionState = .connected
        startEnvelopeLoop()
        startTokenRefresh()
    }

    public func disconnect() {
        envelopeTask?.cancel()
        envelopeTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        gateway.disconnect()
        _connectionState = .disconnected
        messageQueue.removeAll()
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
            do {
                try await messenger.processServerBundle(bundle, userId: friendUserId)
            } catch {
                logger.sessionEstablishFailed(userId: friendUserId, error: "\(error)")
                continue
            }
            let targetDeviceId = bundle.deviceId
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

    // MARK: - Session Reset

    /// Delete all Signal sessions for a user and send SESSION_RESET message.
    public func resetSessionWith(_ targetUserId: String, reason: String = "manual") async throws {
        try? persistentSignalStore?.deleteAllSessions(for: targetUserId)

        var msg = Obscura_V2_ClientMessage()
        msg.type = .sessionReset
        msg.resetReason = reason
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await sendToAllDevices(targetUserId, msg)
    }

    /// Reset Signal sessions with all accepted friends.
    public func resetAllSessions(reason: String = "manual") async throws {
        for friend in await friends.getAccepted() {
            try? await resetSessionWith(friend.userId, reason: reason)
        }
    }

    // MARK: - Device Sync

    /// Ask own devices for state (SYNC_REQUEST).
    public func requestSync() async throws {
        let messenger = try requireMessenger()
        guard let uid = userId else { throw ObscuraError.notAuthenticated }
        let ownDevices = await devices.getOwnDevices()

        var msg = Obscura_V2_ClientMessage()
        msg.type = .syncRequest
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let msgData = try msg.serializedData()

        for device in ownDevices where device.deviceId != self.deviceId {
            try await messenger.queueMessage(targetDeviceId: device.deviceId, clientMessageData: msgData, targetUserId: uid)
        }
        _ = try await messenger.flushMessages()
    }

    /// Send history (friends + messages) as SYNC_BLOB to a specific device.
    public func pushHistoryToDevice(_ targetDeviceId: String) async throws {
        let messenger = try requireMessenger()
        guard let uid = userId else { throw ObscuraError.notAuthenticated }

        let friendsData = await friends.getAll()
        let compressed = SyncBlobExporter.export(friends: friendsData, messages: [])

        var msg = Obscura_V2_ClientMessage()
        msg.type = .syncBlob
        msg.syncBlob.compressedData = compressed
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let msgData = try msg.serializedData()
        try await messenger.queueMessage(targetDeviceId: targetDeviceId, clientMessageData: msgData, targetUserId: uid)
        _ = try await messenger.flushMessages()
    }

    /// Approve a device link request — send DEVICE_LINK_APPROVAL, push history, announce.
    public func approveLink(newDeviceId: String, challengeResponse: Data) async throws {
        let messenger = try requireMessenger()
        guard let uid = userId else { throw ObscuraError.notAuthenticated }

        let identity = await devices.getIdentity()
        let ownDevices = await devices.getOwnDevices()
        let friendsData = await friends.getAll()
        let friendsExportData = SyncBlobExporter.export(friends: friendsData, messages: [])

        var approval = Obscura_V2_DeviceLinkApproval()
        if let pk = identity?.p2pPublicKey { approval.p2PPublicKey = pk }
        if let sk = identity?.p2pPrivateKey { approval.p2PPrivateKey = sk }
        if let rk = identity?.recoveryPublicKey { approval.recoveryPublicKey = rk }
        approval.challengeResponse = challengeResponse
        approval.ownDevices = ownDevices.map { d in
            var info = Obscura_V2_DeviceInfo()
            info.deviceID = d.deviceId
            info.deviceName = d.deviceName
            return info
        }
        approval.friendsExport = friendsExportData

        var msg = Obscura_V2_ClientMessage()
        msg.type = .deviceLinkApproval
        msg.deviceLinkApproval = approval
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let msgData = try msg.serializedData()
        try await messenger.queueMessage(targetDeviceId: newDeviceId, clientMessageData: msgData, targetUserId: uid)
        _ = try await messenger.flushMessages()

        try await pushHistoryToDevice(newDeviceId)
        try await announceDevices()
    }

    /// Announce device revocation to a specific friend with remaining device IDs.
    public func announceDeviceRevocation(to friendUserId: String, remainingDeviceIds: [String]) async throws {
        var announce = Obscura_V2_DeviceAnnounce()
        announce.devices = remainingDeviceIds.map { id in
            var info = Obscura_V2_DeviceInfo()
            info.deviceID = id
            info.deviceName = "Device"
            return info
        }
        announce.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        announce.isRevocation = true
        announce.signature = Data(repeating: 0, count: Self.emptySignatureSize)

        var msg = Obscura_V2_ClientMessage()
        msg.type = .deviceAnnounce
        msg.deviceAnnounce = announce
        try await sendToAllDevices(friendUserId, msg)
    }

    /// Re-provision this device with a new identity key (device takeover).
    public func takeoverDevice() async throws {
        let (identity, regId) = generateSignalIdentity()
        let (spkPrivate, spkSig) = generateSignedPreKey(identity: identity)
        let (otpKeys, preKeyRecords) = generateOneTimePreKeys()

        try await api.uploadDeviceKeys(
            identityKey: Data(identity.publicKey.serialize()).base64EncodedString(),
            registrationId: Int(regId),
            signedPreKey: SignedPreKeyUpload(
                keyId: Int(Self.signedPreKeyId),
                publicKey: Data(spkPrivate.publicKey.serialize()).base64EncodedString(),
                signature: Data(spkSig).base64EncodedString()
            ),
            oneTimePreKeys: otpKeys
        )

        let store = try initializeSignalStore(identity: identity, regId: regId, spkPrivate: spkPrivate, spkSig: spkSig, preKeyRecords: preKeyRecords)
        self._messenger = MessengerActor(api: api, store: store, ownUserId: self.userId!)

        if let did = deviceId, let uid = userId {
            await _messenger?.mapDevice(did, userId: uid, registrationId: regId)
        }
    }

    // MARK: - Encrypted Attachments

    /// Encrypt plaintext, upload ciphertext, send CONTENT_REFERENCE to friend.
    public func sendEncryptedAttachment(to friendUserId: String, plaintext: Data, mimeType: String = "application/octet-stream") async throws {
        let encrypted = try AttachmentCrypto.encrypt(plaintext)
        let result = try await api.uploadAttachment(encrypted.ciphertext)
        await rateLimitDelay()
        try await sendAttachment(
            to: friendUserId, attachmentId: result.id,
            contentKey: encrypted.contentKey, nonce: encrypted.nonce,
            mimeType: mimeType, sizeBytes: encrypted.sizeBytes
        )
    }

    /// Download ciphertext and decrypt with provided key material.
    public func downloadDecryptedAttachment(id: String, contentKey: Data, nonce: Data, expectedHash: Data? = nil) async throws -> Data {
        let ciphertext = try await api.fetchAttachment(id)
        return try AttachmentCrypto.decrypt(ciphertext, contentKey: contentKey, nonce: nonce, expectedHash: expectedHash)
    }

    /// Send a CONTENT_REFERENCE message to a friend (attachment already uploaded).
    public func sendAttachment(to friendUserId: String, attachmentId: String, contentKey: Data, nonce: Data, mimeType: String, sizeBytes: Int) async throws {
        var ref = Obscura_V2_ContentReference()
        ref.attachmentID = attachmentId
        ref.contentKey = contentKey
        ref.nonce = nonce
        ref.contentType = mimeType
        ref.sizeBytes = UInt64(sizeBytes)

        var msg = Obscura_V2_ClientMessage()
        msg.type = .contentReference
        msg.contentReference = ref
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await sendToAllDevices(friendUserId, msg)
    }

    /// Send a MODEL_SYNC message to a friend.
    public func sendModelSync(to friendUserId: String, model: String, entryId: String, op: String = "CREATE", data: Data) async throws {
        var sync = Obscura_V2_ModelSync()
        sync.model = model
        sync.id = entryId
        sync.op = {
            switch op.uppercased() {
            case "UPDATE": return .update
            case "DELETE": return .delete
            default: return .create
            }
        }()
        sync.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        sync.data = data
        sync.authorDeviceID = deviceId ?? ""

        var msg = Obscura_V2_ClientMessage()
        msg.type = .modelSync
        msg.modelSync = sync
        try await sendToAllDevices(friendUserId, msg)
    }

    // MARK: - Query Helpers

    /// Convenience: get messages for a conversation (delegates to MessageActor).
    public func getMessages(_ conversationId: String, limit: Int = 50) async -> [Message] {
        await messages.getMessages(conversationId, limit: limit)
    }

    /// Check if a backup exists on the server (HEAD request).
    public func checkBackup() async throws -> (exists: Bool, etag: String?, size: Int?) {
        try await api.checkBackup()
    }

    // MARK: - Recovery

    /// Generate a 12-word recovery phrase. Store it securely — it's the only way to recover.
    /// Access via getRecoveryPhrase() which clears the in-memory copy after read.
    private var _recoveryPhrase: String?
    public var recoveryPublicKey: Data?

    /// Read the recovery phrase exactly once, then wipe it from memory.
    public func getRecoveryPhrase() -> String? {
        let phrase = _recoveryPhrase
        _recoveryPhrase = nil
        return phrase
    }

    public func generateRecoveryPhrase() -> String {
        let phrase = RecoveryKeys.generatePhrase()
        self._recoveryPhrase = phrase
        self.recoveryPublicKey = RecoveryKeys.getPublicKey(from: phrase)
        return phrase
    }

    /// Revoke a device — delete from server, purge messages, broadcast signed DeviceAnnounce.
    public func revokeDevice(_ recoveryPhrase: String, targetDeviceId: String) async throws {
        try await api.deleteDevice(targetDeviceId)
        await rateLimitDelay()

        _ = await messages.deleteByAuthorDevice(targetDeviceId)

        // Clean up Signal sessions for revoked device
        try? persistentSignalStore?.deleteAllSessions(for: targetDeviceId)

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

        // Poll with short sleeps — avoids continuation leak that caused hangs
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !messageQueue.isEmpty {
                return messageQueue.removeFirst()
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
        }
        throw ObscuraError.timeout
    }

    // MARK: - Logout

    /// Logout — clears credentials and disconnects. Data (friends, messages, Signal sessions) is preserved.
    /// Call `restoreSession()` + `connect()` to resume, or `login()`/`loginAndProvision()` for a fresh session.
    public func logout() async throws {
        disconnect()
        if let rt = refreshToken { try? await api.logout(rt) }
        token = nil
        refreshToken = nil
        userId = nil
        username = nil
        deviceId = nil
        _recoveryPhrase = nil
        recoveryPublicKey = nil
        _messenger = nil
        _authState = .loggedOut
        await api.clearToken()
    }

    /// Nuclear wipe — clears ALL data from this device. Use for device revocation or account deletion.
    /// After this, the device must re-register or loginAndProvision.
    public func wipeDevice() async throws {
        try await logout()
        identityKeyPair = nil
        registrationId = nil
        persistentSignalStore?.clearAll()
        persistentSignalStore = nil
        await friends.clearAll()
        await messages.clearAll()
        await devices.clearAll()
    }

    // MARK: - Internal: Send to all devices of a user

    private func sendToAllDevices(_ targetUserId: String, _ msg: Obscura_V2_ClientMessage) async throws {
        let messenger = try requireMessenger()
        NSLog("[ObscuraKit] sendToAllDevices to %@, fetching bundles...", targetUserId)
        let bundles = try await messenger.fetchPreKeyBundles(targetUserId)
        NSLog("[ObscuraKit] got %d bundles for %@", bundles.count, targetUserId)
        await rateLimitDelay()

        let msgData = try msg.serializedData()
        for bundle in bundles {
            do {
                try await messenger.processServerBundle(bundle, userId: targetUserId)
            } catch {
                NSLog("[ObscuraKit] session establish failed for %@: %@", targetUserId, "\(error)")
                logger.sessionEstablishFailed(userId: targetUserId, error: "\(error)")
                continue
            }
            let targetDeviceId = bundle.deviceId
            try await messenger.queueMessage(targetDeviceId: targetDeviceId, clientMessageData: msgData, targetUserId: targetUserId)
        }
        let result = try await messenger.flushMessages()
        NSLog("[ObscuraKit] flushMessages result: %@", "\(result)")
    }

    // MARK: - Internal: Envelope Loop

    private func startEnvelopeLoop() {
        NSLog("[ObscuraKit] startEnvelopeLoop — messenger exists: \(_messenger != nil)")
        envelopeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                do {
                    let raw = try await self.gateway.waitForRawEnvelope(timeout: 30)
                    NSLog("[ObscuraKit] envelope received from %@", bytesToUuid(raw.senderID))
                    await self.processEnvelope(raw)
                } catch {
                    if Task.isCancelled { break }
                    if error is CancellationError { break }
                    if let gwError = error as? GatewayConnection.GatewayError {
                        if case .notConnected = gwError {
                            NSLog("[ObscuraKit] envelope loop: not connected, exiting")
                            break
                        }
                        if case .timeout = gwError { continue }
                    }
                    NSLog("[ObscuraKit] envelope loop error: %@", "\(error)")
                    break
                }
            }
            NSLog("[ObscuraKit] envelope loop ended")
        }
    }

    private func processEnvelope(_ raw: (id: Data, senderID: Data, timestamp: UInt64, message: Data)) async {
        guard let messenger = _messenger else {
            NSLog("[ObscuraKit] processEnvelope: messenger is nil, dropping envelope")
            return
        }

        let sourceUserId = bytesToUuid(raw.senderID)

        // Rate limit: skip senders with too many recent decrypt failures
        if let entry = decryptFailures[sourceUserId] {
            if Date().timeIntervalSince(entry.windowStart) > decryptFailureWindow {
                decryptFailures[sourceUserId] = nil // Reset window
            } else if entry.count >= maxDecryptFailures {
                return // Skip — rate limited
            }
        }

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

            // Check prekey count (non-blocking, fire-and-forget)
            checkAndReplenishPreKeys()

            // Ack
            do {
                try gateway.acknowledge([raw.id])
            } catch {
                logger.ackFailed(envelopeId: raw.id.map { String(format: "%02x", $0) }.joined(), error: "\(error)")
            }
        } catch {
            NSLog("[ObscuraKit] decrypt/route failed for %@: %@", sourceUserId, "\(error)")
            let entry = decryptFailures[sourceUserId] ?? (count: 0, windowStart: Date())
            decryptFailures[sourceUserId] = (count: entry.count + 1, windowStart: entry.windowStart)
            logger.decryptFailed(sourceUserId: sourceUserId, error: "\(error)")
        }
    }

    // MARK: - Internal: Message Routing

    private func routeMessage(_ msg: Obscura_V2_ClientMessage, sourceUserId: String) async {
        NSLog("[ObscuraKit] routeMessage type=%d from %@", msg.type.rawValue, sourceUserId)
        switch msg.type {
        case .friendRequest:
            NSLog("[ObscuraKit] friend request from %@ username=%@", sourceUserId, msg.username)
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
            let announce = msg.deviceAnnounce
            let deviceInfos = announce.devices.map { dev -> [String: String] in
                ["deviceId": dev.deviceID, "deviceName": dev.deviceName]
            }
            let deviceIds = announce.devices.map(\.deviceID)

            // Verify signature against sender's stored recovery public key
            if let friend = await friends.getFriend(sourceUserId),
               let recoveryPubKey = friend.recoveryPublicKey, !recoveryPubKey.isEmpty {
                let payload = RecoveryKeys.serializeAnnounceForSigning(
                    deviceIds: deviceIds, timestamp: announce.timestamp, isRevocation: announce.isRevocation
                )
                guard RecoveryKeys.verify(publicKey: recoveryPubKey, data: payload, signature: announce.signature) else {
                    break // Reject unverified announcement
                }
            }

            await friends.updateDevices(sourceUserId, devices: deviceInfos, timestamp: announce.timestamp)

            if announce.isRevocation {
                // Purge messages from revoked devices
                let currentDeviceIds = Set(deviceInfos.compactMap { $0["deviceId"] })
                // Would need to know which device was removed to purge its messages
            }

        case .modelSync:
            // ORM would handle this: orm.handleSync(msg.modelSync, from: sourceUserId)
            break

        case .syncBlob:
            // Import state from linked device — only accept from own devices
            guard sourceUserId == self.userId else { break }
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
            // Only accept sent sync from own devices
            guard sourceUserId == self.userId else { break }
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
            // Only accept friend sync from own devices
            guard sourceUserId == self.userId else { break }
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
            do {
                try await sendToAllDevices(self.userId!, syncMsg)
            } catch {
                logger.sessionEstablishFailed(userId: self.userId ?? "unknown", error: "sentSync: \(error)")
            }
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
            do {
                try await sendToAllDevices(self.userId!, syncMsg)
            } catch {
                logger.sessionEstablishFailed(userId: self.userId ?? "unknown", error: "friendSync: \(error)")
            }
        }
    }

    // MARK: - Internal: Prekey Replenishment (matches Kotlin pattern)

    private func checkAndReplenishPreKeys() {
        Task { [weak self] in
            guard let self = self,
                  let store = self.persistentSignalStore,
                  store.getPreKeyCount() < self.prekeyMinCount else { return }
            await self.replenishPreKeys()
        }
    }

    private func replenishPreKeys() async {
        guard let store = persistentSignalStore, let identity = identityKeyPair else { return }
        do {
            let highestId = store.getHighestPreKeyId()
            var newKeys: [PreKeyUpload] = []

            for i: UInt32 in 1...prekeyReplenishCount {
                let keyId = highestId + i
                let pk = PrivateKey.generate()
                newKeys.append(PreKeyUpload(
                    keyId: Int(keyId),
                    publicKey: Data(pk.publicKey.serialize()).base64EncodedString()
                ))
                try store.storePreKey(
                    PreKeyRecord(id: keyId, publicKey: pk.publicKey, privateKey: pk),
                    id: keyId, context: NullContext()
                )
            }

            // Reuse existing signed prekey — don't generate a new one
            let existingSpk = try store.loadSignedPreKey(id: 1, context: NullContext())

            try await api.uploadDeviceKeys(
                identityKey: Data(identity.publicKey.serialize()).base64EncodedString(),
                registrationId: Int(registrationId ?? 0),
                signedPreKey: SignedPreKeyUpload(
                    keyId: 1,
                    publicKey: Data(existingSpk.publicKey.serialize()).base64EncodedString(),
                    signature: Data(existingSpk.signature).base64EncodedString()
                ),
                oneTimePreKeys: newKeys
            )
        } catch {
            logger.sessionEstablishFailed(userId: userId ?? "unknown", error: "prekey replenish: \(error)")
        }
    }

    // MARK: - Internal: Token Refresh

    private func startTokenRefresh() {
        tokenRefreshTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                guard let self = self, let token = self.token else {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continue
                }

                let delayMs = self.getTokenRefreshDelay(token)
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)

                if let rt = self.refreshToken {
                    do {
                        let result = try await self.api.refreshSession(rt)
                        self.token = result.token
                        await self.api.setToken(result.token)
                        if let newRefresh = result.refreshToken {
                            self.refreshToken = newRefresh
                        }
                        consecutiveFailures = 0
                    } catch {
                        consecutiveFailures += 1
                        self.logger.tokenRefreshFailed(attempt: consecutiveFailures, error: "\(error)")
                        if consecutiveFailures >= 3 {
                            self._authState = .loggedOut
                            break
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

    /// Generate a fresh Signal identity keypair + registration ID. Stores on self.
    private func generateSignalIdentity() -> (IdentityKeyPair, UInt32) {
        let identity = IdentityKeyPair.generate()
        let regId = UInt32.random(in: 1...Self.maxRegistrationId)
        self.identityKeyPair = identity
        self.registrationId = regId
        return (identity, regId)
    }

    /// Generate a signed pre-key from the given identity.
    private func generateSignedPreKey(identity: IdentityKeyPair) -> (privateKey: PrivateKey, signature: [UInt8]) {
        let spkPrivate = PrivateKey.generate()
        let spkSig = identity.privateKey.generateSignature(message: spkPrivate.publicKey.serialize())
        return (spkPrivate, spkSig)
    }

    /// Generate one-time pre-keys for upload + local storage.
    private func generateOneTimePreKeys() -> (uploads: [PreKeyUpload], records: [(id: UInt32, privateKey: PrivateKey)]) {
        var uploads: [PreKeyUpload] = []
        var records: [(id: UInt32, privateKey: PrivateKey)] = []
        for i: UInt32 in 1...Self.initialPreKeyCount {
            let pk = PrivateKey.generate()
            uploads.append(PreKeyUpload(keyId: Int(i), publicKey: Data(pk.publicKey.serialize()).base64EncodedString()))
            records.append((id: i, privateKey: pk))
        }
        return (uploads, records)
    }

    /// Create and populate a PersistentSignalStore with identity + keys.
    private func initializeSignalStore(identity: IdentityKeyPair, regId: UInt32,
                                       spkPrivate: PrivateKey, spkSig: [UInt8],
                                       preKeyRecords: [(id: UInt32, privateKey: PrivateKey)]) throws -> PersistentSignalStore {
        let store = try sharedDb.map { try PersistentSignalStore(db: $0) } ?? PersistentSignalStore()
        store.logger = self.logger
        store.initialize(keyPair: identity, registrationId: regId)
        try store.storeSignedPreKey(
            SignedPreKeyRecord(id: Self.signedPreKeyId, timestamp: UInt64(Date().timeIntervalSince1970), privateKey: spkPrivate, signature: spkSig),
            id: Self.signedPreKeyId, context: NullContext()
        )
        for record in preKeyRecords {
            try store.storePreKey(
                PreKeyRecord(id: record.id, publicKey: record.privateKey.publicKey, privateKey: record.privateKey),
                id: record.id, context: NullContext()
            )
        }
        self.persistentSignalStore = store
        return store
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
