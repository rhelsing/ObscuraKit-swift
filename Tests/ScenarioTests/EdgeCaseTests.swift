import XCTest
@testable import ObscuraKit

/// Matches Kotlin's EdgeCaseTests.kt
/// Edge cases: attachment sizes, verify code stability, profile MODEL_SYNC.
final class EdgeCaseTests: XCTestCase {

    func testSmallAttachmentUploadSucceeds() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        let small = Data((0..<100).map { UInt8($0) })
        let result = try await alice.api.uploadAttachment(small)
        XCTAssertFalse(result.id.isEmpty)
    }

    func testMediumAttachmentUploadSucceeds() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // 500KB
        let medium = Data((0..<(500 * 1024)).map { UInt8($0 % 256) })
        let result = try await alice.api.uploadAttachment(medium)
        XCTAssertFalse(result.id.isEmpty)
        await rateLimitDelay()

        let downloaded = try await alice.api.fetchAttachment(result.id)
        XCTAssertEqual(downloaded.count, medium.count)
    }

    func testVerifyCodeIsStableForSameRecoveryPhrase() async throws {
        let alice = try await ObscuraTestClient.register()
        _ = alice.client.generateRecoveryPhrase()

        guard let pubKey = alice.client.recoveryPublicKey else {
            XCTFail("Should have recovery public key")
            return
        }

        let code1 = generateVerifyCode(from: pubKey)
        let code2 = generateVerifyCode(from: pubKey)
        XCTAssertEqual(code1, code2, "Verify code should be deterministic")
        XCTAssertEqual(code1.count, 4, "Should be 4 digits")
        XCTAssertTrue(code1.allSatisfy(\.isNumber))
    }

    func testProfileDataSyncsViaModelSync() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        let profileData = try JSONSerialization.data(withJSONObject: [
            "displayName": "Alice Display",
            "avatarUrl": "att-avatar-123"
        ])
        try await alice.client.sendModelSync(
            to: bob.userId!, model: "profile",
            entryId: "profile_\(alice.userId!)", data: profileData
        )
        await rateLimitDelay()

        let msg = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(msg.type, 30, "Should be MODEL_SYNC (30)")

        let clientMsg = try Obscura_V2_ClientMessage(serializedBytes: msg.rawBytes)
        XCTAssertEqual(clientMsg.modelSync.model, "profile")

        let data = try JSONSerialization.jsonObject(with: clientMsg.modelSync.data) as? [String: Any]
        XCTAssertEqual(data?["displayName"] as? String, "Alice Display")
        XCTAssertEqual(data?["avatarUrl"] as? String, "att-avatar-123")

        bob.disconnectWebSocket()
    }
}
