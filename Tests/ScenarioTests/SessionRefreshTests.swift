import XCTest
@testable import ObscuraKit

/// Regression test for the single-use-refresh-token 401 (broadcast/reconnect
/// failures after "app restart"). A refresh rotates the refresh token; the host
/// must re-persist it, so the kit fires `onSessionChanged` on every refresh.
/// Runs against the live server (like the other scenario tests).
final class SessionRefreshTests: XCTestCase {

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "obscura_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRefreshRotatesTokenAndFiresOnSessionChanged() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let apiURL = TestServer.apiURL
        let username = "test_\(Int.random(in: 100000...999999))"
        let client = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await client.register(username, "testpass123456")
        await rateLimitDelay()

        let rt1 = try XCTUnwrap(client.refreshToken, "registration should yield a refresh token")

        var fired = false
        client.onSessionChanged = { fired = true }

        // Force a refresh (bypasses the expiry guard) — always rotates server-side.
        let refreshed = try await client.refreshTokenNow()
        await rateLimitDelay()

        XCTAssertTrue(refreshed, "refreshTokenNow should refresh when a refresh token exists")
        XCTAssertTrue(fired, "onSessionChanged must fire so the host re-persists the rotated token")
        let rt2 = try XCTUnwrap(client.refreshToken)
        XCTAssertNotEqual(rt2, rt1, "the single-use refresh token should be rotated by the server")

        // Root-cause proof: the OLD refresh token is now invalid. Before the fix,
        // a restored session used exactly this consumed token → 401 on every send.
        do {
            _ = try await client.api.refreshSession(rt1)
            XCTFail("the old (consumed) refresh token must be rejected after rotation")
        } catch {
            // expected — server rejects the consumed refresh token
        }
    }

    /// The device-scope spec — mirrors Kotlin `RefreshScopeTests` exactly.
    /// register() must store the DEVICE provision's refresh token (not the
    /// user-scoped one from registerUser), so refreshing it keeps device scope.
    /// Was RED: iOS kept the user-scoped refresh token → refresh → user-scoped
    /// token → gateway ticket 403. Android (same server) stays device-scoped.
    func testRefreshKeepsDeviceScope() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let apiURL = TestServer.apiURL
        let client = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await client.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        await rateLimitDelay()

        XCTAssertNotNil(client.token.flatMap { APIClient.extractDeviceId($0) },
                        "token should be device-scoped after register")

        // Refresh the stored refresh token and check the NEW token's scope —
        // identical to the Kotlin test that passes against the same server.
        let rt = try XCTUnwrap(client.refreshToken, "register should yield a refresh token")
        let result = try await client.api.refreshSession(rt)
        XCTAssertNotNil(APIClient.extractDeviceId(result.token),
                        "refresh must KEEP the token device-scoped")
    }

    /// One clean managed flow, end to end, the way the app intends it:
    /// register → connect → a token refresh happens → the gateway can still
    /// (re)connect. `connect()` fetches a gateway ticket that REQUIRES a
    /// device-scoped token, so the second connect throws 403 if the refresh
    /// dropped scope — i.e. this is the actual user-facing bug as a smoke test.
    func testManagedFlowStaysConnectedAcrossRefresh() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let client = try ObscuraClient(apiURL: TestServer.apiURL, dataDirectory: dir)
        try await client.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        await rateLimitDelay()

        try await client.connect()               // opens the gateway (needs device-scoped ticket)
        _ = try await client.refreshTokenNow()   // simulate the background token refresh
        await rateLimitDelay()

        XCTAssertNotNil(client.token.flatMap { APIClient.extractDeviceId($0) },
                        "token still device-scoped after refresh")
        try await client.connect()               // re-fetch ticket — throws 403 here if scope dropped
        client.disconnect()
    }
}
