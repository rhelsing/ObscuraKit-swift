import Foundation
import GRDB

/// ObscuraClient — the unified facade.
/// This is the public API that both SwiftUI views and XCTests call.
public class ObscuraClient {
    public let api: APIClient
    public let friends: FriendActor
    public let messages: MessageActor
    public let devices: DeviceActor
    public let signalStore: GRDBSignalStore

    // Auth state
    public var token: String?
    public var refreshToken: String?
    public var userId: String?
    public var username: String?
    public var deviceId: String?
    public var deviceUUID: String?

    /// Create with shared GRDB database (production)
    public init(apiURL: String, db: DatabaseQueue) throws {
        self.api = APIClient(baseURL: apiURL)
        self.friends = try FriendActor(db: db)
        self.messages = try MessageActor(db: db)
        self.devices = try DeviceActor(db: db)
        self.signalStore = try GRDBSignalStore(db: db)
    }

    /// Create with in-memory databases (testing)
    public init(apiURL: String) throws {
        self.api = APIClient(baseURL: apiURL)
        self.friends = try FriendActor()
        self.messages = try MessageActor()
        self.devices = try DeviceActor()
        self.signalStore = try GRDBSignalStore()
    }

    // MARK: - Auth

    public func register(_ username: String, _ password: String) async throws {
        let result = try await api.registerUser(username, password)

        guard let token = result["token"] as? String else {
            throw ObscuraError.missingToken
        }

        self.token = token
        self.refreshToken = result["refreshToken"] as? String
        self.userId = APIClient.extractUserId(token)
        self.username = username
        await api.setToken(token)
    }

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

    public func logout() async throws {
        if let refreshToken = refreshToken {
            try await api.logout(refreshToken)
        }
        token = nil
        refreshToken = nil
        userId = nil
        await api.clearToken()
    }

    public enum ObscuraError: Error {
        case missingToken
        case notAuthenticated
        case provisionFailed(String)
    }
}
