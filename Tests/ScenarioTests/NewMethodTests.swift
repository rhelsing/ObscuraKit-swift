import XCTest
@testable import ObscuraKit

/// Tests for session management and query helpers ported from Kotlin.
/// Attachment, reset, model sync, and edge case tests live in their own suites.
final class NewMethodTests: XCTestCase {

    // MARK: - hasSession

    func testHasSession() async throws {
        let alice = try await ObscuraTestClient.register()
        XCTAssertTrue(alice.client.hasSession, "Should have session after register")

        let fresh = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
        XCTAssertFalse(fresh.hasSession, "Fresh client should not have session")
    }

    // MARK: - restoreSession

    func testRestoreSession() async throws {
        let alice = try await ObscuraTestClient.register()
        let savedToken = alice.token!
        let savedRefreshToken = alice.client.refreshToken
        let savedUserId = alice.userId!
        let savedDeviceId = alice.deviceId!
        let savedUsername = alice.username
        await rateLimitDelay()

        let restored = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
        await restored.restoreSession(
            token: savedToken, refreshToken: savedRefreshToken,
            userId: savedUserId, deviceId: savedDeviceId,
            username: savedUsername
        )

        XCTAssertTrue(restored.hasSession)
        XCTAssertEqual(restored.userId, savedUserId)
        XCTAssertEqual(restored.deviceId, savedDeviceId)
        XCTAssertEqual(restored.username, savedUsername)
        XCTAssertEqual(restored.authState, .authenticated)
    }

    // MARK: - ensureFreshToken

    func testEnsureFreshToken() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        let result = await alice.client.ensureFreshToken()
        XCTAssertTrue(result, "Should return true for a fresh token")

        let fresh = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
        let noResult = await fresh.ensureFreshToken()
        XCTAssertFalse(noResult, "Should return false with no token")
    }

    // MARK: - loginAndProvision

    func testLoginAndProvision() async throws {
        let alice = try await ObscuraTestClient.register()
        let aliceUserId = alice.userId!
        await rateLimitDelay()

        let device2 = try await ObscuraTestClient.loginAndProvision(alice.username)

        XCTAssertNotNil(device2.token)
        XCTAssertEqual(device2.userId, aliceUserId, "Same user ID")
        XCTAssertNotNil(device2.deviceId)
        XCTAssertNotEqual(device2.deviceId, alice.deviceId, "Different device IDs")
        XCTAssertTrue(device2.client.hasSession)
    }

    // MARK: - getMessages (convenience)

    func testGetMessages() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        try await alice.send(to: bob.userId!, "test message 1")
        _ = try await bob.waitForMessage(timeout: 10)

        let aliceMsgs = await bob.client.getMessages(alice.userId!)
        XCTAssertGreaterThanOrEqual(aliceMsgs.count, 1)
        XCTAssertEqual(aliceMsgs.first?.content, "test message 1")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - checkBackup

    func testCheckBackup() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        let check1 = try await alice.client.checkBackup()
        XCTAssertFalse(check1.exists, "Should have no backup initially")

        let backupData = Data(repeating: 0x42, count: 1024)
        _ = try await alice.api.uploadBackup(backupData)
        await rateLimitDelay()

        let check2 = try await alice.client.checkBackup()
        XCTAssertTrue(check2.exists, "Should have backup after upload")
        XCTAssertNotNil(check2.etag)
    }

    // MARK: - Recovery phrase one-time read

    func testRecoveryPhraseIsOneTimeRead() async throws {
        let alice = try await ObscuraTestClient.register()
        let phrase = alice.client.generateRecoveryPhrase()
        XCTAssertNotNil(phrase)
        XCTAssertEqual(alice.client.getRecoveryPhrase(), phrase)
        XCTAssertNil(alice.client.getRecoveryPhrase(), "Second read should return nil")
    }

    // MARK: - AttachmentCrypto unit test

    func testAttachmentCryptoRoundTrip() throws {
        let plaintext = Data("hello world this is a test of AES-256-GCM encryption".utf8)
        let encrypted = try AttachmentCrypto.encrypt(plaintext)

        XCTAssertEqual(encrypted.contentKey.count, 32)
        XCTAssertEqual(encrypted.nonce.count, 12)
        XCTAssertEqual(encrypted.sizeBytes, plaintext.count)
        XCTAssertNotEqual(encrypted.ciphertext, plaintext)

        let decrypted1 = try AttachmentCrypto.decrypt(encrypted.ciphertext, contentKey: encrypted.contentKey, nonce: encrypted.nonce)
        XCTAssertEqual(decrypted1, plaintext)

        let decrypted2 = try AttachmentCrypto.decrypt(encrypted.ciphertext, contentKey: encrypted.contentKey, nonce: encrypted.nonce, expectedHash: encrypted.contentHash)
        XCTAssertEqual(decrypted2, plaintext)

        let badHash = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try AttachmentCrypto.decrypt(encrypted.ciphertext, contentKey: encrypted.contentKey, nonce: encrypted.nonce, expectedHash: badHash))
    }
}
