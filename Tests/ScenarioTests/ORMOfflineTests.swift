import XCTest
@testable import ObscuraKit

/// ORM offline/rejoin tests against live server.
/// Proves that ORM content survives disconnect/reconnect just like TEXT messages.
final class ORMOfflineTests: XCTestCase {

    private let storyDef = ModelDefinition(
        name: "story",
        sync: .gset,
        syncScope: .friends,
        fields: ["content": .string]
    )

    private let profileDef = ModelDefinition(
        name: "profile",
        sync: .lwwMap,
        syncScope: .friends,
        fields: ["displayName": .string]
    )

    /// Bob is offline when Alice creates a story.
    /// Bob reconnects → server delivers the queued MODEL_SYNC → Bob's CRDT has the story.
    func testORM_offlineRecipientGetsStoryOnReconnect() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Both connect, become friends
        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        // Define ORM on both
        alice.client.schema([storyDef])
        bob.client.schema([storyDef])

        // Bob goes offline
        bob.disconnectWebSocket()
        await rateLimitDelay()

        // Alice creates a story while Bob is offline
        let aliceStory = alice.client.model("story")!
        _ = try await aliceStory.create(["content": "posted while you were gone"])

        await rateLimitDelay()

        // Bob reconnects
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Bob should receive the queued MODEL_SYNC
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 30, "Should be MODEL_SYNC")

        // Bob's ORM should have the story
        let bobStory = bob.client.model("story")!
        let stories = await bobStory.all()
        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(stories[0].data["content"] as? String, "posted while you were gone")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    /// Both sides create stories, then exchange.
    /// Proves CRDT merge — both stories exist on both sides.
    func testORM_bidirectionalSync() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        alice.client.schema([storyDef])
        bob.client.schema([storyDef])

        // Alice creates a story
        let aliceModel = alice.client.model("story")!
        _ = try await aliceModel.create(["content": "alice's story"])

        // Bob receives it
        _ = try await bob.waitForMessage(timeout: 10)

        // Bob creates a story
        let bobModel = bob.client.model("story")!
        _ = try await bobModel.create(["content": "bob's story"])

        // Alice receives it
        _ = try await alice.waitForMessage(timeout: 10)

        // Both should have 2 stories (GSet merge = union)
        let aliceStories = await aliceModel.all()
        let bobStories = await bobModel.all()

        XCTAssertEqual(aliceStories.count, 2, "Alice should have both stories")
        XCTAssertEqual(bobStories.count, 2, "Bob should have both stories")

        let aliceContents = Set(aliceStories.compactMap { $0.data["content"] as? String })
        let bobContents = Set(bobStories.compactMap { $0.data["content"] as? String })
        XCTAssertEqual(aliceContents, ["alice's story", "bob's story"])
        XCTAssertEqual(bobContents, ["alice's story", "bob's story"])

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - LWW conflict resolution after offline

    /// Alice updates profile to v2 then v3 while Bob is offline.
    /// Bob reconnects, receives both, v3 wins by timestamp.
    func testLWWConflict_newerTimestampWinsAfterOffline() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        alice.client.schema([profileDef])
        bob.client.schema([profileDef])

        let aliceProfile = alice.client.model("profile")!

        // Alice sets profile while both online
        _ = try await aliceProfile.upsert("shared_profile", ["displayName": "v1"])
        _ = try await bob.waitForMessage(timeout: 10)

        // Bob goes offline
        bob.disconnectWebSocket()
        await rateLimitDelay()

        // Alice updates profile twice while Bob is away
        _ = try await aliceProfile.upsert("shared_profile", ["displayName": "v2"])
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await aliceProfile.upsert("shared_profile", ["displayName": "v3"])
        await rateLimitDelay()

        // Bob reconnects — should get both updates, final state = v3
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Drain queued messages (v2 and v3 arrive)
        _ = try await bob.waitForMessage(timeout: 10)
        _ = try await bob.waitForMessage(timeout: 10)

        // Bob's LWW should have v3 (newest timestamp wins)
        let bobProfile = bob.client.model("profile")!
        let result = await bobProfile.find("shared_profile")
        XCTAssertEqual(result?.data["displayName"] as? String, "v3",
                       "After reconnect, newest timestamp (v3) should win")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Both sides create while other is offline

    /// Alice creates while Bob is offline, Bob reconnects and gets it.
    /// Then Bob creates while Alice is offline, Alice reconnects and gets it.
    /// GSet union — both entries exist on both sides.
    func testBothSidesCreateWhileOtherOffline() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        alice.client.schema([storyDef])
        bob.client.schema([storyDef])

        // Bob goes offline, Alice creates
        bob.disconnectWebSocket()
        await rateLimitDelay()
        _ = try await alice.client.model("story")!.create(["content": "Alice while Bob offline"])
        await rateLimitDelay()

        // Bob comes back — gets Alice's story
        try await bob.connectWebSocket()
        await rateLimitDelay()
        let fromAlice = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(fromAlice.type, 30)

        // Alice goes offline, Bob creates
        alice.disconnectWebSocket()
        await rateLimitDelay()
        _ = try await bob.client.model("story")!.create(["content": "Bob while Alice offline"])
        await rateLimitDelay()

        // Alice comes back — gets Bob's story
        try await alice.connectWebSocket()
        await rateLimitDelay()
        let fromBob = try await alice.waitForMessage(timeout: 10)
        XCTAssertEqual(fromBob.type, 30)

        // Both should have both stories
        let aliceStories = await alice.client.model("story")!.all()
        let bobStories = await bob.client.model("story")!.all()

        let aliceContents = Set(aliceStories.compactMap { $0.data["content"] as? String })
        let bobContents = Set(bobStories.compactMap { $0.data["content"] as? String })

        XCTAssertEqual(aliceContents, ["Alice while Bob offline", "Bob while Alice offline"])
        XCTAssertEqual(bobContents, ["Alice while Bob offline", "Bob while Alice offline"])

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Typed model survives offline round-trip

    /// Alice creates a typed Story while Bob is offline.
    /// Bob reconnects, receives it, decodes it as a typed Story struct.
    func testTypedModel_survivesOfflineRoundTrip() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        alice.client.schema([storyDef])
        bob.client.schema([storyDef])

        // Bob goes offline
        bob.disconnectWebSocket()
        await rateLimitDelay()

        // Alice creates while Bob is offline
        _ = try await alice.client.model("story")!.create(["content": "typed offline test"])
        await rateLimitDelay()

        // Bob reconnects
        try await bob.connectWebSocket()
        await rateLimitDelay()
        _ = try await bob.waitForMessage(timeout: 10)

        // Bob decodes as typed model
        let bobStories = await bob.client.model("story")!.all()
        XCTAssertEqual(bobStories.count, 1)
        XCTAssertEqual(bobStories[0].data["content"] as? String, "typed offline test")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - Multiple model types survive offline

    /// Alice creates both a story and a profile while Bob is offline.
    /// Bob reconnects, both route to the correct models.
    func testMultipleModelTypes_routeCorrectlyAfterOffline() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        alice.client.schema([storyDef, profileDef])
        bob.client.schema([storyDef, profileDef])

        // Bob goes offline
        bob.disconnectWebSocket()
        await rateLimitDelay()

        // Alice creates a story AND a profile while Bob is offline
        _ = try await alice.client.model("story")!.create(["content": "offline story"])
        _ = try await alice.client.model("profile")!.upsert("alice_profile", ["displayName": "Alice"])
        await rateLimitDelay()

        // Bob reconnects
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Drain both messages
        _ = try await bob.waitForMessage(timeout: 10)
        _ = try await bob.waitForMessage(timeout: 10)

        // Verify routing — each landed in the correct model
        let bobStories = await bob.client.model("story")!.all()
        let bobProfiles = await bob.client.model("profile")!.all()

        XCTAssertEqual(bobStories.count, 1, "Story should be in story model")
        XCTAssertEqual(bobProfiles.count, 1, "Profile should be in profile model")
        XCTAssertEqual(bobStories[0].data["content"] as? String, "offline story")
        XCTAssertEqual(bobProfiles[0].data["displayName"] as? String, "Alice")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
