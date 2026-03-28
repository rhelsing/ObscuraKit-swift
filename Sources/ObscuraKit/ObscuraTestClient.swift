import Foundation

/// Thin test wrapper around ObscuraClient.
/// Provides convenience methods for scenario tests (register + connect in one call, etc.)
/// This calls the same API that views would call.
public class ObscuraTestClient {
    public let client: ObscuraClient
    public let username: String
    public let password: String

    public var userId: String? { client.userId }
    public var deviceId: String? { client.deviceId }
    public var token: String? { client.token }

    // Convenience accessors (same API views use)
    public var friends: FriendActor { client.friends }
    public var messages: MessageActor { client.messages }
    public var devices: DeviceActor { client.devices }
    public var api: APIClient { client.api }

    private init(client: ObscuraClient, username: String, password: String) {
        self.client = client
        self.username = username
        self.password = password
    }

    /// Register a new test user. Returns a ready-to-use test client.
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

    /// Re-login this user (simulating logout + login).
    public func relogin(deviceId: String? = nil) async throws {
        try await client.login(username, password, deviceId: deviceId)
        await rateLimitDelay()
    }

    /// Check if this user is friends with another.
    public func isFriendsWith(_ userId: String) async -> Bool {
        await friends.isFriend(userId)
    }
}
