import XCTest
import LibSignalClient
@testable import ObscuraKit

/// Test real Signal key generation and registration against the live server
final class SignalCryptoTests: XCTestCase {

    // MARK: - Key Generation

    func testGenerateIdentityKeyPair() throws {
        let identityKey = IdentityKeyPair.generate()
        let pubBytes = identityKey.publicKey.serialize()
        let privBytes = identityKey.privateKey.serialize()

        // Public key: 33 bytes (0x05 prefix + 32 bytes Curve25519)
        XCTAssertEqual(pubBytes.count, 33)
        XCTAssertEqual(pubBytes[0], 0x05, "First byte should be 0x05 Curve25519 type prefix")

        // Private key: 32 bytes
        XCTAssertEqual(privBytes.count, 32)
    }

    func testGenerateSignedPreKey() throws {
        let identityKey = IdentityKeyPair.generate()

        // Generate a signed pre-key (signed by the identity key)
        let signedPreKeyPair = KEMKeyPair.generate()

        // Actually for Signal Protocol, signed pre-key uses Curve25519, not KEM
        // Let's use the correct approach
        let preKeyPair = PrivateKey.generate()
        let preKeyPublic = preKeyPair.publicKey

        // Sign the public key with the identity key
        let signature = identityKey.privateKey.generateSignature(message: preKeyPublic.serialize())

        // Verify the signature
        let valid = try identityKey.publicKey.verifySignature(
            message: preKeyPublic.serialize(),
            signature: signature
        )
        XCTAssertTrue(valid, "Signature should verify with identity public key")

        // Signature should be 64 bytes (XEdDSA)
        XCTAssertEqual(signature.count, 64)
    }

    func testGeneratePreKeys() throws {
        // Generate 10 one-time pre-keys
        for i in 1...10 {
            let preKey = PrivateKey.generate()
            let pubBytes = preKey.publicKey.serialize()
            XCTAssertEqual(pubBytes.count, 33)
            XCTAssertEqual(pubBytes[0], 0x05)
        }
    }

    func testGenerateRegistrationPayload() throws {
        let identityKey = IdentityKeyPair.generate()

        // Signed pre-key
        let signedPreKeyPrivate = PrivateKey.generate()
        let signedPreKeyPublic = signedPreKeyPrivate.publicKey
        let signedPreKeySignature = identityKey.privateKey.generateSignature(
            message: signedPreKeyPublic.serialize()
        )

        // One-time pre-keys
        var oneTimePreKeys: [[String: Any]] = []
        for i in 1...5 {
            let preKey = PrivateKey.generate()
            oneTimePreKeys.append([
                "keyId": i,
                "publicKey": Data(preKey.publicKey.serialize()).base64EncodedString(),
            ])
        }

        // Build the registration payload (same format as JS testClient)
        let payload: [String: Any] = [
            "identityKey": Data(identityKey.publicKey.serialize()).base64EncodedString(),
            "registrationId": Int.random(in: 1...16380),
            "signedPreKey": [
                "keyId": 1,
                "publicKey": Data(signedPreKeyPublic.serialize()).base64EncodedString(),
                "signature": Data(signedPreKeySignature).base64EncodedString(),
            ] as [String: Any],
            "oneTimePreKeys": oneTimePreKeys,
        ]

        // Verify key sizes
        let identityKeyB64 = payload["identityKey"] as! String
        let identityKeyData = Data(base64Encoded: identityKeyB64)!
        XCTAssertEqual(identityKeyData.count, 33)

        let spk = payload["signedPreKey"] as! [String: Any]
        let spkSigData = Data(base64Encoded: spk["signature"] as! String)!
        XCTAssertEqual(spkSigData.count, 64)

        let otpks = payload["oneTimePreKeys"] as! [[String: Any]]
        XCTAssertEqual(otpks.count, 5)
    }

    // MARK: - Server Registration with Real Keys

    func testRegisterWithRealKeys() async throws {
        let api = APIClient(baseURL: "https://obscura.barrelmaker.dev")
        let username = "test_\(Int.random(in: 100000...999999))"
        let password = "testpass123456"

        // Generate real Signal keys
        let identityKey = IdentityKeyPair.generate()
        let registrationId = Int.random(in: 1...16380)

        let signedPreKeyPrivate = PrivateKey.generate()
        let signedPreKeyPublic = signedPreKeyPrivate.publicKey
        let signedPreKeySignature = identityKey.privateKey.generateSignature(
            message: signedPreKeyPublic.serialize()
        )

        var oneTimePreKeys: [[String: Any]] = []
        for i in 1...10 {
            let preKey = PrivateKey.generate()
            oneTimePreKeys.append([
                "keyId": i,
                "publicKey": Data(preKey.publicKey.serialize()).base64EncodedString(),
            ])
        }

        // Register with server
        let result = try await api.registerUser(username, password)
        let token = result["token"] as? String
        XCTAssertNotNil(token, "Registration should return a token")
        await api.setToken(token!)
        await rateLimitDelay()

        // Provision device with real keys
        let deviceResult = try await api.provisionDevice(
            name: "test-swift-device",
            identityKey: Data(identityKey.publicKey.serialize()).base64EncodedString(),
            registrationId: registrationId,
            signedPreKey: [
                "keyId": 1,
                "publicKey": Data(signedPreKeyPublic.serialize()).base64EncodedString(),
                "signature": Data(signedPreKeySignature).base64EncodedString(),
            ],
            oneTimePreKeys: oneTimePreKeys
        )

        let deviceToken = deviceResult["token"] as? String
        XCTAssertNotNil(deviceToken, "Device provisioning should return device-scoped token")

        let deviceId = APIClient.extractDeviceId(deviceToken!)
        XCTAssertNotNil(deviceId, "Device token should have deviceId claim")

        let userId = APIClient.extractUserId(deviceToken!)
        XCTAssertNotNil(userId)

        print("SUCCESS: Registered \(username) with real Signal keys")
        print("  userId: \(userId!)")
        print("  deviceId: \(deviceId!)")
    }
}
