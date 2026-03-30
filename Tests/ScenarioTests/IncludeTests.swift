import XCTest
@testable import ObscuraKit

/// Tests for include() eager loading — has_many/belongs_to associations.
final class IncludeTests: XCTestCase {

    func testInclude_loadsChildEntries() async throws {
        let client = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")

        // Story has_many comments. Comment belongs_to story.
        let storyDef = ModelDefinition(name: "story", sync: .gset,
                                       fields: ["content": .string], hasMany: ["comment"])
        let commentDef = ModelDefinition(name: "comment", sync: .gset,
                                          fields: ["text": .string, "storyId": .string], belongsTo: ["story"])
        client.schema([storyDef, commentDef])

        let storyModel = client.model("story")!
        let commentModel = client.model("comment")!

        // Create a story
        let story = try await storyModel.create(["content": "sunset photo"])

        // Create comments linked to the story
        _ = try await commentModel.create(["text": "beautiful!", "storyId": story.id])
        _ = try await commentModel.create(["text": "where is this?", "storyId": story.id])

        // Create a comment on a different story (should NOT be included)
        _ = try await commentModel.create(["text": "unrelated", "storyId": "other_story_id"])

        // Query stories with comments included
        let results = await storyModel.where([:]).include("comment").exec()

        XCTAssertEqual(results.count, 1)

        // The story entry should have a "comments" key with 2 child entries
        let comments = results[0].data["comments"] as? [[String: Any]]
        XCTAssertNotNil(comments, "include() should attach child entries")
        XCTAssertEqual(comments?.count, 2)

        let texts = Set(comments?.compactMap { $0["text"] as? String } ?? [])
        XCTAssertEqual(texts, ["beautiful!", "where is this?"])
    }

    func testInclude_noChildrenReturnsEmptyArray() async throws {
        let client = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")

        let storyDef = ModelDefinition(name: "story", sync: .gset,
                                       fields: ["content": .string], hasMany: ["comment"])
        let commentDef = ModelDefinition(name: "comment", sync: .gset,
                                          fields: ["text": .string, "storyId": .string], belongsTo: ["story"])
        client.schema([storyDef, commentDef])

        let storyModel = client.model("story")!

        _ = try await storyModel.create(["content": "no comments yet"])

        let results = await storyModel.where([:]).include("comment").exec()
        XCTAssertEqual(results.count, 1)

        let comments = results[0].data["comments"] as? [[String: Any]]
        XCTAssertNotNil(comments)
        XCTAssertEqual(comments?.count, 0)
    }

    func testInclude_multipleParentsLoadCorrectChildren() async throws {
        let client = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")

        let storyDef = ModelDefinition(name: "story", sync: .gset,
                                       fields: ["content": .string], hasMany: ["comment"])
        let commentDef = ModelDefinition(name: "comment", sync: .gset,
                                          fields: ["text": .string, "storyId": .string], belongsTo: ["story"])
        client.schema([storyDef, commentDef])

        let storyModel = client.model("story")!
        let commentModel = client.model("comment")!

        let story1 = try await storyModel.create(["content": "first story"])
        let story2 = try await storyModel.create(["content": "second story"])

        _ = try await commentModel.create(["text": "comment on first", "storyId": story1.id])
        _ = try await commentModel.create(["text": "comment on second", "storyId": story2.id])
        _ = try await commentModel.create(["text": "another on first", "storyId": story1.id])

        let results = await storyModel.where([:]).include("comment").exec()
        XCTAssertEqual(results.count, 2)

        for result in results {
            let comments = result.data["comments"] as? [[String: Any]] ?? []
            if result.data["content"] as? String == "first story" {
                XCTAssertEqual(comments.count, 2)
            } else {
                XCTAssertEqual(comments.count, 1)
            }
        }
    }
}
