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

        let apiURL = "https://obscura.barrelmaker.dev"
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
}
