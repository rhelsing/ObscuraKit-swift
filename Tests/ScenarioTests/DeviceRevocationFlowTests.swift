import XCTest
import LibSignalClient
@testable import ObscuraKit

/// DEVICE_ANNOUNCE receive behaviour: delivery, trust-on-first-use verification, and the timestamp
/// clamp.
///
/// ## What this file used to be, and why none of it is left
///
/// It was the worst file in the suite, and its vacuity is the direct reason a broken `revokeDevice`
/// survived unnoticed until it was deleted:
///
/// - `testFriendProcessesRevocation` performed the revocation ITSELF — it called
///   `messages.deleteByAuthorDevice` and `friends.updateDevices` by hand and then asserted those two
///   stores had done what they were just told. Deleting the entire `.deviceAnnounce` arm from
///   `routeMessage` left it green.
/// - `testRevokedDeviceSelfBricks` called `devices.clearAll()` / `messages.clearAll()` and asserted
///   they had cleared. There is no self-brick behaviour anywhere in the kit; the test asserted that
///   `DELETE` deletes.
/// - `testRevocationAnnounceDelivery` set `signature = Data(repeating: 0xAA, count: 64)` with the
///   comment "signed with recovery key". It was 64 bytes of 0xAA.
///
/// `DeviceRevocationTests` duplicated two of them verbatim. Everything here now goes through
/// `routeMessage`, so deleting a handler fails a test.
final class DeviceRevocationFlowTests: XCTestCase {

    // MARK: - DeviceAnnounce is delivered and APPLIED

    /// The announce reaches Alice *and changes her friend record*. The old version stopped at the
    /// first half, which any wire test would pass.
    func testDeviceAnnounceUpdatesTheSendersDeviceList() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        var announce = Obscura_Client_V1_DeviceAnnounce()
        var deviceInfo = Obscura_Client_V1_DeviceInfo()
        deviceInfo.deviceID = bob.deviceId ?? ""
        deviceInfo.deviceName = "Bob's Phone"
        announce.devices = [deviceInfo]
        announce.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        var msg = Obscura_Client_V1_ClientMessage()
        msg.deviceAnnounce = announce
        msg.timestamp = announce.timestamp
        try await bob.sendRaw(to: alice.userId!, try msg.serializedData())

        let received = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, "DEVICE_ANNOUNCE")
        XCTAssertEqual(received.sourceUserId, bob.userId!)

        let friend = await alice.friends.getFriend(bob.userId!)
        XCTAssertEqual(friend?.devices.count, 1,
                       "the announce must have been APPLIED, not merely delivered")
        XCTAssertEqual(friend?.devices.first?["deviceId"], bob.deviceId)

        alice.disconnectWebSocket(); bob.disconnectWebSocket()
    }

    // MARK: - The timestamp trap (the reason this file exists at all)

    /// **A remote, uncatchable crash before the clamp.** `updateDevices` binds the announce timestamp
    /// into an INTEGER column three times, and GRDB binds `UInt64` through the non-failable
    /// `Int64(self)` — so a value above `Int64.max` TRAPPED. A Swift trap cannot be caught, so
    /// `processEnvelope`'s do/catch could not contain it: the process died. Friendship is not
    /// required to deliver a message, so any authenticated user could do this to anyone.
    ///
    /// This test would have caught the original bug: reaching the assertions at all means no trap.
    func testAnAnnounceTimestampAboveInt64MaxDoesNotCrashTheStore() async throws {
        let friends = try FriendActor()
        try await friends.add("bob-id", "bob", status: .accepted)

        // 0x8000_0000_0000_0000 — one past Int64.max, the exact value that trapped.
        //
        // Passed RAW, deliberately. An earlier version of this test computed the clamp ITSELF and
        // handed `updateDevices` the already-safe value — so it exercised nothing, and despite its
        // own doc comment it would NOT have caught the original bug. The clamp lives in
        // `ObscuraClient`; this test is about the store surviving a value that reaches it anyway.
        let hostile = UInt64(Int64.max) + 1
        try await friends.updateDevices("bob-id", devices: [["deviceId": "bob-dev1"]],
                                        timestamp: hostile)

        // Reaching this line at all is the assertion: a trap is uncatchable, so a crash here is a
        // dead test process, not a failure message.
        let friend = await friends.getFriend("bob-id")
        XCTAssertEqual(friend?.devices.count, 1)
        XCTAssertLessThanOrEqual(friend!.devicesUpdatedAt, UInt64(Int64.max),
                                 "a hostile timestamp must saturate, not trap and not round-trip")
    }

    /// The LWW guard stays satisfiable — the quieter half of the same defect.
    ///
    /// `WHERE devices_updated_at < ?` means a stored timestamp in the future blocks every later
    /// announce until wall-clock catches up. Unclamped, a hostile value blocked it FOREVER: one
    /// friend with a broken clock permanently froze their own fan-out, with no error anywhere.
    ///
    /// Timestamps here are explicit and strictly ordered rather than read from `Date()`. The earlier
    /// version took two `Date()` readings and required a millisecond to elapse between them — it
    /// passed on one CI run and failed on the next, which is how it got here.
    func testALaterAnnounceStillWinsAfterAClampedOne() async throws {
        let friends = try FriendActor()
        try await friends.add("bob-id", "bob", status: .accepted)

        let clamped = UInt64(Date().timeIntervalSince1970 * 1000) + 60_000
        try await friends.updateDevices("bob-id", devices: [["deviceId": "bob-dev1"]],
                                        timestamp: clamped)
        XCTAssertEqual(await friends.getFriend("bob-id")?.devices.count, 1)

        try await friends.updateDevices("bob-id",
                                        devices: [["deviceId": "bob-dev1"], ["deviceId": "bob-dev2"]],
                                        timestamp: clamped + 1)
        XCTAssertEqual(await friends.getFriend("bob-id")?.devices.count, 2,
                       "a strictly-later announce must win; a poisoned devices_updated_at froze it")
    }

    // MARK: - Trust on first use

    /// The key is pinned from the first announce that carries one. Before this, `recovery_public_key`
    /// was read by `routeMessage` and written by nothing, so verification was dead by construction
    /// and every announce from every sender was accepted unverified.
    func testTheFirstAnnounceCarryingARecoveryKeyPinsIt() async throws {
        let friends = try FriendActor()
        try await friends.add("bob-id", "bob", status: .accepted)
        // Hoisted: XCTAssert* take autoclosures, which cannot contain an `await`.
        let before = await friends.getFriend("bob-id")
        XCTAssertNil(before?.recoveryPublicKey)

        let key = RecoveryKeys.getPublicKey(from: RecoveryKeys.generatePhrase())
        try await friends.pinRecoveryPublicKey("bob-id", key)

        let after = await friends.getFriend("bob-id")
        XCTAssertEqual(after?.recoveryPublicKey, key)
    }

    /// A pin must survive `add` being called again — INSERT OR REPLACE deletes the row, so omitting
    /// the column would silently downgrade a pinned peer back to unverified.
    func testReAddingAFriendDoesNotDropThePinnedRecoveryKey() async throws {
        let friends = try FriendActor()
        try await friends.add("bob-id", "bob", status: .pendingSent)
        let key = RecoveryKeys.getPublicKey(from: RecoveryKeys.generatePhrase())
        try await friends.pinRecoveryPublicKey("bob-id", key)

        try await friends.add("bob-id", "bob", status: .accepted)

        let reloaded = await friends.getFriend("bob-id")
        XCTAssertEqual(reloaded?.recoveryPublicKey, key,
                       "a re-add must not reset a pinned key — that is a silent downgrade to unverified")
    }

    /// A real signature over the real payload verifies; 64 bytes of 0xAA does not. The old
    /// `testRevocationAnnounceDelivery` asserted neither and claimed both.
    func testASignatureOnlyVerifiesAgainstTheKeyThatMadeIt() {
        let phrase = RecoveryKeys.generatePhrase()
        let pubKey = RecoveryKeys.getPublicKey(from: phrase)
        let payload = RecoveryKeys.serializeAnnounceForSigning(
            deviceIds: ["dev-1"], timestamp: 1_700_000_000_000, isRevocation: true
        )

        let signature = RecoveryKeys.sign(phrase: phrase, data: payload)
        XCTAssertTrue(RecoveryKeys.verify(publicKey: pubKey, data: payload, signature: signature))

        XCTAssertFalse(
            RecoveryKeys.verify(publicKey: pubKey, data: payload,
                                signature: Data(repeating: 0xAA, count: 64)),
            "the deleted test shipped exactly this and called it 'signed with recovery key'")

        let otherPubKey = RecoveryKeys.getPublicKey(from: RecoveryKeys.generatePhrase())
        XCTAssertFalse(
            RecoveryKeys.verify(publicKey: otherPubKey, data: payload, signature: signature),
            "a signature must not verify under a different recovery key")

        let tampered = RecoveryKeys.serializeAnnounceForSigning(
            deviceIds: ["dev-1", "dev-attacker"], timestamp: 1_700_000_000_000, isRevocation: true
        )
        XCTAssertFalse(
            RecoveryKeys.verify(publicKey: pubKey, data: tampered, signature: signature),
            "the signature must cover the device list")
    }
}
