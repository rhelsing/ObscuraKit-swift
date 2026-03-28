import Foundation
import GRDB
import LibSignalClient

/// ObscuraClient — the unified facade.
/// This is the public API that both SwiftUI views and XCTests call.
public class ObscuraClient {
    public let api: APIClient
    public let friends: FriendActor
    public let messages: MessageActor
    public let devices: DeviceActor
    public let signalStore: GRDBSignalStore
    public var messenger: MessengerActor?
    public var gateway: GatewayConnection?

    // Signal crypto state
    public var signalProtocolStore: InMemorySignalProtocolStore?
    public var identityKeyPair: IdentityKeyPair?
    public var registrationId: UInt32?

    // Auth state
    public var token: String?
    public var refreshToken: String?
    public var userId: String?
    public var username: String?
    public var deviceId: String?
    public var deviceUUID: String?

    /// Create with in-memory databases (testing)
    public init(apiURL: String) throws {
        self.api = APIClient(baseURL: apiURL)
        self.friends = try FriendActor()
        self.messages = try MessageActor()
        self.devices = try DeviceActor()
        self.signalStore = try GRDBSignalStore()
    }

    // MARK: - Registration (with real Signal keys)

    /// Register a new user, generate Signal keys, provision device.
    /// After this call: token, userId, deviceId are set, messenger is ready.
    public func register(_ username: String, _ password: String) async throws {
        // 1. Register user account
        let result = try await api.registerUser(username, password)

        guard let token = result["token"] as? String else {
            throw ObscuraError.missingToken
        }

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

        // 3. Provision device with server
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

        // 4. Initialize Signal protocol store
        let protocolStore = InMemorySignalProtocolStore(
            identity: identity,
            registrationId: regId
        )

        // Store signed pre-key
        try protocolStore.storeSignedPreKey(
            SignedPreKeyRecord(
                id: 1,
                timestamp: UInt64(Date().timeIntervalSince1970),
                privateKey: signedPreKeyPrivate,
                signature: signedPreKeySignature
            ),
            id: 1,
            context: NullContext()
        )

        // Store one-time pre-keys
        for record in preKeyRecords {
            try protocolStore.storePreKey(
                PreKeyRecord(id: record.id, publicKey: record.privateKey.publicKey, privateKey: record.privateKey),
                id: record.id,
                context: NullContext()
            )
        }

        self.signalProtocolStore = protocolStore

        // 5. Initialize messenger
        self.messenger = MessengerActor(
            api: api,
            store: protocolStore,
            ownUserId: self.userId!
        )

        // 6. Initialize gateway
        self.gateway = GatewayConnection(api: api)
    }

    // MARK: - Login

    public func login(_ username: String, _ password: String, deviceId: String? = nil) async throws {
        let result = try await api.loginWithDevice(username, password, deviceId: deviceId)

        guard let token = result["token"] as? String else {
            throw ObscuraError.missingToken
        }

        self.token = token
        self.refreshToken = result["refreshToken"] as? String
        self.userId = APIClient.extractUserId(token)
        self.username = username
        self.deviceId = APIClient.extractDeviceId(token) ?? deviceId
        await api.setToken(token)
    }

    // MARK: - Logout

    public func logout() async throws {
        if let refreshToken = refreshToken {
            try await api.logout(refreshToken)
        }
        gateway?.disconnect()
        token = nil
        refreshToken = nil
        userId = nil
        await api.clearToken()
    }

    public enum ObscuraError: Error, LocalizedError {
        case missingToken
        case notAuthenticated
        case provisionFailed(String)
        case noMessenger

        public var errorDescription: String? {
            switch self {
            case .missingToken: return "No token in server response"
            case .notAuthenticated: return "Not authenticated"
            case .provisionFailed(let msg): return "Device provisioning failed: \(msg)"
            case .noMessenger: return "Messenger not initialized (call register first)"
            }
        }
    }
}
