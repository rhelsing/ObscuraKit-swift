import XCTest
import LibSignalClient
@testable import ObscuraKit

/// Test Signal session establishment and encrypt/decrypt using official libsignal
final class SignalSessionTests: XCTestCase {

    // MARK: - Helpers

    struct TestUser {
        let identityKeyPair: IdentityKeyPair
        let registrationId: UInt32
        let signedPreKeyId: UInt32
        let signedPreKeyPair: PrivateKey
        let signedPreKeySignature: [UInt8]
        let preKeyId: UInt32
        let preKeyPair: PrivateKey
        let store: InMemorySignalProtocolStore

        static func create() throws -> TestUser {
            let identityKey = IdentityKeyPair.generate()
            let registrationId = UInt32.random(in: 1...16380)

            let signedPreKeyPair = PrivateKey.generate()
            let signedPreKeySignature = identityKey.privateKey.generateSignature(
                message: signedPreKeyPair.publicKey.serialize()
            )

            let preKeyPair = PrivateKey.generate()

            let store = InMemorySignalProtocolStore(
                identity: identityKey,
                registrationId: registrationId
            )

            // Store the pre-keys
            try store.storePreKey(
                PreKeyRecord(id: 1, publicKey: preKeyPair.publicKey, privateKey: preKeyPair),
                id: 1,
                context: NullContext()
            )
            try store.storeSignedPreKey(
                SignedPreKeyRecord(
                    id: 1,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    privateKey: signedPreKeyPair,
                    signature: signedPreKeySignature
                ),
                id: 1,
                context: NullContext()
            )

            return TestUser(
                identityKeyPair: identityKey,
                registrationId: registrationId,
                signedPreKeyId: 1,
                signedPreKeyPair: signedPreKeyPair,
                signedPreKeySignature: signedPreKeySignature,
                preKeyId: 1,
                preKeyPair: preKeyPair,
                store: store
            )
        }

        /// Build a PreKeyBundle that another user can use to establish a session
        func makePreKeyBundle() throws -> PreKeyBundle {
            try PreKeyBundle(
                registrationId: registrationId,
                deviceId: 1,
                prekeyId: preKeyId,
                prekey: preKeyPair.publicKey,
                signedPrekeyId: signedPreKeyId,
                signedPrekey: signedPreKeyPair.publicKey,
                signedPrekeySignature: signedPreKeySignature,
                identity: identityKeyPair.identityKey
            )
        }
    }

    // MARK: - Tests

    func testLocalEncryptDecrypt() throws {
        let alice = try TestUser.create()
        let bob = try TestUser.create()

        // Alice processes Bob's pre-key bundle (X3DH key agreement)
        let bobAddress = try ProtocolAddress(name: "bob-user-id", deviceId: 1)
        let bobBundle = try bob.makePreKeyBundle()

        try processPreKeyBundle(
            bobBundle,
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )

        // Alice encrypts a message to Bob
        let plaintext = Array("hello bob from alice".utf8)
        let ciphertext = try signalEncrypt(
            message: plaintext,
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )

        // Should be a PreKey message (first message in session)
        XCTAssertEqual(ciphertext.messageType, .preKey)

        // Bob decrypts (using PreKeySignalMessage)
        let aliceAddress = try ProtocolAddress(name: "alice-user-id", deviceId: 1)
        let preKeyMessage = try PreKeySignalMessage(bytes: ciphertext.serialize())

        let decrypted = try signalDecryptPreKey(
            message: preKeyMessage,
            from: aliceAddress,
            sessionStore: bob.store,
            identityStore: bob.store,
            preKeyStore: bob.store,
            signedPreKeyStore: bob.store,
            kyberPreKeyStore: bob.store,
            context: NullContext()
        )

        XCTAssertEqual(decrypted, plaintext)
        XCTAssertEqual(String(bytes: decrypted, encoding: .utf8), "hello bob from alice")
    }

    func testBidirectionalMessaging() throws {
        let alice = try TestUser.create()
        let bob = try TestUser.create()

        let aliceAddress = try ProtocolAddress(name: "alice-id", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob-id", deviceId: 1)

        // Alice → Bob: establish session via PreKey
        try processPreKeyBundle(
            bob.makePreKeyBundle(),
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )

        // Alice sends first message (PreKey)
        let msg1Cipher = try signalEncrypt(
            message: Array("hello bob".utf8),
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )
        XCTAssertEqual(msg1Cipher.messageType, .preKey)

        // Bob decrypts PreKey message
        let msg1Plain = try signalDecryptPreKey(
            message: PreKeySignalMessage(bytes: msg1Cipher.serialize()),
            from: aliceAddress,
            sessionStore: bob.store,
            identityStore: bob.store,
            preKeyStore: bob.store,
            signedPreKeyStore: bob.store,
            kyberPreKeyStore: bob.store,
            context: NullContext()
        )
        XCTAssertEqual(String(bytes: msg1Plain, encoding: .utf8), "hello bob")

        // Bob replies (Whisper message — session already established from PreKey)
        let msg2Cipher = try signalEncrypt(
            message: Array("hello alice".utf8),
            for: aliceAddress,
            sessionStore: bob.store,
            identityStore: bob.store,
            context: NullContext()
        )
        XCTAssertEqual(msg2Cipher.messageType, .whisper, "Second message should be Whisper (not PreKey)")

        // Alice decrypts Whisper message
        let msg2Plain = try signalDecrypt(
            message: SignalMessage(bytes: msg2Cipher.serialize()),
            from: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )
        XCTAssertEqual(String(bytes: msg2Plain, encoding: .utf8), "hello alice")

        // Alice sends another message (also Whisper now)
        let msg3Cipher = try signalEncrypt(
            message: Array("how are you?".utf8),
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )
        XCTAssertEqual(msg3Cipher.messageType, .whisper)

        let msg3Plain = try signalDecrypt(
            message: SignalMessage(bytes: msg3Cipher.serialize()),
            from: aliceAddress,
            sessionStore: bob.store,
            identityStore: bob.store,
            context: NullContext()
        )
        XCTAssertEqual(String(bytes: msg3Plain, encoding: .utf8), "how are you?")
    }

    func testMultiplePreKeysConsumed() throws {
        let alice = try TestUser.create()
        let bob = try TestUser.create()

        let bobAddress = try ProtocolAddress(name: "bob-id", deviceId: 1)

        // Alice establishes session
        try processPreKeyBundle(
            bob.makePreKeyBundle(),
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )

        // First message consumes the one-time pre-key
        let cipher = try signalEncrypt(
            message: Array("test".utf8),
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )
        XCTAssertEqual(cipher.messageType, .preKey)

        // Decrypt should remove the one-time pre-key
        let aliceAddress = try ProtocolAddress(name: "alice-id", deviceId: 1)
        _ = try signalDecryptPreKey(
            message: PreKeySignalMessage(bytes: cipher.serialize()),
            from: aliceAddress,
            sessionStore: bob.store,
            identityStore: bob.store,
            preKeyStore: bob.store,
            signedPreKeyStore: bob.store,
            kyberPreKeyStore: bob.store,
            context: NullContext()
        )

        // Pre-key should be consumed (deleted from store after decrypt)
        XCTAssertThrowsError(try bob.store.loadPreKey(id: 1, context: NullContext()),
                             "Pre-key should be consumed after PreKey message decrypt")
    }

    func testEncryptWithRegistrationIdAddressing() throws {
        // Test that sessions work with (userId, registrationId) addressing
        // This matches the web client's SignalProtocolAddress(userId, registrationId)
        let alice = try TestUser.create()
        let bob = try TestUser.create()

        // Use registrationId as deviceId (matches web client pattern)
        let bobAddress = try ProtocolAddress(name: "bob-user-id", deviceId: bob.registrationId)
        let aliceAddress = try ProtocolAddress(name: "alice-user-id", deviceId: alice.registrationId)

        try processPreKeyBundle(
            bob.makePreKeyBundle(),
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )

        let cipher = try signalEncrypt(
            message: Array("regid test".utf8),
            for: bobAddress,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )

        let plain = try signalDecryptPreKey(
            message: PreKeySignalMessage(bytes: cipher.serialize()),
            from: aliceAddress,
            sessionStore: bob.store,
            identityStore: bob.store,
            preKeyStore: bob.store,
            signedPreKeyStore: bob.store,
            kyberPreKeyStore: bob.store,
            context: NullContext()
        )

        XCTAssertEqual(String(bytes: plain, encoding: .utf8), "regid test")
    }
}
