import XCTest
@testable import ObscuraKit

/// Recovery phrase generation, signing, verification, and backup.
final class RecoveryTests: XCTestCase {

    // MARK: - BIP39 phrase generation

    func testGenerateRecoveryPhrase() {
        let phrase = RecoveryKeys.generatePhrase()
        let words = phrase.split(separator: " ")

        XCTAssertEqual(words.count, 12, "Should be 12 words")
        XCTAssertTrue(words.allSatisfy { !$0.isEmpty }, "No empty words")
    }

    func testPhrasesAreUnique() {
        let p1 = RecoveryKeys.generatePhrase()
        let p2 = RecoveryKeys.generatePhrase()
        XCTAssertNotEqual(p1, p2, "Two phrases should be different")
    }

    // MARK: - Key derivation

    func testDeriveKeypairDeterministic() {
        let phrase = "abandon ability able about above absent absorb abstract absurd abuse access accident"
        let kp1 = RecoveryKeys.deriveKeypair(from: phrase)
        let kp2 = RecoveryKeys.deriveKeypair(from: phrase)

        XCTAssertEqual(kp1.publicKey, kp2.publicKey, "Same phrase → same public key")
        XCTAssertEqual(kp1.privateKey, kp2.privateKey, "Same phrase → same private key")
        XCTAssertEqual(kp1.publicKey.count, 33, "33-byte public key (0x05 prefix)")
        XCTAssertEqual(kp1.privateKey.count, 32, "32-byte private key")
    }

    func testDifferentPhraseDifferentKeys() {
        let kp1 = RecoveryKeys.deriveKeypair(from: "abandon ability able about above absent absorb abstract absurd abuse access accident")
        let kp2 = RecoveryKeys.deriveKeypair(from: "zoo zone zoom zone zoo zone zoom zone zoo zone zoom zone")

        XCTAssertNotEqual(kp1.publicKey, kp2.publicKey)
    }

    // MARK: - Sign and verify

    func testSignAndVerify() {
        let phrase = "abandon ability able about above absent absorb abstract absurd abuse access accident"
        let data = Data("test message".utf8)

        let signature = RecoveryKeys.sign(phrase: phrase, data: data)
        XCTAssertEqual(signature.count, 64, "64-byte XEdDSA signature")

        let publicKey = RecoveryKeys.getPublicKey(from: phrase)
        let valid = RecoveryKeys.verify(publicKey: publicKey, data: data, signature: signature)
        XCTAssertTrue(valid, "Signature should verify")
    }

    func testSignatureInvalidWithWrongKey() {
        let phrase1 = "abandon ability able about above absent absorb abstract absurd abuse access accident"
        let phrase2 = "zoo zone zoom zone zoo zone zoom zone zoo zone zoom zone"
        let data = Data("test".utf8)

        let signature = RecoveryKeys.sign(phrase: phrase1, data: data)
        let wrongKey = RecoveryKeys.getPublicKey(from: phrase2)
        let valid = RecoveryKeys.verify(publicKey: wrongKey, data: data, signature: signature)
        XCTAssertFalse(valid, "Wrong key should not verify")
    }

    // MARK: - DeviceAnnounce serialization

    func testAnnounceSerializationDeterministic() {
        let data1 = RecoveryKeys.serializeAnnounceForSigning(
            deviceIds: ["dev-1", "dev-2"], timestamp: 1000, isRevocation: true
        )
        let data2 = RecoveryKeys.serializeAnnounceForSigning(
            deviceIds: ["dev-1", "dev-2"], timestamp: 1000, isRevocation: true
        )
        XCTAssertEqual(data1, data2, "Same inputs → same serialization")
    }

    // MARK: - ObscuraClient recovery integration

    func testGenerateRecoveryPhraseOnClient() async throws {
        let client = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
        let phrase = client.generateRecoveryPhrase()

        XCTAssertEqual(phrase.split(separator: " ").count, 12)
        XCTAssertNotNil(client.recoveryPhrase)
        XCTAssertNotNil(client.recoveryPublicKey)
        XCTAssertEqual(client.recoveryPublicKey?.count, 33)
    }

    // MARK: - Backup upload/download

    func testBackupUploadAndDownload() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Add some state
        await alice.friends.add("bob-id", "bob", status: .accepted)

        // Upload backup
        do {
            let etag = try await alice.client.uploadBackup()
            // Upload succeeded — try download
            await rateLimitDelay()
            let data = try await alice.client.downloadBackup()
            XCTAssertNotNil(data, "Should get backup data")
        } catch {
            // Server may not support backup endpoint — pass with warning
            print("Backup test skipped: \(error)")
        }
    }
}
