import XCTest
@testable import ObscuraKit

/// ORM auto-sync integration test against live server.
/// Alice defines a "story" model, calls create(), Bob receives MODEL_SYNC automatically.
/// No manual sendModelSync() call. Proves the full ORM loop.
final class ORMAutoSyncTests: XCTestCase {

    func testStoryAutoSyncToFriend() async throws {
        // Register two users, become friends
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        try await ObscuraTestClient.becomeFriends(alice, bob)

        // Define ORM schema on both clients
        let storyDef = ModelDefinition(
            name: "story",
            sync: .gset,
            syncScope: .friends,
            fields: ["content": .string, "authorUsername": .optionalString]
        )
        alice.client.schema([storyDef])
        bob.client.schema([storyDef])

        // Alice creates a story — auto-sync should broadcast to Bob
        let aliceStory = alice.client.model("story")!
        let entry = try await aliceStory.create([
            "content": "sunset from the rooftop",
            "authorUsername": alice.username
        ])

        XCTAssertTrue(entry.id.hasPrefix("story_"))

        // Bob should receive the MODEL_SYNC
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 30, "Should be MODEL_SYNC (type 30)")

        // Bob's ORM should have merged the story
        let bobStory = bob.client.model("story")!
        let bobStories = await bobStory.all()
        XCTAssertEqual(bobStories.count, 1, "Bob should have 1 story")
        XCTAssertEqual(bobStories[0].data["content"] as? String, "sunset from the rooftop")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    func testPrivateModelDoesNotSyncToFriend() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()

        try await ObscuraTestClient.becomeFriends(alice, bob)

        // Define a private model (syncScope: .ownDevices)
        let settingsDef = ModelDefinition(
            name: "settings",
            sync: .lwwMap,
            syncScope: .ownDevices,
            isPrivate: true
        )
        alice.client.schema([settingsDef])
        bob.client.schema([settingsDef])

        // Alice creates private settings
        let aliceSettings = alice.client.model("settings")!
        _ = try await aliceSettings.upsert("alice_settings", ["theme": "dark", "notificationsEnabled": true])

        // Bob should NOT receive anything — wait briefly and confirm empty
        do {
            _ = try await bob.waitForMessage(timeout: 3)
            XCTFail("Bob should NOT receive private model sync")
        } catch {
            // Expected — timeout means no message received
        }

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }
}
