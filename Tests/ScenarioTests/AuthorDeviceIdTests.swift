import XCTest
@testable import ObscuraKit

/// Swift counterpart to Kotlin's `AuthorDeviceIdTests.kt` — `obscura-proto/PLAN.md` Phase 2
/// acceptance: **`authorDeviceId` is HONEST.**
///
/// F4 background: pre-Phase-2 the `Envelope` carried no sender device, so this kit assumed device 1
/// on the inbound side and `ReceivedMessage.senderDeviceId` was hardcoded `nil`, while
/// `routeMessage` passed `sourceUserId` into the `authorDeviceId` slot — a USER id in a field
/// documented as a DEVICE id. `RESET.md` called that "a security property being asserted falsely".
///
/// Phase 2 stamps `Envelope.sender_device_id` server-side from the sender's device-scoped JWT, and
/// derives attribution from the address of the session that decrypted: a valid MAC proves possession
/// of that session's chain key, which only the sender's device holds (`SPEC.md` §0.10 rule 4).
///
/// This asserts the attribution is the sender's **real device UUID**, on the wake-up and on the
/// durably persisted message, and emphatically **not** the user id.
final class AuthorDeviceIdTests: XCTestCase {

    func testAuthorDeviceIdIsTheSendersRealDeviceUUIDNeverTheUserId() async throws {
        let (alice, bob) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        let bobDeviceId = try XCTUnwrap(bob.deviceId, "Bob must have a device id")
        let bobUserId = try XCTUnwrap(bob.userId, "Bob must have a user id")
        XCTAssertNotEqual(bobDeviceId, bobUserId,
            "device UUID and user UUID must differ, or this test cannot distinguish them")

        try await bob.send(to: alice.userId!, "attribute me correctly")

        let received = try await alice.waitForMessage(timeout: 15)
        XCTAssertEqual(received.text, "attribute me correctly")
        XCTAssertEqual(received.sourceUserId, bobUserId, "sourceUserId is Bob's USER id")

        // The wake-up carries the sender's real DEVICE UUID — not nil (the old hardcoded value),
        // and not the user id (the F4 lie).
        let senderDeviceId = try XCTUnwrap(received.senderDeviceId,
            "senderDeviceId must be populated — it was hardcoded nil before Phase 2")
        XCTAssertEqual(senderDeviceId, bobDeviceId, "senderDeviceId must be Bob's REAL device UUID")
        XCTAssertNotEqual(senderDeviceId, bobUserId,
            "senderDeviceId must NOT be the user id — that was the F4 lie")

        try await Task.sleep(nanoseconds: 500_000_000)

        // The DURABLY PERSISTED message records the honest device id too. Attribution that is right
        // in the wake-up and wrong on disk is still wrong, and the app reads the store.
        let persisted = await alice.messages.getMessages(bobUserId)
        let msg = try XCTUnwrap(persisted.first { $0.content == "attribute me correctly" },
            "message must be persisted in Alice's conversation with Bob")
        XCTAssertEqual(msg.authorDeviceId, bobDeviceId,
            "persisted authorDeviceId must be Bob's REAL device UUID")
        XCTAssertNotEqual(msg.authorDeviceId, bobUserId,
            "persisted authorDeviceId must NOT be the user id")

        print("PROVEN: authorDeviceId=\(msg.authorDeviceId ?? "nil") == bob.deviceId=\(bobDeviceId) "
            + "(bob.userId=\(bobUserId))")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
