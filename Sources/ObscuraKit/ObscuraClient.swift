import Foundation
import GRDB
import LibSignalClient
import SwiftProtobuf
#if os(iOS)
import UIKit
#endif

// MARK: - Public Types

public enum ConnectionState: String, Sendable {
    case disconnected, connecting, connected, reconnecting
}

public enum AuthState: String, Sendable {
    case loggedOut, authenticated, pendingApproval
}

/// Result of a login attempt — tells the app what to do next.
public enum LoginScenario: Sendable {
    case existingDevice       // Known device, session restored. Call connect().
    case newDevice            // New device, needs link approval from existing device.
    case onlyDevice           // Lost local data but no other devices exist. Re-provision directly, no linking.
    case deviceMismatch       // DB exists but stored device doesn't match server. Re-provision needed.
    case invalidCredentials   // Wrong password.
    case userNotFound         // Username doesn't exist.
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

/// Result of `processPendingMessages(timeout:)` — counts of envelopes drained, by ORM model.
/// The bridge uses these to pick generic notification text. `otherCount` is debug-only; the
/// bridge ignores it. Shape is identical to Kotlin's `ProcessedCounts` so both platforms
/// implement the same notification logic.
public struct ProcessedCounts: Sendable {
    public let pixCount: Int
    public let messageCount: Int
    public let otherCount: Int

    public init(pixCount: Int = 0, messageCount: Int = 0, otherCount: Int = 0) {
        self.pixCount = pixCount
        self.messageCount = messageCount
        self.otherCount = otherCount
    }
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

    /// Session storage — kit persists session internally. Set before register/login.
    public var sessionStorage: SessionStorage?

    /// Attachment cache — decrypted bytes cached in the encrypted DB.
    private var attachmentCache: AttachmentCache?

    // MARK: - Observable State

    private var _connectionState: ConnectionState = .disconnected {
        didSet {
            if _connectionState != oldValue {
                for c in connectionContinuations { c.yield(_connectionState) }
            }
        }
    }
    private var _authState: AuthState = .loggedOut {
        didSet {
            if _authState != oldValue {
                for c in authContinuations { c.yield(_authState) }
                // Auto-persist session when authenticated
                if _authState == .authenticated { persistSession() }
            }
        }
    }

    private var connectionContinuations: [AsyncStream<ConnectionState>.Continuation] = []
    private var authContinuations: [AsyncStream<AuthState>.Continuation] = []

    /// Connection state — current value
    public var connectionState: ConnectionState { _connectionState }
    public var authState: AuthState { _authState }

    /// Observe connection state changes. Push-based, no polling.
    public func observeConnectionState() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(_connectionState)
            connectionContinuations.append(continuation)
            continuation.onTermination = { [weak self] _ in
                self?.connectionContinuations.removeAll { $0 as AnyObject === continuation as AnyObject }
            }
        }
    }

    /// Observe auth state changes. Push-based, no polling.
    public func observeAuthState() -> AsyncStream<AuthState> {
        AsyncStream { continuation in
            continuation.yield(_authState)
            authContinuations.append(continuation)
            continuation.onTermination = { [weak self] _ in
                self?.authContinuations.removeAll { $0 as AnyObject === continuation as AnyObject }
            }
        }
    }

    /// Buffered message queue for waitForMessage
    private var messageQueue: [ReceivedMessage] = []
    // messageWaiters removed — waitForMessage now polls messageQueue directly

    /// ORM sync manager — routes MODEL_SYNC messages to correct model.
    internal var _ormSyncManager: SyncManager?
    internal var _ormModels: [String: Model] = [:]
    internal var _ormTTLManager: TTLManager?

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
    private var reconnectTask: Task<Void, Never>?

    // Reconnection state (matches JS client)
    private var shouldReconnect = false
    private var reconnectAttempts = 0
    private static let reconnectDelayMs: UInt64 = 1_000
    private static let reconnectMaxDelayMs: UInt64 = 30_000
    private static let pingIntervalSeconds: TimeInterval = 30

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
    public init(apiURL: String, dataDirectory: String, userId: String? = nil, logger: ObscuraLogger = PrintLogger()) throws {
        self.logger = logger

        // Ensure directory exists with iOS Data Protection (encrypted at rest)
        try FileManager.default.createDirectory(
            atPath: dataDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let dbPath = (dataDirectory as NSString).appendingPathComponent("obscura.sqlite")

        // SQLCipher encryption: per-user key from Keychain
        var config = Configuration()
        if let userId = userId {
            let key = DatabaseSecret.getOrCreate(userId: userId)
            config.prepareDatabase { db in
                try db.usePassphrase(key)
                try db.execute(sql: "PRAGMA kdf_iter = 1") // key is already 256-bit entropy
                try db.execute(sql: "PRAGMA cipher_page_size = 4096")
            }
        }

        let db = try DatabaseQueue(path: dbPath, configuration: config)
        try db.write { db in try db.execute(sql: "PRAGMA secure_delete = ON") }

        // Set file protection on the DB file itself
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dbPath
        )
        self.sharedDb = db
        self.attachmentCache = try? AttachmentCache(db: db)

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
        gateway.disconnectSync()
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

    /// Lightweight account registration — API call only, no Signal keys or DB.
    /// Returns (token, refreshToken, userId) so the caller can create a user-scoped client.
    public static func registerAccount(_ username: String, _ password: String, apiURL: String = "https://obscura.barrelmaker.dev") async throws -> (token: String, refreshToken: String?, userId: String) {
        let api = APIClient(baseURL: apiURL)
        let result = try await api.registerUser(username, password)
        let userId = APIClient.extractUserId(result.token) ?? ""
        return (token: result.token, refreshToken: result.refreshToken, userId: userId)
    }

    /// Lightweight login — API call only, returns credentials.
    /// Pass deviceId to get a device-scoped token (required for messaging).
    public static func loginAccount(_ username: String, _ password: String, deviceId: String? = nil, apiURL: String = "https://obscura.barrelmaker.dev") async throws -> (token: String, refreshToken: String?, userId: String) {
        let api = APIClient(baseURL: apiURL)
        let result = try await api.loginWithDevice(username, password, deviceId: deviceId)
        let userId = APIClient.extractUserId(result.token) ?? ""
        return (token: result.token, refreshToken: result.refreshToken, userId: userId)
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

    /// Provision the current device with Signal keys. Requires token + userId already set.
    /// Used after registerAccount/loginAccount when the client was created with a user-scoped DB.
    public func provisionCurrentDevice(deviceName: String = "ObscuraKit-device") async throws {
        guard let _ = token, let userId = userId else {
            throw NSError(domain: "ObscuraKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "No auth token or userId set"])
        }
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
        self.deviceId = APIClient.extractDeviceId(deviceResult.token)
        await api.setToken(deviceResult.token)

        let store = try initializeSignalStore(identity: identity, regId: regId, spkPrivate: spkPrivate, spkSig: spkSig, preKeyRecords: preKeyRecords)
        self._messenger = MessengerActor(api: api, store: store, ownUserId: userId)
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

    /// Smart login — returns a scenario telling the app what to do next.
    /// File-backed clients: checks for existing DB + stored device identity.
    ///
    /// ```swift
    /// let scenario = try await client.loginSmart(username, password)
    /// switch scenario {
    /// case .existingDevice: try await client.connect()
    /// case .newDevice:      // show link code screen
    /// case .invalidCredentials: // show error
    /// }
    /// ```
    public func loginSmart(_ username: String, _ password: String) async throws -> LoginScenario {
        // Step 1: User-scoped login (no deviceId) to check credentials
        do {
            let result = try await api.loginWithDevice(username, password, deviceId: nil)
            self.token = result.token
            self.refreshToken = result.refreshToken
            self.userId = APIClient.extractUserId(result.token)
            self.username = username
            await api.setToken(result.token)
        } catch let error as APIClient.APIError {
            if error.status == 401 { return .invalidCredentials }
            if error.status == 404 { return .userNotFound }
            throw error
        }

        await rateLimitDelay()

        // Step 2: Check for existing device identity in local DB
        let storedIdentity = await devices.getIdentity()

        if let identity = storedIdentity, !identity.deviceId.isEmpty {
            // We have a stored device — try to login with it
            do {
                let deviceResult = try await api.loginWithDevice(username, password, deviceId: identity.deviceId)
                self.token = deviceResult.token
                self.refreshToken = deviceResult.refreshToken
                self.deviceId = identity.deviceId
                await api.setToken(deviceResult.token)

                // Restore messenger from persisted Signal store
                if let store = persistentSignalStore, store.hasPersistedIdentity {
                    self.identityKeyPair = try? store.identityKeyPair(context: NullContext())
                    self.registrationId = try? store.localRegistrationId(context: NullContext())
                    self._messenger = MessengerActor(api: api, store: store, ownUserId: self.userId!)
                    await _messenger?.mapDevice(identity.deviceId, userId: self.userId!, registrationId: self.registrationId ?? 0)
                }
                self._authState = .authenticated
                return .existingDevice
            } catch {
                // Device might have been revoked
                return .deviceMismatch
            }
        }

        // No local device identity. Check if user has other devices on the server.
        // If they have 0 or 1 device (the stale one), re-provision directly — no linking needed.
        // If they have 2+ devices, this is genuinely a new device that needs linking.
        await rateLimitDelay()
        let serverDevices = try await api.listDevices()
        if serverDevices.count <= 1 {
            // Only device (or no devices) — re-provision directly, no QR needed
            return .onlyDevice
        } else {
            // Multiple devices exist — need approval from an existing one
            self._authState = .pendingApproval
            return .newDevice
        }
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

    // MARK: - Connect (WebSocket + envelope loop + token refresh + auto-reconnect)

    public func connect() async throws {
        // Cancel any existing loops (but not reconnectTask — it called us)
        envelopeTask?.cancel()
        envelopeTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil

        shouldReconnect = true
        _connectionState = .connecting

        // Listen for PreKeyStatus frames from server
        await gateway.setOnPreKeyStatus { [weak self] count, threshold in
            if count < threshold {
                Task { [weak self] in await self?.replenishPreKeys() }
            }
        }

        // Ensure fresh token before connecting
        await ensureFreshToken()

        try await gateway.connect()
        _connectionState = .connected
        reconnectAttempts = 0
        persistSession() // save refreshed tokens on connect/reconnect
        logger.log("gateway connected (messenger: \(_messenger != nil))")
        startEnvelopeLoop()
        startTokenRefresh()
        startForegroundObserver()
    }

    /// Re-check connection when app returns to foreground.
    /// Matches JS client's visibilitychange handler.
    private func startForegroundObserver() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task {
                if self.shouldReconnect && self._connectionState != .connected {
                    self.logger.log("app foregrounded — reconnecting")
                    await self.ensureFreshToken()
                    try? await self.connect()
                }
            }
        }
        #endif
    }

    /// Intentional disconnect — stops reconnection.
    public func disconnect() {
        shouldReconnect = false
        envelopeTask?.cancel()
        envelopeTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        gateway.disconnectSync()
        _connectionState = .disconnected
        messageQueue.removeAll()
    }

    // MARK: - Push Notifications

    /// Register APNS/FCM push token with server. Requires device-scoped JWT.
    /// Safe to call multiple times — server upserts by deviceId.
    public func registerPushToken(_ token: String) async throws {
        try await api.registerPushToken(token)
    }

    /// Drain queued envelopes after a silent push wake. Connects if needed, waits up to `timeout`
    /// seconds (returning early when the queue stays empty for 500ms), categorizes by ORM model,
    /// and returns counts. Does NOT disconnect afterwards — the OS will freeze the app when done.
    ///
    /// The bridge layer uses the returned counts to post a generic local notification
    /// ("New pix" / "New message"). Kit must NEVER post OS notifications itself.
    public func processPendingMessages(timeout: TimeInterval) async -> ProcessedCounts {
        if _connectionState != .connected {
            do { try await connect() } catch { return ProcessedCounts() }
        }

        var pix = 0
        var message = 0
        var other = 0
        let deadline = Date().addingTimeInterval(timeout)
        let idleThreshold: TimeInterval = 0.5
        var lastEnvelopeAt = Date()

        while Date() < deadline {
            if !messageQueue.isEmpty {
                let received = messageQueue.removeFirst()
                classifyForPushCounts(received, pix: &pix, message: &message, other: &other)
                lastEnvelopeAt = Date()
            } else if Date().timeIntervalSince(lastEnvelopeAt) > idleThreshold {
                break
            } else {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        return ProcessedCounts(pixCount: pix, messageCount: message, otherCount: other)
    }

    private func classifyForPushCounts(
        _ msg: ReceivedMessage, pix: inout Int, message: inout Int, other: inout Int
    ) {
        // MODEL_SYNC (type 30) carries the ORM model name — the authoritative categorization.
        // Legacy TEXT/CONTENT_REFERENCE paths go to `other` since our app uses ORM exclusively.
        if msg.type == 30, let clientMsg = try? Obscura_V2_ClientMessage(serializedBytes: msg.rawBytes) {
            switch clientMsg.modelSync.model {
            case "pix":            pix += 1; return
            case "directMessage":  message += 1; return
            default:               break
            }
        }
        other += 1
    }

    /// Schedule auto-reconnect with exponential backoff.
    /// 1s → 2s → 4s → 8s → 16s → 30s cap. Matches JS client.
    private func scheduleReconnect() {
        guard shouldReconnect else { return }

        let delay = min(
            Self.reconnectDelayMs * (1 << UInt64(min(reconnectAttempts, 5))),
            Self.reconnectMaxDelayMs
        )
        reconnectAttempts += 1
        _connectionState = .reconnecting
        logger.log("reconnecting in \(delay)ms (attempt \(reconnectAttempts))")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            guard let self = self, self.shouldReconnect, !Task.isCancelled else { return }

            do {
                // Refresh token before reconnecting
                await self.ensureFreshToken()
                try await self.connect()
                self.logger.log("reconnected after \(self.reconnectAttempts) attempts")
            } catch {
                // connect() failed — onClose in envelope loop will schedule next attempt
                self.logger.log("reconnect failed: \(error.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }

    // MARK: - High-Level Operations

    /// Send a text message to an accepted friend. Throws if not friends.
    public func send(to friendUserId: String, _ text: String) async throws {
        _ = try requireMessenger()
        guard await friends.isFriend(friendUserId) else {
            throw ObscuraError.notFriends(friendUserId)
        }
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

    /// Send a friend request. Stores the target with their username so the UI can display it.
    public func befriend(_ targetUserId: String, username targetUsername: String) async throws {
        _ = try requireMessenger()

        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendRequest
        msg.username = username ?? ""
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        try await sendToAllDevices(targetUserId, msg)
        await friends.add(targetUserId, targetUsername, status: .pendingSent)

        try await sendFriendSync(username: targetUsername, action: "add", status: "pending_sent", userId: targetUserId)
    }

    /// Accept a friend request. Updates status to accepted.
    public func acceptFriend(_ targetUserId: String, username targetUsername: String) async throws {
        _ = try requireMessenger()

        var msg = Obscura_V2_ClientMessage()
        msg.type = .friendResponse
        msg.username = username ?? ""
        msg.accepted = true
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        try await sendToAllDevices(targetUserId, msg)
        await friends.updateStatus(targetUserId, .accepted)

        try await sendFriendSync(username: targetUsername, action: "add", status: "accepted", userId: targetUserId)
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

        // Delete the session that was just rebuilt to send the reset message.
        // Forces next send to use a fresh PreKey exchange, which the receiver
        // can handle after they also cleared their session.
        try? persistentSignalStore?.deleteAllSessions(for: targetUserId)
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

    /// Approve a device link request — fetch bundles, send DEVICE_LINK_APPROVAL, push history, announce.
    public func approveLink(newDeviceId: String, challengeResponse: Data) async throws {
        let messenger = try requireMessenger()
        guard let uid = userId else { throw ObscuraError.notAuthenticated }

        // Fetch prekey bundles so we can encrypt to the new device
        let bundles = try await messenger.fetchPreKeyBundles(uid)
        await rateLimitDelay()
        for bundle in bundles {
            do {
                try await messenger.processServerBundle(bundle, userId: uid)
            } catch {
                logger.sessionEstablishFailed(userId: uid, error: "\(error)")
            }
        }

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

    // MARK: - Device Linking (QR Code / Link Code)

    /// Generate a link code for this device. Display as QR code or copyable text.
    /// The new device calls this, the existing device scans/validates it.
    public func generateLinkCode() -> String? {
        guard let deviceId = deviceId,
              let identityKeyPair = identityKeyPair else { return nil }
        let deviceUUID = deviceId // Use deviceId as UUID for now
        return DeviceLink.generateLinkCode(
            deviceId: deviceId,
            deviceUUID: deviceUUID,
            signalIdentityKey: Data(identityKeyPair.publicKey.serialize())
        )
    }

    /// Validate a link code and approve the device link.
    /// The existing device calls this after scanning the QR code.
    /// Validates the code, then sends DEVICE_LINK_APPROVAL + SYNC_BLOB + DEVICE_ANNOUNCE.
    public func validateAndApproveLink(_ linkCodeString: String) async throws {
        let result = DeviceLink.validateLinkCode(linkCodeString)

        switch result {
        case .valid(let code):
            guard let challenge = DeviceLink.extractChallenge(code) else {
                throw ObscuraError.deviceLinkFailed("invalid challenge in link code")
            }

            // Fetch prekey bundles for the new device so we can encrypt to it
            let messenger = try requireMessenger()
            let bundles = try await messenger.fetchPreKeyBundles(userId!)
            await rateLimitDelay()

            // Find the bundle for the new device
            guard let newDeviceBundle = bundles.first(where: { $0.deviceId == code.deviceId }) else {
                throw ObscuraError.deviceLinkFailed("no prekey bundle for device \(code.deviceId)")
            }
            try await messenger.processServerBundle(newDeviceBundle, userId: userId!)

            // Add new device to own device list
            let newDevice = OwnDevice(deviceUUID: code.deviceUUID, deviceId: code.deviceId, deviceName: code.deviceId)
            await devices.addOwnDevice(newDevice)

            // Approve: send DEVICE_LINK_APPROVAL + SYNC_BLOB + announce
            try await approveLink(newDeviceId: code.deviceId, challengeResponse: challenge)

        case .expired:
            throw ObscuraError.deviceLinkFailed("link code expired")

        case .invalid(let reason):
            throw ObscuraError.deviceLinkFailed(reason)
        }
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

        // Clear all old sessions — identity key changed, old sessions are invalid.
        // Next send will do a fresh PreKey exchange with the new identity.
        for friend in await friends.getAccepted() {
            try? persistentSignalStore?.deleteAllSessions(for: friend.userId)
        }

        let store = try initializeSignalStore(identity: identity, regId: regId, spkPrivate: spkPrivate, spkSig: spkSig, preKeyRecords: preKeyRecords)
        self._messenger = MessengerActor(api: api, store: store, ownUserId: self.userId!)

        if let did = deviceId, let uid = userId {
            await _messenger?.mapDevice(did, userId: uid, registrationId: regId)
        }
    }

    // MARK: - Encrypted Attachments

    /// Encrypt plaintext, upload ciphertext, send CONTENT_REFERENCE to friend. Throws if not friends.
    public func sendEncryptedAttachment(to friendUserId: String, plaintext: Data, mimeType: String = "application/octet-stream") async throws {
        guard await friends.isFriend(friendUserId) else { throw ObscuraError.notFriends(friendUserId) }
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
    /// Checks in-DB cache first — returns instantly on hit.
    public func downloadDecryptedAttachment(id: String, contentKey: Data, nonce: Data, expectedHash: Data? = nil) async throws -> Data {
        // Cache hit — return immediately, zero network
        if let cached = await attachmentCache?.get(id) {
            return cached
        }
        // Cache miss — fetch, decrypt, cache
        let ciphertext = try await api.fetchAttachment(id)
        let plaintext = try AttachmentCrypto.decrypt(ciphertext, contentKey: contentKey, nonce: nonce, expectedHash: expectedHash)
        await attachmentCache?.put(id, plaintext: plaintext)
        return plaintext
    }

    /// Send a CONTENT_REFERENCE message to a friend (attachment already uploaded). Throws if not friends.
    public func sendAttachment(to friendUserId: String, attachmentId: String, contentKey: Data, nonce: Data, mimeType: String, sizeBytes: Int) async throws {
        guard await friends.isFriend(friendUserId) else { throw ObscuraError.notFriends(friendUserId) }
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

    /// Send a MODEL_SYNC message to a friend. Throws if not friends.
    public func sendModelSync(to friendUserId: String, model: String, entryId: String, op: String = "CREATE", data: Data) async throws {
        guard await friends.isFriend(friendUserId) else { throw ObscuraError.notFriends(friendUserId) }
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

    /// SyncManager-friendly overload with all fields.
    public func sendModelSync(to friendUserId: String? = nil, toSelf: Bool = false, model: String, entryId: String, op: String = "CREATE", data: Data, timestamp: UInt64 = 0, authorDeviceId: String = "", signature: Data = Data()) async throws {
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
        sync.timestamp = timestamp != 0 ? timestamp : UInt64(Date().timeIntervalSince1970 * 1000)
        sync.data = data
        sync.authorDeviceID = authorDeviceId.isEmpty ? (deviceId ?? "") : authorDeviceId
        sync.signature = signature

        var msg = Obscura_V2_ClientMessage()
        msg.type = .modelSync
        msg.modelSync = sync

        if let targetUserId = friendUserId {
            guard await friends.isFriend(targetUserId) else { throw ObscuraError.notFriends(targetUserId) }
            try await sendToAllDevices(targetUserId, msg)
        }

        if toSelf {
            // Self-sync: send to all own devices except this one
            let messenger = try requireMessenger()
            guard let uid = userId else { throw ObscuraError.notAuthenticated }
            let ownDevices = await devices.getOwnDevices()
            let msgData = try msg.serializedData()

            for device in ownDevices where device.deviceId != self.deviceId {
                do {
                    try await messenger.queueMessage(targetDeviceId: device.deviceId, clientMessageData: msgData, targetUserId: uid)
                } catch {
                    logger.log("self-sync failed for device \(device.deviceId): \(error)")
                }
            }
            if !ownDevices.filter({ $0.deviceId != self.deviceId }).isEmpty {
                _ = try await messenger.flushMessages()
            }
        }
    }

    // MARK: - ORM Schema

    /// Define ORM models. Call once after login, before connect.
    /// Attaches models to client as `client.model("story")` etc.
    public func schema(_ definitions: [ModelDefinition]) {
        let store: ModelStore
        if let db = sharedDb {
            store = (try? ModelStore(db: db)) ?? (try! ModelStore())
        } else {
            store = (try? ModelStore()) ?? (try! ModelStore())
        }

        let syncManager = SyncManager(client: self)
        let ttlManager = TTLManager(store: store)

        for def in definitions {
            let model = Model(name: def.name, definition: def, store: store)
            model.deviceId = self.deviceId ?? ""
            model.username = self.username ?? ""
            model.ttlManager = ttlManager
            syncManager.register(def.name, model)
            _ormModels[def.name] = model
        }

        ttlManager.setModelResolver { [weak self] name in self?._ormModels[name] }
        _ormSyncManager = syncManager
        _ormTTLManager = ttlManager
    }

    /// Define models from typed SyncModel types. Call once after auth, like a Rails migration.
    ///
    /// ```swift
    /// client.defineModels(DirectMessage.self, Story.self, Profile.self, AppSettings.self)
    /// ```
    public func defineModels(_ types: any SyncModel.Type...) {
        let definitions = types.map { type in
            ModelDefinition(
                name: type.modelName,
                sync: type.sync,
                syncScope: type.scope,
                ttl: type.ttl
            )
        }
        schema(definitions)
    }

    /// Access a registered ORM model by name.
    public func model(_ name: String) -> Model? {
        _ormModels[name]
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

    // MARK: - Facade (high-level methods for thin bridges)

    /// Typed event for the unified event stream.
    public enum ObscuraEvent {
        case friendsUpdated([Friend])
        case connectionChanged(ConnectionState)
        case authChanged(AuthState)
        case messageReceived(model: String, entryId: String)
        case typingChanged(conversationId: String, typers: [String])
        case debugLog(String)
    }

    /// Unified event stream — bridge subscribes once and relays all events.
    public func observeEvents() -> AsyncStream<ObscuraEvent> {
        AsyncStream { continuation in
            // Friends
            let friendTask = Task {
                for await allFriends in friends.observeAll().values {
                    continuation.yield(.friendsUpdated(allFriends))
                }
            }
            // Connection
            let connTask = Task {
                for await state in observeConnectionState() {
                    continuation.yield(.connectionChanged(state))
                }
            }
            // Auth
            let authTask = Task {
                for await state in observeAuthState() {
                    continuation.yield(.authChanged(state))
                }
            }
            // Incoming messages
            let msgTask = Task {
                for await event in events() {
                    if event.type == 30 { // MODEL_SYNC
                        continuation.yield(.messageReceived(model: "directMessage", entryId: ""))
                    }
                }
            }

            continuation.onTermination = { _ in
                friendTask.cancel()
                connTask.cancel()
                authTask.cancel()
                msgTask.cancel()
            }
        }
    }

    /// Parse schema JSON from JS and define ORM models. Caches for cold start.
    public func defineModelsFromJson(_ jsonString: String) throws {
        guard let data = jsonString.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw ObscuraError.provisionFailed("Invalid schema JSON")
        }

        var definitions: [ModelDefinition] = []
        for (name, config) in schema {
            let syncStr = config["sync"] as? String ?? "gset"
            let sync: SyncStrategy = syncStr == "lww" ? .lwwMap : .gset
            let isPrivate = config["private"] as? Bool ?? false
            let scope: SyncScope = isPrivate ? .ownDevices : .friends

            var ttl: TTL? = nil
            if let ttlStr = config["ttl"] as? String {
                ttl = parseTTLString(ttlStr)
            }

            var fields: [String: FieldType] = [:]
            if let fieldMap = config["fields"] as? [String: String] {
                for (fieldName, fieldType) in fieldMap {
                    switch fieldType {
                    case "string": fields[fieldName] = .string
                    case "number": fields[fieldName] = .number
                    case "boolean": fields[fieldName] = .boolean
                    case "string?": fields[fieldName] = .optionalString
                    case "number?": fields[fieldName] = .optionalNumber
                    case "boolean?": fields[fieldName] = .optionalBoolean
                    default: fields[fieldName] = .string
                    }
                }
            }

            definitions.append(ModelDefinition(name: name, sync: sync, syncScope: scope, ttl: ttl, fields: fields, isPrivate: isPrivate))
        }

        self.schema(definitions)

        // Cache for cold start
        sessionStorage?.save(["cachedSchema": jsonString])
        logger.log("models defined from JSON (\(definitions.count) models)")
    }

    private func parseTTLString(_ str: String) -> TTL? {
        guard str.count >= 2, let value = Int(str.dropLast()) else { return nil }
        switch str.last {
        case "s": return .seconds(value)
        case "m": return .minutes(value)
        case "h": return .hours(value)
        case "d": return .days(value)
        default: return nil
        }
    }

    /// Decode a friend code and send a friend request.
    public func addFriendByCode(_ code: String) async throws {
        let cleaned = code.replacingOccurrences(of: "\u{00AD}", with: "")
        let decoded = try FriendCode.decode(cleaned)
        try await befriend(decoded.userId, username: decoded.username)
    }

    /// Generate a shareable friend code for this user.
    public func friendCode() -> String? {
        guard let userId = userId, let username = username else { return nil }
        return FriendCode.encode(userId: userId, username: username)
    }

    /// Full logout — handles ALL teardown. Bridge calls this one method.
    public func fullLogout() async {
        // Cancel all background tasks
        envelopeTask?.cancel()
        envelopeTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        shouldReconnect = false

        // Disconnect
        gateway.disconnectSync()

        // Clear auth state
        try? await api.clearToken()
        token = nil
        refreshToken = nil
        userId = nil
        username = nil
        deviceId = nil
        _messenger = nil
        _connectionState = .disconnected
        _authState = .loggedOut
        _ormModels.removeAll()
        _ormSyncManager = nil
        _ormTTLManager = nil
        messageQueue.removeAll()

        // Clear persisted session
        sessionStorage?.clear()
        Task { await attachmentCache?.clearAll() }
        logger.log("full logout complete")
    }

    /// Persist current session. Called internally after register, login, connect, reconnect.
    public func persistSession() {
        guard let token = token, let userId = userId else { return }
        var data: [String: Any] = [
            "token": token,
            "refreshToken": refreshToken ?? "",
            "userId": userId,
            "deviceId": deviceId ?? "",
            "username": username ?? "",
            "registrationId": registrationId ?? 0,
        ]
        // Include cached schema if available
        if let existing = sessionStorage?.load(), let cached = existing["cachedSchema"] as? String {
            data["cachedSchema"] = cached
        }
        sessionStorage?.save(data)
    }

    /// Restore session from storage, define cached models, connect.
    public func restorePersistedSession() async throws {
        guard let storage = sessionStorage, let saved = storage.load(),
              let token = saved["token"] as? String, !token.isEmpty,
              let userId = saved["userId"] as? String, !userId.isEmpty else {
            throw ObscuraError.notAuthenticated
        }

        let regId = UInt32(saved["registrationId"] as? Int ?? 0)
        await restoreSession(
            token: token,
            refreshToken: saved["refreshToken"] as? String,
            userId: userId,
            deviceId: saved["deviceId"] as? String,
            username: saved["username"] as? String,
            registrationId: regId
        )

        // Define models from cached schema
        if let cachedSchema = saved["cachedSchema"] as? String {
            try? defineModelsFromJson(cachedSchema)
        }

        // Refresh token and connect
        let fresh = await ensureFreshToken()
        guard fresh else {
            storage.clear()
            throw ObscuraError.notAuthenticated
        }

        try await connect()
        persistSession() // save refreshed tokens
        logger.log("session restored from storage")
    }

    // MARK: - Recovery (Optional)
    //
    // BIP39 recovery is opt-in. If you never call generateRecoveryPhrase(), everything
    // works without it — device linking, messaging, sync. The only features that require
    // a recovery phrase are:
    //   - revokeDevice() — remote device revocation with signed proof
    //   - announceRecovery() — signed device announcements
    // Without a recovery phrase, device revocation requires physical access to a linked device.
    //
    // Device announce signature verification is automatic: if the sender has a recovery
    // public key stored, announcements are verified. If not, they're accepted on trust.

    /// Generate a 12-word recovery phrase. Store it securely.
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
        let bundles = try await messenger.fetchPreKeyBundles(targetUserId)
        await rateLimitDelay()

        let msgData = try msg.serializedData()
        for bundle in bundles {
            do {
                try await messenger.processServerBundle(bundle, userId: targetUserId)
            } catch {
                logger.sessionEstablishFailed(userId: targetUserId, error: "\(error)")
                continue
            }
            let targetDeviceId = bundle.deviceId
            try await messenger.queueMessage(targetDeviceId: targetDeviceId, clientMessageData: msgData, targetUserId: targetUserId)
        }
        let result = try await messenger.flushMessages()
        _ = result
    }

    // MARK: - Internal: Envelope Loop

    private func startEnvelopeLoop() {
        envelopeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                do {
                    let raw = try await self.gateway.waitForRawEnvelope(timeout: 30)
                    await self.processEnvelope(raw)
                } catch {
                    if Task.isCancelled { break }
                    if error is CancellationError { break }
                    if let gwError = error as? GatewayConnection.GatewayError {
                        if case .timeout = gwError { continue } // Normal idle timeout, keep looping
                        if case .notConnected = gwError {
                            // Connection dropped — trigger reconnect
                            self._connectionState = .disconnected
                            self.logger.log("gateway disconnected, scheduling reconnect")
                            self.scheduleReconnect()
                            break
                        }
                    }
                    // Unknown error — also trigger reconnect
                    self._connectionState = .disconnected
                    self.logger.log("envelope loop error: \(error.localizedDescription)")
                    self.scheduleReconnect()
                    break
                }
            }
        }
    }

    private func processEnvelope(_ raw: (id: Data, senderID: Data, timestamp: UInt64, message: Data)) async {
        guard let messenger = _messenger else { return }

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
                try await gateway.acknowledge([raw.id])
            } catch {
                logger.ackFailed(envelopeId: raw.id.map { String(format: "%02x", $0) }.joined(), error: "\(error)")
            }
        } catch {
            let entry = decryptFailures[sourceUserId] ?? (count: 0, windowStart: Date())
            decryptFailures[sourceUserId] = (count: entry.count + 1, windowStart: entry.windowStart)
            logger.decryptFailed(sourceUserId: sourceUserId, error: "\(error)")
        }
    }

    // MARK: - Internal: Message Routing

    private func routeMessage(_ msg: Obscura_V2_ClientMessage, sourceUserId: String) async {
        NSLog("[ObscuraKit] routeMessage type=%d from=%@", msg.type.rawValue, String(sourceUserId.prefix(8)))
        switch msg.type {
        case .friendRequest:
            await friends.add(sourceUserId, msg.username, status: .pendingReceived)

        case .friendResponse:
            if msg.accepted {
                await friends.add(sourceUserId, msg.username, status: .accepted)
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
            // Clear all typing indicators — a real message arrived
            await SignalStoreRegistry.shared.store.clearAll()
            SignalStoreRegistry.shared.notifyObservers()

            if let syncManager = _ormSyncManager {
                let syncMsg = ModelSyncMessage(
                    model: msg.modelSync.model,
                    id: msg.modelSync.id,
                    op: msg.modelSync.op == .delete ? "DELETE" : (msg.modelSync.op == .update ? "UPDATE" : "CREATE"),
                    timestamp: msg.modelSync.timestamp,
                    data: msg.modelSync.data,
                    signature: msg.modelSync.signature,
                    authorDeviceId: msg.modelSync.authorDeviceID
                )
                _ = await syncManager.handleIncoming(syncMsg, sourceUserId: sourceUserId)
            }

        case .modelSignal:
            // Ephemeral signal — don't persist, don't CRDT merge
            NSLog("[ObscuraKit] MODEL_SIGNAL received text=%@", String(msg.text.prefix(200)))
            if let payloadData = msg.text.data(using: .utf8),
               let payload = try? JSONDecoder().decode(ModelSignalPayload.self, from: payloadData) {
                NSLog("[ObscuraKit] MODEL_SIGNAL decoded model=%@ signal=%@", payload.model, payload.signal)
                // Always store as "typing" — let auto-expire handle cleanup.
                // stoppedTyping just means don't refresh the timer.
                if payload.signal != SignalType.stoppedTyping.rawValue {
                    await SignalStoreRegistry.shared.store.receive(payload)
                    SignalStoreRegistry.shared.notifyObservers()
                }
            } else {
                NSLog("[ObscuraKit] MODEL_SIGNAL decode FAILED text=%@", String(msg.text.prefix(300)))
                if let payloadData = msg.text.data(using: .utf8) {
                    do {
                        _ = try JSONDecoder().decode(ModelSignalPayload.self, from: payloadData)
                    } catch {
                        NSLog("[ObscuraKit] MODEL_SIGNAL decode error: %@", "\(error)")
                    }
                }
            }

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
            try? persistentSignalStore?.deleteAllSessions(for: sourceUserId)

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
        case notFriends(String)
        case deviceLinkFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken: return "No token in server response"
            case .notAuthenticated: return "Not authenticated"
            case .provisionFailed(let msg): return "Device provisioning failed: \(msg)"
            case .noMessenger: return "Messenger not initialized (call register first)"
            case .noMessage: return "No message received"
            case .timeout: return "Operation timed out"
            case .notFriends(let userId): return "Not friends with \(userId)"
            case .deviceLinkFailed(let reason): return "Device link failed: \(reason)"
            }
        }
    }
}
