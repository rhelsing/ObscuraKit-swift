import XCTest
@testable import ObscuraKit

final class SignalStoreTests: XCTestCase {

    func testStoreAndLoadIdentityKeyPair() async throws {
        let store = try GRDBSignalStore()

        let keyPair = SignalKeyPair(
            publicKey: Data(repeating: 0x05, count: 1) + Data(repeating: 0xAA, count: 32),
            privateKey: Data(repeating: 0xBB, count: 32)
        )

        // Store
        await store.storeIdentityKeyPair(keyPair)

        // Load
        let loaded = await store.getIdentityKeyPair()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.publicKey.count, 33)
        XCTAssertEqual(loaded!.privateKey.count, 32)
        XCTAssertEqual(loaded, keyPair)
    }

    func testStoreAndLoadRegistrationId() async throws {
        let store = try GRDBSignalStore()

        await store.storeLocalRegistrationId(12345)
        let regId = await store.getLocalRegistrationId()
        XCTAssertEqual(regId, 12345)
    }

    func testStoreAndLoadPreKeys() async throws {
        let store = try GRDBSignalStore()

        let preKey = SignalKeyPair(
            publicKey: Data(repeating: 0x05, count: 1) + Data(repeating: 0x11, count: 32),
            privateKey: Data(repeating: 0x22, count: 32)
        )

        await store.storePreKey(42, preKey)

        let loaded = await store.loadPreKey(42)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, preKey)

        // Non-existent key
        let missing = await store.loadPreKey(999)
        XCTAssertNil(missing)

        // Remove
        await store.removePreKey(42)
        let removed = await store.loadPreKey(42)
        XCTAssertNil(removed)
    }

    func testStoreAndLoadSignedPreKeys() async throws {
        let store = try GRDBSignalStore()

        let signedPreKey = SignalSignedPreKey(
            keyId: 1,
            keyPair: SignalKeyPair(
                publicKey: Data(repeating: 0x05, count: 1) + Data(repeating: 0x33, count: 32),
                privateKey: Data(repeating: 0x44, count: 32)
            ),
            signature: Data(repeating: 0x55, count: 64)
        )

        await store.storeSignedPreKey(1, signedPreKey)

        let loaded = await store.loadSignedPreKey(1)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.keyId, 1)
        XCTAssertEqual(loaded!.signature.count, 64)
        XCTAssertEqual(loaded, signedPreKey)
    }

    func testStoreAndLoadSessions() async throws {
        let store = try GRDBSignalStore()

        let address = "user123.456"
        let sessionData = Data("fake-session-record".utf8)

        await store.storeSession(address, sessionData)

        let loaded = await store.loadSession(address)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, sessionData)

        // Remove
        await store.removeSession(address)
        let removed = await store.loadSession(address)
        XCTAssertNil(removed)
    }

    func testRemoveSessionsForUser() async throws {
        let store = try GRDBSignalStore()

        // Store sessions for user "alice" with different registration IDs
        await store.storeSession("alice.100", Data("session1".utf8))
        await store.storeSession("alice.200", Data("session2".utf8))
        await store.storeSession("bob.300", Data("session3".utf8))

        // Remove all sessions for alice
        await store.removeSessionsForUser("alice")

        let alice100 = await store.loadSession("alice.100")
        let alice200 = await store.loadSession("alice.200")
        let bob300 = await store.loadSession("bob.300")
        XCTAssertNil(alice100)
        XCTAssertNil(alice200)
        // Bob's session should survive
        XCTAssertNotNil(bob300)
    }

    func testTrustedIdentityTOFU() async throws {
        let store = try GRDBSignalStore()

        let address = "alice.1"
        let key1 = Data(repeating: 0xAA, count: 33)
        let key2 = Data(repeating: 0xBB, count: 33)

        // Trust on first use — no stored key, should trust anything
        let trusted1 = await store.isTrustedIdentity(address, key1)
        XCTAssertTrue(trusted1)

        // Save identity
        await store.saveIdentity(address, key1)

        // Same key should still be trusted
        let trusted2 = await store.isTrustedIdentity(address, key1)
        XCTAssertTrue(trusted2)

        // Different key should NOT be trusted
        let trusted3 = await store.isTrustedIdentity(address, key2)
        XCTAssertFalse(trusted3)
    }
}
