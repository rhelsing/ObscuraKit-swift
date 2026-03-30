import XCTest
@testable import ObscuraKit

// MARK: - Typed models for tests

private struct TestStory: SyncModel {
    static let modelName = "story"
    static let sync: SyncStrategy = .gset
    var content: String
    var authorUsername: String
}

private struct TestProfile: SyncModel {
    static let modelName = "profile"
    static let sync: SyncStrategy = .lwwMap
    var displayName: String
    var bio: String?
}

/// ORM server integration tests — proves the ORM works end-to-end through
/// Signal encryption, protobuf serialization, server relay, and back.
final class ORMServerTests: XCTestCase {

    // MARK: - 1. LWW conflict resolution over the wire

    func testLWWConflict_newerTimestampWinsAcrossDevices() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        let profileDef = ModelDefinition(name: "profile", sync: .lwwMap, syncScope: .friends)
        alice.client.schema([profileDef])
        bob.client.schema([profileDef])

        let aliceProfile = alice.client.model("profile")!
        let bobProfile = bob.client.model("profile")!

        // Alice sets profile with timestamp T
        _ = try await aliceProfile.upsert("shared_profile", ["displayName": "Alice's version"])

        // Bob receives it
        _ = try await bob.waitForMessage(timeout: 10)

        // Small delay ensures Bob's timestamp is newer
        try await Task.sleep(nanoseconds: 10_000_000)

        // Bob overwrites with newer timestamp
        _ = try await bobProfile.upsert("shared_profile", ["displayName": "Bob's version"])

        // Alice receives the update
        _ = try await alice.waitForMessage(timeout: 10)

        // Both should converge to Bob's version (newer timestamp wins)
        let aliceResult = await aliceProfile.find("shared_profile")
        let bobResult = await bobProfile.find("shared_profile")

        XCTAssertEqual(aliceResult?.data["displayName"] as? String, "Bob's version",
                       "Alice should have Bob's newer version")
        XCTAssertEqual(bobResult?.data["displayName"] as? String, "Bob's version",
                       "Bob should have his own newer version")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - 2. Typed model round-trip over the wire

    func testTypedModel_survivesEncryptionRoundTrip() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        // Alice uses typed model
        let aliceStories = alice.client.register(TestStory.self)

        // Bob uses untyped model (simulates different client version)
        let storyDef = ModelDefinition(name: "story", sync: .gset, syncScope: .friends)
        bob.client.schema([storyDef])

        // Alice creates a typed Story
        let created = try await aliceStories.create(
            TestStory(content: "typed round-trip test", authorUsername: alice.username)
        )
        XCTAssertEqual(created.value.content, "typed round-trip test")

        // Bob receives it
        _ = try await bob.waitForMessage(timeout: 10)

        // Bob decodes it as a typed Story too
        let bobStories = TypedModel<TestStory>(model: bob.client.model("story")!)
        let bobAll = await bobStories.all()

        XCTAssertEqual(bobAll.count, 1)
        XCTAssertEqual(bobAll[0].value.content, "typed round-trip test",
                       "Typed struct should survive: Swift → JSON → protobuf → encrypt → server → decrypt → protobuf → JSON → Swift")
        XCTAssertEqual(bobAll[0].value.authorUsername, alice.username)

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - 3. Multiple model types route correctly

    func testMultipleModelTypes_routeToCorrectModel() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        // Both define story + profile
        let storyDef = ModelDefinition(name: "story", sync: .gset, syncScope: .friends)
        let profileDef = ModelDefinition(name: "profile", sync: .lwwMap, syncScope: .friends)
        alice.client.schema([storyDef, profileDef])
        bob.client.schema([storyDef, profileDef])

        let aliceStory = alice.client.model("story")!
        let aliceProfile = alice.client.model("profile")!

        // Alice creates a story AND a profile
        _ = try await aliceStory.create(["content": "hello world"])
        _ = try await aliceProfile.upsert("alice_profile", ["displayName": "Alice"])

        // Bob receives both
        _ = try await bob.waitForMessage(timeout: 10)
        _ = try await bob.waitForMessage(timeout: 10)

        // Verify they landed in the correct models
        let bobStories = await bob.client.model("story")!.all()
        let bobProfiles = await bob.client.model("profile")!.all()

        XCTAssertEqual(bobStories.count, 1, "Story should be in story model")
        XCTAssertEqual(bobProfiles.count, 1, "Profile should be in profile model")

        XCTAssertEqual(bobStories[0].data["content"] as? String, "hello world")
        XCTAssertEqual(bobProfiles[0].data["displayName"] as? String, "Alice")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    // MARK: - 4. ORM content survives file-backed restart

    func testORM_persistsThroughRestart() async throws {
        let dir = NSTemporaryDirectory() + "orm_persist_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let apiURL = "https://obscura.barrelmaker.dev"
        let storyDef = ModelDefinition(name: "story", sync: .gset, syncScope: .friends)

        // Phase 1: Create client, register, create ORM content
        let client1 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        try await client1.register("test_\(Int.random(in: 100000...999999))", "testpass123456")
        await rateLimitDelay()

        client1.schema([storyDef])
        let stories1 = client1.model("story")!
        _ = try await stories1.create(["content": "survives restart"])
        _ = try await stories1.create(["content": "me too"])

        let beforeRestart = await stories1.all()
        XCTAssertEqual(beforeRestart.count, 2)

        // Phase 2: "Restart" — new client from same directory
        client1.disconnect()
        let client2 = try ObscuraClient(apiURL: apiURL, dataDirectory: dir)
        client2.schema([storyDef])
        let stories2 = client2.model("story")!

        let afterRestart = await stories2.all()
        XCTAssertEqual(afterRestart.count, 2, "ORM content should survive restart")

        let contents = Set(afterRestart.compactMap { $0.data["content"] as? String })
        XCTAssertEqual(contents, ["survives restart", "me too"])
    }
}
