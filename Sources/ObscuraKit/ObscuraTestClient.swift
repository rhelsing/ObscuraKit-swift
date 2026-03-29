import Foundation

/// Thin test wrapper around ObscuraClient.
/// Provides convenience methods for scenario tests.
/// All real logic lives in ObscuraClient — this just adds test helpers.
public class ObscuraTestClient {
    public let client: ObscuraClient
    public let username: String
    public let password: String

    // Passthrough to client
    public var userId: String? { client.userId }
    public var deviceId: String? { client.deviceId }
    public var token: String? { client.token }
    public var friends: FriendActor { client.friends }
    public var messages: MessageActor { client.messages }
    public var devices: DeviceActor { client.devices }
    public var api: APIClient { client.api }
    public var gateway: GatewayConnection { client.gateway }

    /// Send a raw protobuf ClientMessage to a user (for tests that build custom message types)
    public func sendRaw(to userId: String, _ messageData: Data) async throws {
        try await client.sendRawMessage(to: userId, clientMessageData: messageData)
        await rateLimitDelay()
    }

    private init(client: ObscuraClient, username: String, password: String) {
        self.client = client
        self.username = username
        self.password = password
    }

    // MARK: - Test Convenience

    /// Register a new test user. Returns ready-to-use client.
    public static func register(
        _ username: String? = nil,
        _ password: String = {
            #if DEBUG
            return "testpass123456"
            #else
            fatalError("ObscuraTestClient must not be used in release builds")
            #endif
        }(),
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
        _ password: String = {
            #if DEBUG
            return "testpass123456"
            #else
            fatalError("ObscuraTestClient must not be used in release builds")
            #endif
        }(),
        deviceId: String? = nil,
        apiURL: String = "https://obscura.barrelmaker.dev"
    ) async throws -> ObscuraTestClient {
        let client = try ObscuraClient(apiURL: apiURL)
        try await client.login(username, password, deviceId: deviceId)
        await rateLimitDelay()
        return ObscuraTestClient(client: client, username: username, password: password)
    }

    /// Login and provision a new device (device linking).
    public static func loginAndProvision(
        _ username: String,
        _ password: String = {
            #if DEBUG
            return "testpass123456"
            #else
            fatalError("ObscuraTestClient must not be used in release builds")
            #endif
        }(),
        deviceName: String = "Device 2",
        apiURL: String = "https://obscura.barrelmaker.dev"
    ) async throws -> ObscuraTestClient {
        let client = try ObscuraClient(apiURL: apiURL)
        try await client.loginAndProvision(username, password, deviceName: deviceName)
        await rateLimitDelay()
        return ObscuraTestClient(client: client, username: username, password: password)
    }

    // MARK: - Passthrough to client operations

    public func connectWebSocket() async throws {
        try await client.connect()
        await rateLimitDelay()
    }

    public func disconnectWebSocket() {
        client.disconnect()
    }

    public func send(to userId: String, _ text: String) async throws {
        try await client.send(to: userId, text)
        await rateLimitDelay()
    }

    public func befriend(_ userId: String) async throws {
        try await client.befriend(userId)
        await rateLimitDelay()
    }

    public func acceptFriend(_ userId: String) async throws {
        try await client.acceptFriend(userId)
        await rateLimitDelay()
    }

    public func waitForMessage(timeout: TimeInterval = 10) async throws -> ReceivedMessage {
        return try await client.waitForMessage(timeout: timeout)
    }
}
