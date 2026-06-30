import XCTest
@testable import ObscuraKit

/// Pure unit tests for `SyncManager` delivery targeting — no server, no network, no Signal.
///
/// These nail the confidentiality boundary: which userIds a model entry is actually sent to.
/// Regression guard for the leak where 1:1 directMessage / pix were broadcast to ALL friends
/// (so a mutual friend C saw A↔B's conversation). Mirrors Kotlin SyncTargetingTests.
///
/// Topology: self ("uMe") is friends with alice (uA), bob (uB), carol (uC).
final class SyncTargetingTests: XCTestCase {

    private let selfUserId = "uMe"

    private func friends() -> [Friend] {
        [
            Friend(userId: "uA", username: "alice", status: .accepted),
            Friend(userId: "uB", username: "bob", status: .accepted),
            Friend(userId: "uC", username: "carol", status: .accepted),
        ]
    }

    /// Canonical 1:1 id — mirrors conversationId(myUserId, friendUserId).
    private func conversationId(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    func testDirectMessageScopedToTheOtherParticipantNotOtherFriends() {
        let r = SyncManager.resolveTargets(
            scope: .direct, isPrivate: false,
            entryData: ["conversationId": conversationId(selfUserId, "uB"), "content": "secret"],
            acceptedFriends: friends()
        )
        // self id is filtered out (self handled separately via toSelf); only bob remains.
        XCTAssertEqual(r, .scoped(["uB"]), "DM must reach only bob — never carol/alice")
    }

    func testPixScopedToItsRecipientNotOtherFriends() {
        let r = SyncManager.resolveTargets(
            scope: .direct, isPrivate: false,
            entryData: ["recipientUsername": "alice", "mediaRef": "ref-1"],
            acceptedFriends: friends()
        )
        XCTAssertEqual(r, .scoped(["uA"]), "pix must reach only alice")
    }

    func testStoryBroadcastsToAllFriends() {
        let r = SyncManager.resolveTargets(
            scope: .friends, isPrivate: false,
            entryData: ["content": "hi all"],
            acceptedFriends: friends()
        )
        XCTAssertEqual(r, .allFriends)
    }

    func testPrivateModelStaysOnOwnDevices() {
        let r = SyncManager.resolveTargets(
            scope: .friends, isPrivate: true,
            entryData: ["theme": "dark"],
            acceptedFriends: friends()
        )
        XCTAssertEqual(r, .selfOnly)
    }

    func testOwnDevicesScopeStaysOnOwnDevices() {
        let r = SyncManager.resolveTargets(
            scope: .ownDevices, isPrivate: false,
            entryData: [:],
            acceptedFriends: friends()
        )
        XCTAssertEqual(r, .selfOnly)
    }

    func testDirectWithMalformedConversationIdRefusesInsteadOfBroadcasting() {
        let r = SyncManager.resolveTargets(
            scope: .direct, isPrivate: false,
            entryData: ["conversationId": "uMe_uB_uC", "content": "x"],
            acceptedFriends: friends()
        )
        guard case .refuse = r else {
            return XCTFail("expected .refuse for a malformed direct conversationId, got \(r)")
        }
    }

    func testDirectWithNoRecipientDeclaredRefuses() {
        let r = SyncManager.resolveTargets(
            scope: .direct, isPrivate: false,
            entryData: ["mediaRef": "ref-1"],
            acceptedFriends: friends()
        )
        guard case .refuse = r else {
            return XCTFail("expected .refuse when a direct entry declares no recipient, got \(r)")
        }
    }

    func testDirectToNonFriendSendsToNoOneNeverBroadcasts() {
        // recipientUsername present but not an accepted friend → scoped to [] (self-only via
        // toSelf), never broadcast. Fail-closed (quiet), matching Kotlin pix semantics.
        let r = SyncManager.resolveTargets(
            scope: .direct, isPrivate: false,
            entryData: ["recipientUsername": "stranger"],
            acceptedFriends: friends()
        )
        XCTAssertEqual(r, .scoped([]))
    }

    func testFriendsModelCarryingAConversationIdStillScopes() {
        // A legacy directMessage declared `.friends` that carries a 1:1 conversationId still
        // scopes (backward-compatible), so it doesn't leak either.
        let r = SyncManager.resolveTargets(
            scope: .friends, isPrivate: false,
            entryData: ["conversationId": conversationId(selfUserId, "uB")],
            acceptedFriends: friends()
        )
        XCTAssertEqual(r, .scoped(["uB"]))
    }
}
