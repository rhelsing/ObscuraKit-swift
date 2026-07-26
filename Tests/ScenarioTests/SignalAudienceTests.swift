import XCTest
@testable import ObscuraKit

/// Local copy — `SignalTests` declares its own as `private`, so it is not visible here.
private struct DirectMessageAudienceTest: SyncModel {
    static let modelName = "directMessage"
    static let sync: SyncStrategy = .gset
    var conversationId: String
    var content: String
    var senderUsername: String
}

/// Who receives an ephemeral signal.
///
/// `SignalTests` proves a typing indicator *arrives*. Nothing proved it did not arrive somewhere
/// it shouldn't, and it did: `SyncManager.broadcastSignal` sent every MODEL_SIGNAL to
/// `friends.getAccepted()` while `contextId` carried the canonical two-party
/// `"userIdA_userIdB"` conversation id. Every accepted friend therefore learned, in real time,
/// that you were typing to a *named* third party.
///
/// Three participants are required to see it — a two-party test cannot distinguish "sent to the
/// conversation" from "sent to everyone", which is why the existing suite passed throughout.
///
/// **These assert on the wire, not on `SignalStoreRegistry`.** That store is a process-wide
/// singleton shared by every client in the test process, so "Carol's store holds it" is
/// indistinguishable from "Bob's store holds it" and would pass either way.
final class SignalAudienceTests: XCTestCase {

    private var msgDef: ModelDefinition {
        ModelDefinition(
            name: "directMessage", sync: .gset, syncScope: .friends,
            fields: ["conversationId": .string, "content": .string, "senderUsername": .string]
        )
    }

    /// Alice types to Bob. Carol — Alice's friend, but not in that conversation — must hear nothing.
    func testTypingReachesThePeerAndNotAnUninvolvedFriend() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let carol = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        try await carol.connectWebSocket()
        await rateLimitDelay()

        try await ObscuraTestClient.becomeFriends(alice, bob)
        try await ObscuraTestClient.becomeFriends(alice, carol)

        for c in [alice, bob, carol] { c.client.schema([msgDef]) }
        let aliceMessages = alice.client.register(DirectMessageAudienceTest.self)

        let convId = [alice.userId!, bob.userId!].sorted().joined(separator: "_")
        await aliceMessages.typing(conversationId: convId)

        // The peer must still get it — a fix that silences the feature is not a fix.
        let bobGot = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(bobGot.type, "MODEL_SIGNAL", "the conversation peer must still receive the signal")

        // Carol must receive nothing at all.
        do {
            let leaked = try await carol.waitForMessage(timeout: 5)
            XCTFail("LEAK: an uninvolved friend received \(leaked.type) for a 1:1 conversation")
        } catch {
            // Expected: the wait times out because nothing was ever sent to her.
        }

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
        carol.disconnectWebSocket()
    }

    /// An id that names no conversation must send nothing, and must not wedge the send path.
    func testMalformedConversationIdSendsNothing() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        for c in [alice, bob] { c.client.schema([msgDef]) }
        let aliceMessages = alice.client.register(DirectMessageAudienceTest.self)

        // `SPEC.md` §1.2 says fail loud rather than guess an audience. For an ephemeral signal
        // the correct failure is to send nothing: dropping a typing indicator costs nothing,
        // guessing its audience leaks the conversation.
        await aliceMessages.typing(conversationId: "not-a-conversation-id")
        do {
            let leaked = try await bob.waitForMessage(timeout: 5)
            XCTFail("a signal whose audience cannot be resolved was still sent: \(leaked.type)")
        } catch {
            // Expected.
        }

        // Fail closed, not fall over: the next well-formed signal must still go out.
        let convId = [alice.userId!, bob.userId!].sorted().joined(separator: "_")
        await aliceMessages.typing(conversationId: convId)
        let recovered = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(recovered.type, "MODEL_SIGNAL", "a dropped signal must not wedge the send path")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    /// `routing.json`'s "LEAK GUARD: a malformed 3-party id must fail loud, never broadcast",
    /// asserted on the signal path rather than the entry path.
    func testThreePartyConversationIdIsRefused() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let carol = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        try await carol.connectWebSocket()
        await rateLimitDelay()

        try await ObscuraTestClient.becomeFriends(alice, bob)
        try await ObscuraTestClient.becomeFriends(alice, carol)

        for c in [alice, bob, carol] { c.client.schema([msgDef]) }
        let aliceMessages = alice.client.register(DirectMessageAudienceTest.self)

        let threeParty = [alice.userId!, bob.userId!, carol.userId!].sorted().joined(separator: "_")
        await aliceMessages.typing(conversationId: threeParty)

        for (name, client) in [("bob", bob), ("carol", carol)] {
            do {
                let leaked = try await client.waitForMessage(timeout: 4)
                XCTFail("\(name) received \(leaked.type) for an id that names three participants")
            } catch {
                // Expected.
            }
        }

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
        carol.disconnectWebSocket()
    }
}
