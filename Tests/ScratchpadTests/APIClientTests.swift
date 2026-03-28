import XCTest
@testable import ObscuraKit

/// Tests that hit the real server at obscura.barrelmaker.dev
/// IMPORTANT: These tests MUST run serially (not in parallel) to avoid rate limiting
final class APIClientTests: XCTestCase {

    let api = APIClient(baseURL: "https://obscura.barrelmaker.dev")

    func testRegisterAndParseToken() async throws {
        let username = "test_\(Int.random(in: 100000...999999))"
        let result = try await api.registerUser(username, "testpass123456")

        // Should have a token
        let token = result["token"] as? String
        XCTAssertNotNil(token, "Registration should return a token")

        // Token should be a JWT we can decode
        let payload = APIClient.decodeJWT(token!)
        XCTAssertNotNil(payload, "Token should be decodable JWT")

        // Should have a userId
        let userId = APIClient.extractUserId(token!)
        XCTAssertNotNil(userId, "Should extract userId from token")
        XCTAssertFalse(userId!.isEmpty)

        // Should have refresh token
        let refreshToken = result["refreshToken"] as? String
        XCTAssertNotNil(refreshToken, "Should have refresh token")
    }

    func testLoginWithDevice() async throws {
        let username = "test_\(Int.random(in: 100000...999999))"

        // Register first
        let regResult = try await api.registerUser(username, "testpass123456")
        await rateLimitDelay()

        let regToken = regResult["token"] as? String
        XCTAssertNotNil(regToken)

        // Login without deviceId (user-scoped)
        let loginResult = try await api.loginWithDevice(username, "testpass123456")
        let loginToken = loginResult["token"] as? String
        XCTAssertNotNil(loginToken)

        // User ID should match
        let regUserId = APIClient.extractUserId(regToken!)
        let loginUserId = APIClient.extractUserId(loginToken!)
        XCTAssertEqual(regUserId, loginUserId)
    }

    /// NOTE: This test uses dummy keys with a fake signature.
    /// Server validates XEdDSA signatures, so provisioning will fail until we have real Signal keys.
    /// This will pass once we integrate libsignal in the Signal Store layer.
    func _testProvisionDeviceAndFetchBundles_PENDING_SIGNAL() async throws {
        let username = "test_\(Int.random(in: 100000...999999))"

        // Register
        let regResult = try await api.registerUser(username, "testpass123456")
        let regToken = regResult["token"] as? String
        XCTAssertNotNil(regToken)
        await api.setToken(regToken!)
        await rateLimitDelay()

        let userId = APIClient.extractUserId(regToken!)!

        // Provision device with dummy keys
        let dummyKey = Data(repeating: 0x05, count: 33).base64EncodedString()
        let dummySig = Data(repeating: 0xAA, count: 64).base64EncodedString()

        let deviceResult = try await api.provisionDevice(
            name: "test-device",
            identityKey: dummyKey,
            registrationId: 12345,
            signedPreKey: [
                "keyId": 1,
                "publicKey": dummyKey,
                "signature": dummySig,
            ],
            oneTimePreKeys: [
                ["keyId": 1, "publicKey": dummyKey],
                ["keyId": 2, "publicKey": dummyKey],
            ]
        )
        await rateLimitDelay()

        // Should return device-scoped token
        let deviceToken = deviceResult["token"] as? String
        XCTAssertNotNil(deviceToken, "Provisioning should return device-scoped token")

        let deviceId = APIClient.extractDeviceId(deviceToken!)
        XCTAssertNotNil(deviceId, "Device token should have deviceId claim")

        // Use device token for subsequent requests
        await api.setToken(deviceToken!)

        // Fetch prekey bundles
        let bundles = try await api.fetchPreKeyBundles(userId)
        XCTAssertFalse(bundles.isEmpty, "Should have at least one bundle")

        let bundle = bundles[0]
        XCTAssertNotNil(bundle["registrationId"])
        XCTAssertNotNil(bundle["identityKey"])
        XCTAssertNotNil(bundle["signedPreKey"])
    }

    func testJWTDecoding() {
        // Purely local — no server call, no actor
        let payloadJson = #"{"sub":"user123","device_id":"dev456","exp":9999999999}"#
        let payloadBase64 = Data(payloadJson.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let fakeJWT = "eyJhbGciOiJIUzI1NiJ9.\(payloadBase64).fakesig"

        let payload = APIClient.decodeJWT(fakeJWT)
        XCTAssertEqual(payload?["sub"] as? String, "user123")
        XCTAssertEqual(payload?["device_id"] as? String, "dev456")

        XCTAssertEqual(APIClient.extractUserId(fakeJWT), "user123")
        XCTAssertEqual(APIClient.extractDeviceId(fakeJWT), "dev456")
    }
}
