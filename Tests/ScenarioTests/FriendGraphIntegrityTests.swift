import XCTest
@testable import ObscuraKit

/// Swift counterpart to Kotlin's `FriendGraphIntegrityTests.kt`.
///
/// The friend graph is the ONLY source of display names (SPEC §0.5, §0.10 rule 5), and the Phase 3
/// kit API puts that name on OS notifications — so a peer's ability to influence its own record is a
/// lock-screen spoofing surface, not a cosmetic bug.
///
/// Both attacks are driven through the attacker's genuine send path; nothing is fabricated at the
/// wire level. Both FAILED against this kit as it stood on 2026-07-25:
///
/// 1. **Self-rename + status downgrade** — `routeMessage`'s `.friendRequest` case called
///    `friends.add()` unconditionally, and `FriendStore` uses `INSERT OR REPLACE`, so an
///    already-accepted friend could re-send a `FriendRequest` to rewrite their stored username and
///    reset their own status to `.pendingReceived` (dropping out of `getAccepted()` and fan-out).
/// 2. **Unsolicited acceptance** — the `.friendResponse` case called `friends.add(..., .accepted)`
///    whenever `accepted` was true, without checking we had ever sent a request. Friendship is not
///    required to deliver a message, so any authenticated stranger could insert themselves as an
///    accepted friend under a name of their choosing.
final class FriendGraphIntegrityTests: XCTestCase {

    func testAcceptedFriendCannotRenameItselfOrResetItsStatus() async throws {
        let (alice, mallory) = try await ObscuraTestClient.registerPairAndBecomeFriends()

        let malloryId = try XCTUnwrap(mallory.userId)
        let before = try XCTUnwrap(await alice.friends.getFriend(malloryId),
            "Mallory must be in Alice's graph before the attack")
        XCTAssertEqual(before.status, .accepted, "precondition: accepted")
        let realName = before.username

        // THE ATTACK: a second FriendRequest from an established friend, claiming a new name.
        var spoof = Obscura_Client_V1_ClientMessage()
        var req = Obscura_Client_V1_FriendRequest()
        req.username = "Mum"
        spoof.friendRequest = req
        spoof.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await mallory.sendRaw(to: try XCTUnwrap(alice.userId), try spoof.serializedData())

        _ = try? await alice.waitForMessage(timeout: 10)
        try await Task.sleep(nanoseconds: 500_000_000)

        let after = try XCTUnwrap(await alice.friends.getFriend(malloryId), "Mallory must still be in the graph")
        print("  stored name before='\(realName)' after='\(after.username)' status=\(after.status.rawValue)")

        XCTAssertEqual(after.username, realName,
            "a peer MUST NOT be able to rewrite its own display name — that name reaches the lock screen")
        XCTAssertNotEqual(after.username, "Mum", "the payload-supplied name must be ignored for a known peer")
        XCTAssertEqual(after.status, .accepted,
            "a peer MUST NOT be able to reset its own status — that silently removes it from fan-out")

        alice.disconnectWebSocket()
        mallory.disconnectWebSocket()
    }

    func testStrangerCannotSelfAcceptIntoTheFriendGraph() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let stranger = try await ObscuraTestClient.register()
        await rateLimitDelay()
        try await alice.connectWebSocket()
        try await stranger.connectWebSocket()
        await rateLimitDelay()

        // No friendship in either direction: the stranger simply claims Alice accepted them.
        var forged = Obscura_Client_V1_ClientMessage()
        var resp = Obscura_Client_V1_FriendResponse()
        resp.username = "Mum"
        resp.accepted = true
        forged.friendResponse = resp
        forged.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try await stranger.sendRaw(to: try XCTUnwrap(alice.userId), try forged.serializedData())

        _ = try? await alice.waitForMessage(timeout: 10)
        try await Task.sleep(nanoseconds: 500_000_000)

        let injected = await alice.friends.getFriend(try XCTUnwrap(stranger.userId))
        print("  alice's graph after unsolicited acceptance: \(await alice.friends.getAll().map { ($0.username, $0.status.rawValue) })")
        XCTAssertFalse(injected?.status == .accepted,
            "an unsolicited FRIEND_RESPONSE MUST NOT create an accepted friend — got \(String(describing: injected))")

        alice.disconnectWebSocket()
        stranger.disconnectWebSocket()
    }
}
