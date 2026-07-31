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
    public let type: String  // app-facing message kind, e.g. "MODEL_SYNC"; "" if unset
    public let text: String
    public let username: String
    public let accepted: Bool
    public let sourceUserId: String
    public let senderDeviceId: String?
    public let timestamp: UInt64
    public let rawBytes: Data
    /// For MODEL_SYNC messages: the affected model name (e.g. "story", "profile").
    /// nil for non-sync message types. Lets the bridge emit a model-accurate
    /// `messageReceived` event instead of hardcoding "directMessage".
    public let model: String?
}

/// Result of `processPendingMessages(timeout:)` — counts of envelopes drained, keyed by model.
/// The bridge uses these to pick generic notification text. `otherCount` is debug-only; the
/// bridge ignores it.
///
/// - Warning: This type hard-codes the application's model names (`"pix"`, `"directMessage"`)
///   in `classifyForPushCounts`, which the kit boundary forbids — a kit must treat a model name
///   as an opaque key (obscura-proto `SPEC.md` §0.4). The fix is counts keyed on the opaque model
///   name, with notification copy supplied by the app; it is a follow-up because it changes the
///   bridge contract on both platforms at once, and it is deliberately NOT bundled with the ORM
///   deletion, which changes no bridge-facing type.
///
///   A previous version of this warning claimed Kotlin had already "moved to a generic
///   `modelCounts` map", making the two kits divergent. **That was false when written and is false
///   now** — `ObscuraKit-Kotlin`'s `ProcessedCounts` still carries the same three Ints and the same
///   two hard-coded names. Both kits are wrong in the same way, which is the only good news here.
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

    /// The durable inbox (`obscura-proto/KIT_API.md` §3) — the thin kit's receive API, and now the
    /// only place an inbound MODEL_SYNC lands.
    ///
    /// It ran ALONGSIDE the ORM through §10 steps 2–3, so that obscura-pix had somewhere to move to
    /// before the old surface went away; the cost was that every MODEL_SYNC was persisted twice, once
    /// as a model entry and once as an inbox row. §10 step 4 ended that — the ORM is gone and the
    /// double write with it.
    public let inbox: InboxStore

    /// Raw storage for application entries (`obscura-proto/KIT_API.md` §8.1) — the other half of the
    /// thin kit's app-facing surface. `inbox` is how messages arrive; this is where the app keeps
    /// what it made of them.
    ///
    /// It stores and returns rows. It does not merge them, expire them, or decide who they go to —
    /// the app owns all three (`obscura-proto/SPEC.md` §0.4).
    public let entries: EntryStore

    // Messenger is initialized after register/login with real keys
    private var _messenger: MessengerActor?
    public private(set) var persistentSignalStore: PersistentSignalStore?

    /// Security logger — set your own implementation or use the default PrintLogger.
    public var logger: ObscuraLogger = PrintLogger()

    /// Session storage — kit persists session internally. Set before register/login.
    public var sessionStorage: SessionStorage?

    /// Fired whenever the access/refresh token is rotated by a refresh, so the
    /// host can re-persist the session. Refresh tokens are single-use — without
    /// re-persisting, a restored session uses a consumed refresh token and gets
    /// a 401 (broadcasts fail, reconnect fails). See `refreshTokenNow()`.
    public var onSessionChanged: (() -> Void)?

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

    private var authFailedContinuations: [AsyncStream<String>.Continuation] = []

    /// Observe hard auth failures (token refresh exhausted its retry budget).
    /// Distinct from `observeAuthState` going to `.loggedOut`: this is an event,
    /// not a state, and carries a reason. Does not replay — only fires live.
    public func observeAuthFailed() -> AsyncStream<String> {
        AsyncStream { continuation in
            authFailedContinuations.append(continuation)
            continuation.onTermination = { [weak self] _ in
                self?.authFailedContinuations.removeAll { $0 as AnyObject === continuation as AnyObject }
            }
        }
    }

    private func emitAuthFailed(_ reason: String) {
        for c in authFailedContinuations { c.yield(reason) }
    }

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
    private var reconnectTask: Task<Void, Never>?

    // In-flight refresh dedup — see refreshTokenNow(). Lock-guarded because
    // callers arrive from multiple concurrent tasks.
    private let refreshLock = NSLock()
    private var refreshInFlight: Task<Bool, Error>?

    // Reconnection state (matches JS client)
    private var shouldReconnect = false
    private var reconnectAttempts = 0
    private static let reconnectDelayMs: UInt64 = 1_000
    private static let reconnectMaxDelayMs: UInt64 = 30_000
    /// F10: backoff between the two connect attempts in `processPendingMessages`. Short on purpose —
    /// the push path runs inside a tight OS budget (an NSE gets ~30s), so a retry costing seconds
    /// would be worse than no retry at all. Matches ObscuraKit-Kotlin's 250ms.
    private static let pushDrainReconnectRetryNanos: UInt64 = 250_000_000
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
        self.inbox = try InboxStore(onDiscard: Self.discardLogger(logger))
        self.entries = try EntryStore()
        self.gateway = GatewayConnection(api: api, logger: logger)
    }

    /// File-backed client (production). All state persists to `dataDirectory/obscura.sqlite`.
    /// On init, restores Signal identity from DB if one exists.
    /// - Parameter keychainAccessGroup: shared keychain access group for the SQLCipher key. Pass
    ///   `nil` (default) for today's behaviour. Required if a Notification Service Extension must
    ///   open this database — see `obscura-proto/KIT_API.md` P2, and note the extension also needs
    ///   `dataDirectory` to be an App Group container path, which is the caller's to supply.
    public init(apiURL: String, dataDirectory: String, userId: String? = nil,
                keychainAccessGroup: String? = nil, logger: ObscuraLogger = PrintLogger()) throws {
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
            let key = DatabaseSecret.getOrCreate(userId: userId, accessGroup: keychainAccessGroup)
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
        self.inbox = try InboxStore(db: db, onDiscard: Self.discardLogger(logger))
        self.entries = try EntryStore(db: db)
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
        do {
            return try await refreshTokenNow()
        } catch {
            if Self.isCancellation(error) { return false }
            logger.tokenRefreshFailed(attempt: 1, error: "\(error)")
            return false
        }
    }

    /// Refresh the access token using the (single-use) refresh token, update
    /// both tokens, and fire `onSessionChanged` so the host can re-persist the
    /// rotated refresh token. Returns false if there's no refresh token; throws
    /// on API failure. Shared by `ensureFreshToken()` and the background
    /// refresh loop so persistence-on-rotation happens on every path.
    ///
    /// Concurrent callers (background loop, reconnect, broadcast path) share a
    /// single in-flight refresh — the refresh token is single-use, so two racing
    /// refreshes mean the loser POSTs an already-consumed token and gets a 401.
    /// Mirrors Kotlin's `refreshInProgress`. The refresh runs in its own Task,
    /// so cancelling a caller mid-refresh doesn't tear down the HTTP request.
    @discardableResult
    internal func refreshTokenNow() async throws -> Bool {
        return try await dedupedRefreshTask().value
    }

    /// Synchronous (lock-guarded) join-or-start for the shared refresh task.
    private func dedupedRefreshTask() -> Task<Bool, Error> {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        if let existing = refreshInFlight { return existing }
        let task = Task { [weak self] () throws -> Bool in
            guard let self = self else { return false }
            defer { self.clearRefreshInFlight() }
            guard let rt = self.refreshToken else { return false }
            let result = try await self.api.refreshSession(rt)
            self.token = result.token
            await self.api.setToken(result.token)
            if let newRT = result.refreshToken { self.refreshToken = newRT }
            self.onSessionChanged?()
            return true
        }
        refreshInFlight = task
        return task
    }

    private func clearRefreshInFlight() {
        refreshLock.lock()
        refreshInFlight = nil
        refreshLock.unlock()
    }

    /// True when the error is a task/URLSession cancellation rather than a server
    /// rejection. Reconnect cancels in-flight loops mid-request; that must not
    /// be logged as a refresh failure or count toward the 3-strike logout.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
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
        // Use the DEVICE provision's refresh token, not the user-scoped one from
        // registerUser above — refreshing a user-scoped token drops device scope
        // and 403s the gateway. (Matches Kotlin `session.refreshToken = provResult.refreshToken`.)
        self.refreshToken = deviceResult.refreshToken
        self.deviceId = APIClient.extractDeviceId(deviceToken)
        await api.setToken(deviceToken)

        // 4. Persistent Signal protocol store (survives app restart)
        let store = try initializeSignalStore(identity: identity, regId: regId, spkPrivate: spkPrivate, spkSig: spkSig, preKeyRecords: preKeyRecords)

        // 5. Messenger
        self._messenger = MessengerActor(api: api, store: store, ownUserId: self.userId!)

        // F9: record THIS device in the own-device registry so approveLink / DeviceAnnounce ship a
        // real device list. Without this the registry stays empty, every DeviceAnnounce is inert,
        // and a friend's device list is always empty (which is what masks F1 today).
        await recordOwnDevice(deviceName: "ObscuraKit-device",
                              signalIdentityKey: Data(identity.publicKey.serialize()), registrationId: regId)

        self._authState = .authenticated
    }

    /// F9: record THIS device in the own-device registry. deviceUUID == deviceId by the kit's
    /// convention (see generateLinkCode / validateAndApproveLink). Idempotent (INSERT OR REPLACE).
    /// Mirrors Kotlin AuthManager.addOwnDevice(OwnDeviceData(...)) on register/loginAndProvision.
    private func recordOwnDevice(deviceName: String, signalIdentityKey: Data, registrationId: UInt32) async {
        guard let did = self.deviceId else { return }
        var device = OwnDevice(deviceUUID: did, deviceId: did, deviceName: deviceName)
        device.signalIdentityKey = signalIdentityKey
        device.registrationId = registrationId
        await devices.addOwnDevice(device)
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
        // Device-scoped refresh token (was left as the user-scoped one from the
        // preceding registerAccount/loginAccount) — see register() for why.
        self.refreshToken = deviceResult.refreshToken
        self.deviceId = APIClient.extractDeviceId(deviceResult.token)
        await api.setToken(deviceResult.token)

        let store = try initializeSignalStore(identity: identity, regId: regId, spkPrivate: spkPrivate, spkSig: spkSig, preKeyRecords: preKeyRecords)
        self._messenger = MessengerActor(api: api, store: store, ownUserId: userId)

        // F9: record THIS device in the own-device registry (see recordOwnDevice / register()).
        await recordOwnDevice(deviceName: deviceName,
                              signalIdentityKey: Data(identity.publicKey.serialize()), registrationId: regId)

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
        let storedIdentity = await devices.getIdentity()

        // Device-first (Android parity): if a local device exists, log in with it
        // directly — a SINGLE device-scoped session, with no user-scoped login
        // churned alongside it. The old user-scoped-first order left a competing
        // user session so refreshes drifted to user-scoped → 403 on the gateway.
        if let identity = storedIdentity, !identity.deviceId.isEmpty {
            do {
                let deviceResult = try await api.loginWithDevice(username, password, deviceId: identity.deviceId)
                self.token = deviceResult.token
                self.refreshToken = deviceResult.refreshToken
                self.userId = APIClient.extractUserId(deviceResult.token)
                self.deviceId = identity.deviceId
                self.username = username
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
            } catch let error as APIClient.APIError {
                // 404 → no such user. 401/403 → wrong password OR the device was
                // revoked; fall through to a user-scoped login to distinguish.
                if error.status == 404 { return .userNotFound }
                if error.status != 401 && error.status != 403 { throw error }
                await rateLimitDelay()
            }
        }

        // No local device (or the device login was rejected) — user-scoped login
        // to verify credentials and decide the scenario.
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

        // Credentials valid. A local device that got rejected above means it was
        // revoked → mismatch. Otherwise decide by the server's device count.
        if let identity = storedIdentity, !identity.deviceId.isEmpty {
            return .deviceMismatch
        }

        await rateLimitDelay()
        let serverDevices = try await api.listDevices()
        if serverDevices.count <= 1 {
            // Only device (or none) — re-provision directly, no linking needed.
            return .onlyDevice
        } else {
            // Multiple devices exist — need approval from an existing one.
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

        // F9: record THIS (as-yet-unapproved) device so it knows itself. The approving device ships
        // the full account device list, which reconciles this on approval. Mirrors Kotlin
        // AuthManager.loginAndProvision's addOwnDevice.
        await recordOwnDevice(deviceName: deviceName,
                              signalIdentityKey: Data(identity.publicKey.serialize()), registrationId: regId)

        _authState = .authenticated
        await rateLimitDelay()
    }

    // MARK: - Connect (WebSocket + envelope loop + token refresh + auto-reconnect)

    public func connect() async throws {
        // DEBUG (flap diagnosis): trace overlapping connect() calls — two of these
        // close together means foreground observer / reconnect / broadcast raced.
        logger.log("[client] connect() begin state=\(_connectionState)")
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
    /// seconds (returning early when the queue stays empty for 500ms), categorizes by model,
    /// and returns counts. Does NOT disconnect afterwards — the OS will freeze the app when done.
    ///
    /// The bridge layer uses the returned counts to post a generic local notification
    /// ("New pix" / "New message"). Kit must NEVER post OS notifications itself.
    public func processPendingMessages(timeout: TimeInterval) async -> ProcessedCounts {
        logger.log("[push] drain start (timeout=\(Int(timeout))s, connected=\(_connectionState == .connected))")
        if _connectionState != .connected {
            // F10 (obscura-proto/PLAN.md). A failed connect returns all-zero counts, which is
            // indistinguishable from "connected fine, nothing waiting" — on the PUSH-WAKE path that
            // means: woken by a push, silently report no messages, leave them on the server. This
            // kit at least logged it; ObscuraKit-Kotlin swallowed it entirely, where it showed up as
            // a ~25% flaky PushTests. The connect failure was transient in every observed case
            // (measured in Kotlin: the retry fired in 3 of 8 runs and recovered every time), so
            // retry once before giving up.
            //
            // The backoff is deliberately short: an NSE has roughly 30 seconds total, so a retry
            // costing seconds would be worse than no retry. The zero-count return is unchanged —
            // making it distinguishable from "could not connect" is a Phase 4 API decision.
            do { try await connect() } catch {
                logger.log("[push] connect failed (attempt 1/2): \(error)")
                try? await Task.sleep(nanoseconds: Self.pushDrainReconnectRetryNanos)
                do { try await connect() } catch {
                    logger.log("[push] drain ABORTED — could not connect after 2 attempts: \(error)")
                    return ProcessedCounts()
                }
            }
        }

        var pix = 0
        var message = 0
        var other = 0
        var drained = 0
        let deadline = Date().addingTimeInterval(timeout)
        let idleThreshold: TimeInterval = 0.5
        var lastEnvelopeAt = Date()

        while Date() < deadline {
            if !messageQueue.isEmpty {
                let received = messageQueue.removeFirst()
                classifyForPushCounts(received, pix: &pix, message: &message, other: &other)
                drained += 1
                logger.log("[push] drained #\(drained) type=\(received.type) → pix=\(pix) msg=\(message) other=\(other)")
                lastEnvelopeAt = Date()
            } else if Date().timeIntervalSince(lastEnvelopeAt) > idleThreshold {
                break
            } else {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        logger.log("[push] drain done: pix=\(pix) msg=\(message) other=\(other)")
        return ProcessedCounts(pixCount: pix, messageCount: message, otherCount: other)
    }

    private func classifyForPushCounts(
        _ msg: ReceivedMessage, pix: inout Int, message: inout Int, other: inout Int
    ) {
        // MODEL_SYNC (type 30) carries the model name straight off the proto — no schema needed,
        // which is why the push path never depended on the engine that was deleted. Legacy
        // TEXT/CONTENT_REFERENCE paths go to `other`; the app sends neither.
        if msg.type == "MODEL_SYNC", let clientMsg = try? Obscura_Client_V1_ClientMessage(serializedBytes: msg.rawBytes) {
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

        var msg = Obscura_Client_V1_ClientMessage()
        msg.text.text = text
        msg.timestamp = timestamp

        try await sendToAllDevices(friendUserId, msg)

        // Persist locally
        try await messages.add(friendUserId, Message(messageId: messageId, conversationId: friendUserId, timestamp: timestamp, content: text, isSent: true))

        // SENT_SYNC to own devices
        try await sendSentSync(conversationId: friendUserId, messageId: messageId, timestamp: timestamp, content: text)
    }

    /// Send a friend request. Stores the target with their username so the UI can display it.
    public func befriend(_ targetUserId: String, username targetUsername: String) async throws {
        _ = try requireMessenger()

        var msg = Obscura_Client_V1_ClientMessage()
        msg.friendRequest.username = username ?? ""
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        try await sendToAllDevices(targetUserId, msg)
        try await friends.add(targetUserId, targetUsername, status: .pendingSent)

        try await sendFriendSync(username: targetUsername, action: "add", status: "pending_sent", userId: targetUserId)
    }

    /// Accept a friend request. Updates status to accepted.
    public func acceptFriend(_ targetUserId: String, username targetUsername: String) async throws {
        _ = try requireMessenger()

        var msg = Obscura_Client_V1_ClientMessage()
        msg.friendResponse.username = username ?? ""
        msg.friendResponse.accepted = true
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
        var announce = Obscura_Client_V1_DeviceAnnounce()
        announce.devices = ownDevices.map { dev in
            var info = Obscura_Client_V1_DeviceInfo()
            info.deviceID = dev.deviceId
            info.deviceName = dev.deviceName
            return info
        }
        announce.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        announce.isRevocation = isRevocation
        announce.signature = signature

        var msg = Obscura_Client_V1_ClientMessage()
        msg.deviceAnnounce = announce

        let accepted = await friends.getAccepted()
        for friend in accepted {
            try await sendToAllDevices(friend.userId, msg)
        }
    }

    // MARK: - Session Reset

    /// Delete all Signal sessions for a user and send SESSION_RESET message.
    public func resetSessionWith(_ targetUserId: String, reason: String = "manual") async throws {
        await clearSessionsWithUser(targetUserId)

        var msg = Obscura_Client_V1_ClientMessage()
        msg.sessionReset.reason = reason
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await sendToAllDevices(targetUserId, msg)

        // Delete the session that was just rebuilt to send the reset message.
        // Forces next send to use a fresh PreKey exchange, which the receiver
        // can handle after they also cleared their session.
        await clearSessionsWithUser(targetUserId)
    }

    /// Phase 2: Signal sessions are keyed on the peer's DEVICE UUID at address (deviceUuid, 1), so
    /// clearing "a user's" sessions means clearing every session with each of that user's devices.
    /// `deleteAllSessions(for:)` matches on the address-name prefix, so passing a device UUID here
    /// deletes exactly that device's session. (Mirrors Kotlin ClientSyncManager.clearSessionsWithUser.)
    private func clearSessionsWithUser(_ userId: String) async {
        guard let messenger = _messenger else { return }
        for deviceId in await messenger.getDeviceIdsForUser(userId) {
            try? persistentSignalStore?.deleteAllSessions(for: deviceId)
        }
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

        var msg = Obscura_Client_V1_ClientMessage()
        msg.syncRequest = Obscura_Client_V1_SyncRequest()
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

        var msg = Obscura_Client_V1_ClientMessage()
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

        var approval = Obscura_Client_V1_DeviceLinkApproval()
        if let pk = identity?.p2pPublicKey { approval.p2PPublicKey = pk }
        if let sk = identity?.p2pPrivateKey { approval.p2PPrivateKey = sk }
        if let rk = identity?.recoveryPublicKey { approval.recoveryPublicKey = rk }
        approval.challengeResponse = challengeResponse
        approval.ownDevices = ownDevices.map { d in
            var info = Obscura_Client_V1_DeviceInfo()
            info.deviceID = d.deviceId
            info.deviceName = d.deviceName
            return info
        }
        approval.friendsExport = friendsExportData

        var msg = Obscura_Client_V1_ClientMessage()
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
        var announce = Obscura_Client_V1_DeviceAnnounce()
        announce.devices = remainingDeviceIds.map { id in
            var info = Obscura_Client_V1_DeviceInfo()
            info.deviceID = id
            info.deviceName = "Device"
            return info
        }
        announce.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        announce.isRevocation = true
        announce.signature = Data(repeating: 0, count: Self.emptySignatureSize)

        var msg = Obscura_Client_V1_ClientMessage()
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
        // Next send will do a fresh PreKey exchange with the new identity. Sessions are keyed on
        // the DEVICE UUID (Phase 2), so clear per friend device.
        for friend in await friends.getAccepted() {
            await clearSessionsWithUser(friend.userId)
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

    /// Encrypt plaintext and upload the ciphertext, returning the reference triple.
    /// Unlike `sendEncryptedAttachment`, this does NOT send a CONTENT_REFERENCE to a
    /// friend — the caller embeds `{id, contentKey, nonce}` in a synced model entry
    /// (e.g. a Pix or Story) whose sync carries the reference. Mirrors the Kotlin
    /// `uploadAttachment` primitive; returns key material so the bridge needn't reach
    /// into `AttachmentCrypto` directly. Pair with `downloadDecryptedAttachment`.
    public func uploadAttachment(_ plaintext: Data) async throws -> (id: String, contentKey: Data, nonce: Data) {
        let encrypted = try AttachmentCrypto.encrypt(plaintext)
        let result = try await api.uploadAttachment(encrypted.ciphertext)
        return (id: result.id, contentKey: encrypted.contentKey, nonce: encrypted.nonce)
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
        var ref = Obscura_Client_V1_ContentReference()
        ref.attachmentID = attachmentId
        ref.contentKey = contentKey
        ref.nonce = nonce
        ref.contentType = mimeType
        ref.sizeBytes = UInt64(sizeBytes)

        var msg = Obscura_Client_V1_ClientMessage()
        msg.contentReference = ref
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await sendToAllDevices(friendUserId, msg)
    }

    /// Send a MODEL_SYNC message to a friend. Throws if not friends.
    /// Send an application entry (`obscura-proto/KIT_API.md` §5) — the outbox half of the thin kit,
    /// paired with ``inbox`` on the receive side and ``entries`` for local storage.
    ///
    /// **The caller names the recipients** (SPEC §0.4). The kit fans out to every device of every
    /// listed userId, plus this user's own *other* devices, and makes **no delivery decision of its
    /// own** — no audience resolution, no reading of `payload` to discover who it is for. That is the
    /// whole difference from ``sendModelSync(to:model:entryId:op:data:)``, which sends to exactly one
    /// friend and refuses a non-friend. Prefer this one; that one is a documented §0.4 follow-up
    /// (`obscura-proto/KIT_API.md` §4.2), still standing only because tests use it as a one-liner.
    ///
    /// Two properties §5 asks to be proven rather than assumed, both pinned by Kotlin's
    /// `EntrySendTests` and mirrored here:
    ///
    /// 1. **The sending device is excluded from its own fan-out.** `getOwnDevices()` includes this
    ///    device, and a message encrypted to yourself is at best waste and at worst a duplicate the
    ///    app must dedupe.
    /// 2. **The sender gets no inbox row.** Nothing loops back locally, so the app writes its own
    ///    outgoing entry to ``entries`` — one write path in the kit, two in the app.
    ///
    /// An empty `recipientUserIds` is legitimate and not an error: it means "my own devices only",
    /// which is what a self-scoped model wants. Failing loud is for an audience the kit was asked to
    /// *guess*, and here it never guesses.
    public func send(
        to recipientUserIds: [String],
        modelKey: String,
        entryId: String,
        op: String = "CREATE",
        sentAt: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        payload: Data
    ) async throws {
        var sync = Obscura_Client_V1_ModelSync()
        sync.model = modelKey
        sync.id = entryId
        sync.op = WireCodec.encodeOp(op)
        sync.timestamp = sentAt
        sync.data = payload
        sync.authorDeviceID = deviceId ?? ""

        var msg = Obscura_Client_V1_ClientMessage()
        msg.modelSync = sync

        // Deduplicated because the app may legitimately name the same user twice — e.g. both
        // participants of a canonical `userIdA_userIdB` conversation, one of whom is you.
        var seen = Set<String>()
        let targets = recipientUserIds.filter { $0 != userId && seen.insert($0).inserted }

        // PER-RECIPIENT, not all-or-nothing. `sendToAllDevices` throws for a recipient with no
        // registered devices, so letting the first failure escape would abandon recipients 2..N —
        // and, worse, skip the own-device self-sync below, so the user's own other devices would
        // silently never receive something they wrote. One unreachable friend must not cost the
        // other four, or the sender's own copy.
        var failures: [(String, Error)] = []
        for recipient in targets {
            do {
                try await sendToAllDevices(recipient, msg)
            } catch {
                failures.append((recipient, error))
                logger.log("SEND FAILED to \(recipient.prefix(8)) for \(modelKey)/\(entryId.prefix(20)): \(error)")
            }
        }

        // Own OTHER devices. Runs whether or not a recipient failed — see above. The `!=` is
        // §5 property 1: without it this device encrypts to itself.
        let ownDevices = await devices.getOwnDevices().filter { $0.deviceId != self.deviceId }
        if !ownDevices.isEmpty, let uid = userId {
            let messenger = try requireMessenger()
            let msgData = try msg.serializedData()
            for device in ownDevices {
                do {
                    try await messenger.queueMessage(targetDeviceId: device.deviceId,
                                                     clientMessageData: msgData, targetUserId: uid)
                } catch {
                    logger.log("self-sync failed for device \(device.deviceId): \(error)")
                }
            }
            _ = try? await messenger.flushMessages()
        }

        // Throw only when NOBODY named got it. A partial failure is logged and survivable — the
        // entry is stored, the other recipients have it, and the caller can retry. A total failure
        // is different in kind: the app believes it sent something that reached no one, and it must
        // be able to tell the user so.
        if !targets.isEmpty && failures.count == targets.count {
            throw ObscuraError.sendFailed(
                "\(modelKey)/\(entryId.prefix(20)) reached none of its \(targets.count) recipient(s)")
        }
    }

    // ── Ephemeral signals (typing, read receipts) ────────────────────────────────────────────
    //
    // These used to reach the app through `client.model(name).typing(...)`, which was the last
    // reason the app touched the ORM at all — and `RESET.md` KEEPS signals while deleting the engine
    // around them. `ModelSignal.swift` was keep-forever code that happened to live in `ORM/`; these
    // three methods are the door that let it stay after the directory went (it is now `Wire/`).
    //
    // `modelKey` is opaque, exactly as it is on the inbox and the entry store: it names the app's
    // conversation namespace and the kit neither parses nor validates it. That is what made this a
    // relocation rather than a new entrance to the engine.

    /// Announce that this user is typing in a conversation.
    ///
    /// Throttled to at most once every 2s. Delivered to the conversation's participants only — never
    /// broadcast; the audience comes from the canonical two-party `conversationId`, and a value that
    /// does not name exactly two participants is DROPPED rather than widened (the leak fixed on
    /// 2026-07-25).
    public func sendTyping(modelKey: String, conversationId: String) async {
        await sendSignalDirect(modelKey: modelKey, kind: "typing", conversationId: conversationId)
    }

    /// Explicitly stop typing.
    public func stopTyping(modelKey: String, conversationId: String) async {
        await sendSignalDirect(modelKey: modelKey, kind: "stoppedTyping", conversationId: conversationId)
    }

    /// Who is currently typing in a conversation, by display name.
    ///
    /// Auto-expires; a signal with no refresh disappears on its own, which is what makes signals
    /// droppable (`KIT_API.md` §4) rather than something the inbox has to carry.
    public nonisolated func observeTyping(modelKey: String, conversationId: String) -> SignalObservation {
        SignalObservation(
            store: SignalStoreRegistry.shared.store,
            model: modelKey,
            signal: SignalType.typing.rawValue,
            data: ["conversationId": conversationId]
        )
    }

    private func sendSignalDirect(modelKey: String, kind: String, conversationId: String) async {
        if kind == "typing" {
            let key = "typing:\(modelKey):\(conversationId)"
            let now = Date()
            if let last = SignalThrottle.shared.lastSent[key], now.timeIntervalSince(last) < 2.0 { return }
            SignalThrottle.shared.lastSent[key] = now
        }

        var signal = Obscura_Client_V1_ModelSignal()
        signal.model = modelKey
        signal.kind = WireCodec.encodeSignalKind(kind)
        signal.contextID = conversationId

        var msg = Obscura_Client_V1_ClientMessage()
        msg.modelSignal = signal
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        guard let msgData = try? msg.serializedData() else { return }

        // Fail CLOSED: a contextId that does not name exactly two participants sends NOTHING.
        // Dropping an ephemeral typing indicator costs nothing; guessing its audience leaks the
        // conversation.
        let participants = conversationId.split(separator: "_").map(String.init).filter { !$0.isEmpty }
        guard participants.count == 2 else {
            logger.log("signal dropped: contextId is not a canonical two-party value — refusing to broadcast a 1:1 signal")
            return
        }
        for participant in participants where participant != userId {
            try? await sendRawMessage(to: participant, clientMessageData: msgData)
        }
    }

    public func sendModelSync(to friendUserId: String, model: String, entryId: String, op: String = "CREATE", data: Data) async throws {
        guard await friends.isFriend(friendUserId) else { throw ObscuraError.notFriends(friendUserId) }
        var sync = Obscura_Client_V1_ModelSync()
        sync.model = model
        sync.id = entryId
        sync.op = WireCodec.encodeOp(op)
        sync.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        sync.data = data
        sync.authorDeviceID = deviceId ?? ""

        var msg = Obscura_Client_V1_ClientMessage()
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

    // MARK: - Facade (high-level methods for thin bridges)

    /// Typed event for the unified event stream.
    public enum ObscuraEvent {
        case friendsUpdated([Friend])
        case connectionChanged(ConnectionState)
        case authChanged(AuthState)
        case messageReceived(model: String, entryId: String)
        case typingChanged(conversationId: String, typers: [String])
        case authFailed(reason: String)
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
            // Incoming messages — surface the real model name for MODEL_SYNC so
            // story/profile/pix syncs re-query, not just directMessage.
            let msgTask = Task {
                for await event in events() {
                    if event.type == "MODEL_SYNC" {
                        continuation.yield(.messageReceived(model: event.model ?? "directMessage", entryId: ""))
                    }
                }
            }
            // Auth failure (token refresh exhausted) — distinct from a clean logout.
            let authFailedTask = Task {
                for await reason in observeAuthFailed() {
                    continuation.yield(.authFailed(reason: reason))
                }
            }

            continuation.onTermination = { _ in
                friendTask.cancel()
                connTask.cancel()
                authTask.cancel()
                msgTask.cancel()
                authFailedTask.cancel()
            }
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
        sessionStorage?.save(data)
    }

    /// Restore session from storage and connect.
    ///
    /// It used to also re-define models from a `cachedSchema` slot, which is gone with the schema
    /// parser — the kit no longer knows what an application model *is* (SPEC §0.4), so there is
    /// nothing to cache and nothing to restore. The app owns its own schema across a cold start.
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

        var announce = Obscura_Client_V1_DeviceRecoveryAnnounce()
        var deviceInfo = Obscura_Client_V1_DeviceInfo()
        deviceInfo.deviceID = deviceId ?? ""
        announce.newDevices = [deviceInfo]
        announce.timestamp = timestamp
        announce.signature = signature
        announce.isFullRecovery = true
        announce.recoveryPublicKey = recoveryPubKey

        var msg = Obscura_Client_V1_ClientMessage()
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
        // The §3.3 rule 2 carve-out, and the reason it is worded as a MUST: the inbox holds
        // DECRYPTED plaintext — full payloads, the resolved sender name, the model key. A wipe that
        // spared it would leave exactly the content a revocation is meant to destroy.
        try? await inbox.wipe()
    }

    // MARK: - Internal: Send to all devices of a user

    private func sendToAllDevices(_ targetUserId: String, _ msg: Obscura_Client_V1_ClientMessage, excludingDeviceId: String? = nil) async throws {
        let messenger = try requireMessenger()
        let bundles = try await messenger.fetchPreKeyBundles(targetUserId)
        await rateLimitDelay()

        let msgData = try msg.serializedData()
        for bundle in bundles {
            if let excluded = excludingDeviceId, bundle.deviceId == excluded { continue }
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

    private func processEnvelope(_ raw: (id: Data, senderID: Data, senderDeviceID: Data, timestamp: UInt64, message: Data)) async {
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
            // Phase 2 receive-side addressing: the envelope carries the sender's DEVICE UUID
            // (sender_device_id, stamped server-side from the device-scoped JWT). Signal sessions
            // are pairwise device-to-device, so this selects the inbound session. Missing/empty is
            // an ERROR (no candidate-registrationId guessing) — throwing here lands in the catch
            // below and SKIPS the ack, so the message stays on the server rather than being lost.
            guard raw.senderDeviceID.count == 16 else {
                throw ObscuraError.provisionFailed(
                    "Envelope from \(sourceUserId) has no sender_device_id (\(raw.senderDeviceID.count) bytes); cannot select an inbound session")
            }
            let senderDeviceId = bytesToUuid(raw.senderDeviceID)

            let encMsg = try Obscura_Client_V1_EncryptedMessage(serializedData: raw.message)
            let messageType = encMsg.type == .prekeyMessage ? 1 : 2
            let plaintext = try await messenger.decrypt(
                senderUserId: sourceUserId, senderDeviceUuid: senderDeviceId,
                content: encMsg.content, messageType: messageType
            )
            let clientMsg = try Obscura_Client_V1_ClientMessage(serializedData: Data(plaintext))

            // Route by message type. SPEC §0.9 rule 3+4: decrypt → persist → (notify) → ack.
            // routeMessage now throws, so if durable persistence fails the error propagates to the
            // catch below and we SKIP the ack — the message stays on the server for retry rather
            // than being deleted un-persisted. authorDeviceId is the decrypting session's device
            // UUID (== senderDeviceId, proven by the MAC), never the userId (the F4 lie).
            // `Envelope.id` is the inbox's DEDUPE KEY, so it gets the same length check
            // `sender_device_id` already gets above — and for the same reason: SPEC §0.10 treats
            // everything the relay stamps as untrusted.
            //
            // Without it, `bytesToUuid` falls back to raw hex for non-16-byte input, so an EMPTY id
            // (proto3's default) becomes "" for every envelope. They would all hash to one key: the
            // first inserts and is acked, and every one after is suppressed by INSERT OR IGNORE,
            // reported as a duplicate, and ACKED — the server deleting messages never stored.
            guard raw.id.count == 16 else {
                throw ObscuraError.provisionFailed(
                    "Envelope id is \(raw.id.count) bytes, expected 16; cannot use it as a dedupe key")
            }
            try await routeMessage(
                clientMsg, sourceUserId: sourceUserId, senderDeviceId: senderDeviceId,
                envelopeId: bytesToUuid(raw.id)
            )

            // Emit to event subscribers
            let received = ReceivedMessage(
                type: WireCodec.decodeMessageType(clientMsg.payload),
                text: clientMsg.text.text,
                username: {
                    switch clientMsg.payload {
                    case .friendRequest?: return clientMsg.friendRequest.username
                    case .friendResponse?: return clientMsg.friendResponse.username
                    default: return ""
                    }
                }(),
                accepted: {
                    if case .friendResponse? = clientMsg.payload { return clientMsg.friendResponse.accepted }
                    return false
                }(),
                sourceUserId: sourceUserId,
                senderDeviceId: senderDeviceId,
                timestamp: clientMsg.timestamp,
                rawBytes: Data(plaintext),
                model: {
                    if case .modelSync? = clientMsg.payload { return clientMsg.modelSync.model }
                    return nil
                }()
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

    /// Persist a decrypted message, by class (`obscura-proto/KIT_API.md` §4).
    ///
    /// Called from the envelope loop **before** the ack, and it throws on a failed durable write so
    /// the ack is skipped and the message survives on the server (SPEC §0.9 rule 3).
    ///
    /// `classify` decides what each arm is *allowed* to do; the switch below then routes it. The old
    /// `default: break` swallowed seven arms and let the caller ack them, destroying them silently.
    private func routeMessage(
        _ msg: Obscura_Client_V1_ClientMessage,
        sourceUserId: String,
        senderDeviceId: String,
        envelopeId: String
    ) async throws {
        NSLog("[ObscuraKit] routeMessage payload=%@ from=%@", WireCodec.decodeMessageType(msg.payload), String(sourceUserId.prefix(8)))

        switch classify(msg.payload) {
        case .inboxed:
            try await inboxMessage(msg, sourceUserId: sourceUserId, senderDeviceId: senderDeviceId,
                                   envelopeId: envelopeId)
            // The inbox row IS the delivery, and it has committed — §3.3 rule 1 gates the ack on
            // exactly that and on nothing else. MODEL_SYNC used to continue into the ORM from here;
            // that parallel write is gone with the engine, and the one thing below it that was never
            // the ORM's — clearing typing indicators, because a real message just arrived — is all
            // that falls through now.
            if case .modelSync? = msg.payload {} else { return }

        case .unimplemented:
            // Classified in §4 but implemented by neither kit. Today's behaviour (drop, then ack) is
            // preserved deliberately — §4.2 keys the inbox fallback on absence from the
            // classification TABLE, not absence from the handler, or the inbox becomes where
            // unimplemented kit work goes to be forgotten. What changes is that it is no longer
            // silent. Four of these are Phase 3 deletions; DEVICE_RECOVERY_ANNOUNCE is a deliberate
            // deferral and cannot currently fire at all.
            logger.log("RECV UNIMPLEMENTED arm=\(WireCodec.decodeMessageType(msg.payload)) "
                + "from=\(sourceUserId.prefix(8)) (dropped and acked — see KIT_API.md §4.2)")
            return

        case .kitInternal, .droppable:
            break // fall through to the handlers below
        }

        switch msg.payload {
        case .friendRequest?:
            // The payload username is a FIRST-CONTACT bootstrap only (SPEC §0.10 rule 5). This used
            // to call friends.add() unconditionally, and FriendStore's INSERT OR REPLACE meant an
            // already-accepted friend could re-send a FriendRequest to rename themselves — the name
            // the kit puts on notifications — and reset their own status to .pendingReceived,
            // dropping out of getAccepted() and out of fan-out.
            if let existing = await friends.getFriend(sourceUserId) {
                // Known peer: the name comes from our graph now, never from their payload. Refresh
                // the device list (that IS ours to learn — the sending device was just added to the
                // messenger's map by decrypt) and change nothing else.
                if let messenger = _messenger {
                    let deviceIds = await messenger.getDeviceIdsForUser(sourceUserId)
                    if !deviceIds.isEmpty {
                        try await friends.updateDevices(
                            sourceUserId,
                            devices: deviceIds.map { ["deviceId": $0, "deviceName": ""] })
                    }
                }
                logger.log("friend request from already-known peer \(sourceUserId) "
                    + "(status=\(existing.status.rawValue)); keeping stored name and status")
            } else {
                try await friends.add(sourceUserId, msg.friendRequest.username, status: .pendingReceived)
            }

        case .friendResponse?:
            // A response is only meaningful as the answer to a request WE sent. This used to call
            // friends.add(..., .accepted) whenever accepted was true, so any authenticated stranger
            // — friendship is not required to deliver a message — could insert themselves as an
            // ACCEPTED friend under a name of their choosing, with no interaction from us.
            if msg.friendResponse.accepted {
                let existing = await friends.getFriend(sourceUserId)
                if let existing, existing.status == .pendingSent {
                    // Promote in place: updateStatus keeps the name WE recorded when we sent the
                    // request. The payload username is not consulted (SPEC §0.5).
                    await friends.updateStatus(sourceUserId, .accepted)
                } else {
                    logger.log("ignoring unsolicited FRIEND_RESPONSE from \(sourceUserId) "
                        + "(local status=\(existing?.status.rawValue ?? "none"); expected pendingSent)")
                }
            }

        case .text?:
            let messageData = Message(
                messageId: "msg_\(UUID().uuidString)",
                conversationId: sourceUserId,
                timestamp: msg.timestamp,
                content: msg.text.text,
                isSent: false,
                // Honest attribution (F4): the sending device's UUID, proven by the session MAC.
                authorDeviceId: senderDeviceId
            )
            try await messages.add(sourceUserId, messageData)

        case .deviceAnnounce?:
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

            try await friends.updateDevices(sourceUserId, devices: deviceInfos, timestamp: announce.timestamp)

            if announce.isRevocation {
                // Purge messages from revoked devices
                let currentDeviceIds = Set(deviceInfos.compactMap { $0["deviceId"] })
                // Would need to know which device was removed to purge its messages
            }

        case .modelSync?:
            // Clear all typing indicators — a real message arrived. The entry itself is already in
            // the inbox (see `.inboxed` above); this case exists only for the signal side effect.
            await SignalStoreRegistry.shared.store.clearAll()
            SignalStoreRegistry.shared.notifyObservers()

        case .modelSignal?:
            // Ephemeral signal — typed payload; identity comes from the authenticated
            // envelope (sender from the decrypted session, display name from the friend
            // graph), never from the payload.
            let sig = msg.modelSignal
            let signalName = WireCodec.decodeSignalKind(sig.kind)
            if !sig.model.isEmpty, !signalName.isEmpty {
                let username = await friends.getAccepted().first(where: { $0.userId == sourceUserId })?.username ?? sourceUserId
                let payload = ModelSignalPayload(
                    model: sig.model,
                    signalRaw: signalName,
                    conversationId: sig.contextID,
                    senderUsername: username,
                    // Honest attribution (F4): the sending device's UUID, proven by the session MAC.
                    authorDeviceId: senderDeviceId,
                    timestamp: msg.timestamp
                )
                if signalName == "stoppedTyping" {
                    await SignalStoreRegistry.shared.store.remove(
                        model: sig.model, signal: "typing", data: payload.data, authorDeviceId: senderDeviceId)
                } else {
                    await SignalStoreRegistry.shared.store.receive(payload)
                }
                SignalStoreRegistry.shared.notifyObservers()
            }

        case .syncBlob?:
            // Import state from linked device — only accept from own devices
            guard sourceUserId == self.userId else { break }
            if let parsed = SyncBlobExporter.parseExport(msg.syncBlob.compressedData) {
                for f in parsed.friends {
                    let status = FriendStatus(rawValue: f["status"] as? String ?? "") ?? .pendingSent
                    try await friends.add(f["userId"] as? String ?? "", f["username"] as? String ?? "", status: status)
                }
                for m in parsed.messages {
                    let message = Message(
                        messageId: m["messageId"] as? String ?? UUID().uuidString,
                        conversationId: m["conversationId"] as? String ?? "",
                        content: m["content"] as? String ?? ""
                    )
                    try await messages.add(m["conversationId"] as? String ?? "", message)
                }
            }

        case .sentSync?:
            // Only accept sent sync from own devices
            guard sourceUserId == self.userId else { break }
            let ss = msg.sentSync
            let messageData = Message(
                messageId: ss.messageID,
                conversationId: ss.recipientUsername,
                timestamp: ss.timestamp,
                content: String(data: ss.content, encoding: .utf8) ?? "",
                isSent: true
            )
            try await messages.add(ss.recipientUsername, messageData)

        case .friendSync?:
            // Only accept friend sync from own devices
            guard sourceUserId == self.userId else { break }
            let fs = msg.friendSync
            if fs.action == "add" {
                let status = FriendStatus(rawValue: fs.status) ?? .pendingSent
                try await friends.add(sourceUserId, fs.username, status: status)
            } else if fs.action == "remove" {
                try await friends.remove(sourceUserId)
            }

        case .sessionReset?:
            // Sessions are keyed on the DEVICE UUID (Phase 2), so reset every session we hold with
            // any of this user's devices.
            await clearSessionsWithUser(sourceUserId)

        default:
            // A kit-internal arm with no handler must NOT be acked — the ack would destroy the only
            // copy of a message this kit is supposed to own. Kotlin throws here for the same reason.
            //
            // This is reachable TODAY: `.deviceLinkApproval` is classified kit-internal and this kit
            // cannot receive one (the divergence recorded in CLAUDE.md). It carries the p2p private
            // key, the recovery public key, the friends export and the approver's device list — so
            // logging and returning meant a newly-linked device dropped all of that and acked it
            // away permanently. Throwing leaves it on the server until the handler exists.
            throw ObscuraError.provisionFailed(
                "\(WireCodec.decodeMessageType(msg.payload)) is classified kit-internal but this kit "
                + "has no handler; refusing to ack it away")
        }
    }

    /// Write an inboxed payload to the durable inbox.
    ///
    /// Order matters: the inbox row commits before the caller acks. If it throws, nothing is acked
    /// and the message stays on the server — which is the whole point of persist-then-ack and the
    /// reason this is not an event stream.
    ///
    /// This is now the *only* durable write on the receive path for an application entry. Through
    /// §10 steps 2–3 the caller also continued into the ORM, because the ORM still owned what
    /// obscura-pix read; step 4 removed the second write and the engine under it.
    private func inboxMessage(
        _ msg: Obscura_Client_V1_ClientMessage,
        sourceUserId: String,
        senderDeviceId: String,
        envelopeId: String
    ) async throws {
        var isModelSync = false
        if case .modelSync? = msg.payload { isModelSync = true }
        let sync = msg.modelSync

        let inserted = try await inbox.put(
            InboxRecord(
                envelopeId: envelopeId,
                // Must match Kotlin byte for byte — the app reads one `kind` column from two kits,
                // and §4.1 has pix's drain BRANCH on it. WireCodec returns "" for an unset payload,
                // which is a poor value for a NOT NULL column read across a bridge; both kits now
                // share the UNKNOWN sentinel.
                kind: WireCodec.decodeMessageType(msg.payload).isEmpty
                    ? "UNKNOWN" : WireCodec.decodeMessageType(msg.payload),
                receivedAt: UInt64(Date().timeIntervalSince1970 * 1000),
                senderUserId: sourceUserId,
                senderDeviceId: senderDeviceId,
                // SPEC §0.5: the name comes from OUR friend graph, keyed on the authenticated
                // sender, never from the payload. Nil when they are not a friend — §7 covers what
                // the app should show then, and it is not a peer-chosen string.
                senderDisplayName: await friends.getFriend(sourceUserId)?.username,
                // ModelSync-derived, so nil for an unknown arm — there is nothing to derive from.
                modelKey: isModelSync ? sync.model : nil,
                entryId: isModelSync ? sync.id : nil,
                // `WireCodec.decodeOp`, not the raw enum: the inbox is read by the app across a
                // bridge, so this must be the app-facing CREATE/UPDATE/DELETE that §3.1 specifies.
                // Interpolating the generated enum would give
                // Swift's `opCreate` against Kotlin's `OP_CREATE` — one wire, two spellings.
                op: isModelSync ? WireCodec.decodeOp(sync.op) : nil,
                sentAt: isModelSync ? clampFutureTimestamp(sync.timestamp) : nil,
                // Opaque bytes. For an unknown arm this is the whole serialized message, because the
                // kit cannot know which sub-field would have been the payload.
                payload: isModelSync ? sync.data : ((try? msg.serializedData()) ?? Data())
            )
        )

        if !inserted {
            // A redelivered envelope. Not an error: persist-then-ack guarantees this happens, and
            // absorbing it here is what keeps depth() and the app's counts honest. Still ack.
            logger.log("RECV DUPLICATE envelope=\(envelopeId.prefix(12)) "
                + "kind=\(WireCodec.decodeMessageType(msg.payload)) (already inboxed)")
        }
    }

    /// SPEC §2.4: a peer-supplied timestamp is clamped before it is stored, not after.
    ///
    /// Without this a peer can set `sentAt` far in the future and win every REPLACE conflict forever
    /// — the tie-break can only order writes it can compare honestly.
    private func clampFutureTimestamp(_ sentAt: UInt64) -> UInt64 {
        min(sentAt, UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
    }

    /// A discard is data loss the app chose deliberately, and §3.3 rule 5 requires it be logged as a
    /// security-relevant event rather than being the quiet path.
    ///
    /// - Note: the hook is passed at construction rather than set afterwards. A detached
    ///   `Task { await inbox.setOnDiscard … }` from the initializer leaves a window in which the
    ///   store is reachable with no hook, and a `discard` in that window is data loss with no record
    ///   — precisely the quiet path rule 5 forbids.
    private static func discardLogger(_ logger: ObscuraLogger) -> @Sendable ([Int64], String) -> Void {
        { ids, reason in
            logger.log("INBOX DISCARD \(ids.count) row(s) reason=\"\(reason)\" ids=\(ids)")
        }
    }

    // MARK: - Internal: SENT_SYNC

    private func sendSentSync(conversationId: String, messageId: String, timestamp: UInt64, content: String) async throws {
        let ownDevices = await devices.getOwnDevices()
        guard !ownDevices.isEmpty else { return }

        var syncMsg = Obscura_Client_V1_ClientMessage()
        var payload = Obscura_Client_V1_SentSync()
        payload.recipientUsername = conversationId
        payload.messageID = messageId
        payload.timestamp = timestamp
        payload.content = Data(content.utf8)
        syncMsg.sentSync = payload

        guard ownDevices.contains(where: { $0.deviceId != self.deviceId }) else { return }
        do {
            try await sendToAllDevices(self.userId!, syncMsg, excludingDeviceId: self.deviceId)
        } catch {
            logger.sessionEstablishFailed(userId: self.userId ?? "unknown", error: "sentSync: \(error)")
        }
    }

    // MARK: - Internal: FRIEND_SYNC

    private func sendFriendSync(username: String, action: String, status: String, userId targetUserId: String) async throws {
        let ownDevices = await devices.getOwnDevices()
        guard !ownDevices.isEmpty else { return }

        var syncMsg = Obscura_Client_V1_ClientMessage()
        var payload = Obscura_Client_V1_FriendSync()
        payload.username = username
        payload.action = action
        payload.status = status
        payload.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        syncMsg.friendSync = payload

        guard ownDevices.contains(where: { $0.deviceId != self.deviceId }) else { return }
        do {
            try await sendToAllDevices(self.userId!, syncMsg, excludingDeviceId: self.deviceId)
        } catch {
            logger.sessionEstablishFailed(userId: self.userId ?? "unknown", error: "friendSync: \(error)")
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

                if self.refreshToken != nil {
                    do {
                        _ = try await self.refreshTokenNow()
                        consecutiveFailures = 0
                    } catch {
                        if Self.isCancellation(error) { continue }
                        consecutiveFailures += 1
                        self.logger.tokenRefreshFailed(attempt: consecutiveFailures, error: "\(error)")
                        if consecutiveFailures >= 3 {
                            self.emitAuthFailed("token refresh failed after \(consecutiveFailures) attempts: \(error)")
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
        /// Dead since §10 step 4 — nothing in this kit throws either one.
        ///
        /// `invalidSchema` belonged to `defineModelsFromJson`, and `directRoutingUnresolved` to the
        /// routing engine; both are deleted. `DIRECT_ROUTING_UNRESOLVED` is now raised **app-side**
        /// by `obscura-pix/src/domain/audience.ts`, which is exactly where §0.4 puts it.
        ///
        /// They stay for now because `ObscuraKit-Kotlin`'s `ObscuraError` carries the same two codes
        /// and the bridge contract is shared: removing them from one kit only would make the two
        /// diverge on a JS-visible surface. Delete them together, with the rest of the Kotlin
        /// storage residue.
        case invalidSchema(String)
        case directRoutingUnresolved(String)
        /// A `send` reached none of its named recipients. Distinct from a PARTIAL failure, which is
        /// logged and survivable — this one means the app believes it sent something that got
        /// nowhere. Matches Kotlin's `ObscuraError.SendFailed` and the bridge's `SEND_FAILED`.
        case sendFailed(String)

        /// Stable, machine-readable code for cross-boundary propagation (mirrors
        /// Kotlin `ObscuraError.code`). The bridge rejects promises with this so JS
        /// can branch on *what* failed rather than parse the message.
        public var code: String {
            switch self {
            case .missingToken: return "MISSING_TOKEN"
            case .notAuthenticated: return "NOT_AUTHENTICATED"
            case .provisionFailed: return "NOT_PROVISIONED"
            case .noMessenger: return "NO_MESSENGER"
            case .noMessage: return "NO_MESSAGE"
            case .timeout: return "TIMEOUT"
            case .notFriends: return "NOT_FRIENDS"
            case .deviceLinkFailed: return "DEVICE_LINK_FAILED"
            case .invalidSchema: return "INVALID_SCHEMA"
            case .directRoutingUnresolved: return "DIRECT_ROUTING_UNRESOLVED"
            case .sendFailed: return "SEND_FAILED"
            }
        }

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
            case .invalidSchema(let msg): return "Invalid schema: \(msg)"
            case .directRoutingUnresolved(let msg): return msg
            case .sendFailed(let msg): return "Send failed: \(msg)"
            }
        }
    }
}
