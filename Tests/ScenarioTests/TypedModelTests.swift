import XCTest
@testable import ObscuraKit

// MARK: - Test Model Definitions

struct Story: SyncModel {
    static let modelName = "story"
    static let sync: SyncStrategy = .gset
    static let scope: SyncScope = .friends
    static let ttl: TTL? = .hours(24)

    var content: String
    var authorUsername: String
    var likes: Int?
}

struct Profile: SyncModel {
    static let modelName = "profile"
    static let sync: SyncStrategy = .lwwMap

    var displayName: String
    var bio: String?
}

// MARK: - Tests

/// Tests for typed models and the query DSL.
/// Proves the DX: define a struct, get type-safe CRUD + queries.
final class TypedModelTests: XCTestCase {

    private func makeClient() throws -> ObscuraClient {
        try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
    }

    // MARK: - Typed CRUD

    func testCreate_typedRoundTrip() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        let entry = try await stories.create(Story(content: "sunset", authorUsername: "alice", likes: 10))

        XCTAssertTrue(entry.id.hasPrefix("story_"))
        XCTAssertEqual(entry.value.content, "sunset")
        XCTAssertEqual(entry.value.authorUsername, "alice")
        XCTAssertEqual(entry.value.likes, 10)
    }

    func testFind_typed() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        let created = try await stories.create(Story(content: "hello", authorUsername: "bob"))
        let found = await stories.find(created.id)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.value.content, "hello")
        XCTAssertEqual(found?.value.authorUsername, "bob")
    }

    func testAll_typed() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        try await stories.create(Story(content: "one", authorUsername: "alice"))
        try await stories.create(Story(content: "two", authorUsername: "bob"))

        let all = await stories.all()
        XCTAssertEqual(all.count, 2)

        let contents = Set(all.map(\.value.content))
        XCTAssertEqual(contents, ["one", "two"])
    }

    func testUpsert_typed() async throws {
        let client = try makeClient()
        let profiles = client.register(Profile.self)

        try await profiles.upsert("p1", Profile(displayName: "Alice"))
        try await Task.sleep(nanoseconds: 1_000_000)
        try await profiles.upsert("p1", Profile(displayName: "Alice Updated", bio: "hello world"))

        let found = await profiles.find("p1")
        XCTAssertEqual(found?.value.displayName, "Alice Updated")
        XCTAssertEqual(found?.value.bio, "hello world")
    }

    func testDelete_typed() async throws {
        let client = try makeClient()
        let profiles = client.register(Profile.self)

        try await profiles.upsert("p1", Profile(displayName: "Alice"))
        try await profiles.delete("p1")

        let found = await profiles.find("p1")
        // Tombstoned entries aren't decoded as valid typed values
        XCTAssertNil(found)
    }

    // MARK: - Query DSL

    func testDSL_equals() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        try await stories.create(Story(content: "swift tips", authorUsername: "alice", likes: 10))
        try await stories.create(Story(content: "kotlin guide", authorUsername: "bob", likes: 25))

        // Clean DSL: "authorUsername" == "alice"
        let results = await stories.where { "authorUsername" == "alice" }.exec()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].value.content, "swift tips")
    }

    func testDSL_range() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        try await stories.create(Story(content: "a", authorUsername: "a", likes: 5))
        try await stories.create(Story(content: "b", authorUsername: "b", likes: 15))
        try await stories.create(Story(content: "c", authorUsername: "c", likes: 25))

        // Range: 5 <= likes <= 15
        let results = await stories.where {
            "likes" >= 5
            "likes" <= 15
        }.exec()

        XCTAssertEqual(results.count, 2)
    }

    func testDSL_oneOf() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        try await stories.create(Story(content: "a", authorUsername: "alice"))
        try await stories.create(Story(content: "b", authorUsername: "bob"))
        try await stories.create(Story(content: "c", authorUsername: "carol"))

        let results = await stories.where {
            "authorUsername".oneOf(["alice", "carol"])
        }.exec()

        XCTAssertEqual(results.count, 2)
    }

    func testDSL_contains() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        try await stories.create(Story(content: "Swift tips for beginners", authorUsername: "alice"))
        try await stories.create(Story(content: "Kotlin guide", authorUsername: "bob"))

        let results = await stories.where {
            "content".contains("tips")
        }.exec()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].value.authorUsername, "alice")
    }

    func testDSL_orderByAndLimit() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        try await stories.create(Story(content: "low", authorUsername: "a", likes: 5))
        try await stories.create(Story(content: "high", authorUsername: "b", likes: 25))
        try await stories.create(Story(content: "mid", authorUsername: "c", likes: 15))

        // Top 2 by likes descending
        let results = await stories.where { "likes" >= 0 }
            .orderBy("likes", .desc)
            .limit(2)
            .exec()

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].value.content, "high")
        XCTAssertEqual(results[1].value.content, "mid")
    }

    // MARK: - Filter (closure-based)

    func testFilter_closure() async throws {
        let client = try makeClient()
        let stories = client.register(Story.self)

        try await stories.create(Story(content: "short", authorUsername: "alice"))
        try await stories.create(Story(content: "a much longer piece of content", authorUsername: "bob"))

        let long = await stories.filter { $0.content.count > 10 }
        XCTAssertEqual(long.count, 1)
        XCTAssertEqual(long[0].value.authorUsername, "bob")
    }
}
