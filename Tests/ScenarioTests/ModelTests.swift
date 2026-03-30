import XCTest
@testable import ObscuraKit

/// Unit tests for ORM Model class — schema, CRUD, validation, handleSync, delete.
/// Matches Android's ModelTests pattern. No server, no network.
final class ModelTests: XCTestCase {

    private func makeModel(
        name: String = "story",
        sync: SyncStrategy = .gset,
        fields: [String: FieldType] = [:],
        isPrivate: Bool = false
    ) throws -> Model {
        let def = ModelDefinition(
            name: name,
            sync: sync,
            fields: fields,
            isPrivate: isPrivate
        )
        let store = try ModelStore()
        let model = Model(name: name, definition: def, store: store)
        model.deviceId = "test-device-1"
        return model
    }

    // MARK: - Schema

    func testDefineAndRetrieveModel() throws {
        let model = try makeModel(name: "story", sync: .gset)
        XCTAssertEqual(model.name, "story")
        XCTAssertEqual(model.definition.sync, .gset)
    }

    func testMultiModelIsolation() async throws {
        let store = try ModelStore()
        let storyDef = ModelDefinition(name: "story", sync: .gset)
        let profileDef = ModelDefinition(name: "profile", sync: .lwwMap)

        let story = Model(name: "story", definition: storyDef, store: store)
        story.deviceId = "d1"
        let profile = Model(name: "profile", definition: profileDef, store: store)
        profile.deviceId = "d1"

        _ = try await story.create([:])
        _ = try await profile.create([:])

        let stories = await story.all()
        let profiles = await profile.all()
        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(profiles.count, 1)
    }

    // MARK: - Create

    func testCreate_generatesIdAndTimestamp() async throws {
        let model = try makeModel()
        let entry = try await model.create(["content": "hello"])

        XCTAssertTrue(entry.id.hasPrefix("story_"))
        XCTAssertGreaterThan(entry.timestamp, 0)
        XCTAssertEqual(entry.authorDeviceId, "test-device-1")
    }

    func testCreate_immediatelyFindable() async throws {
        let model = try makeModel()
        let entry = try await model.create(["content": "hello"])

        let found = await model.find(entry.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, entry.id)
    }

    func testCreate_multipleEntriesQueryable() async throws {
        let model = try makeModel()
        _ = try await model.create(["content": "one"])
        _ = try await model.create(["content": "two"])
        _ = try await model.create(["content": "three"])

        let all = await model.all()
        XCTAssertEqual(all.count, 3)
    }

    // MARK: - Validation

    func testValidation_missingRequiredThrows() async throws {
        let model = try makeModel(fields: ["title": .string, "count": .number])

        do {
            _ = try await model.create(["count": 5])
            XCTFail("Should throw for missing required field")
        } catch let error as Model.ModelError {
            XCTAssertTrue("\(error)".contains("title"))
        }
    }

    func testValidation_optionalCanBeNil() async throws {
        let model = try makeModel(fields: ["title": .string, "subtitle": .optionalString])

        // Should not throw — subtitle is optional
        let entry = try await model.create(["title": "hello"])
        XCTAssertNotNil(entry)
    }

    func testValidation_wrongTypeThrows() async throws {
        let model = try makeModel(fields: ["count": .number])

        do {
            _ = try await model.create(["count": "not a number"])
            XCTFail("Should throw for wrong type")
        } catch let error as Model.ModelError {
            XCTAssertTrue("\(error)".contains("number"))
        }
    }

    // MARK: - Upsert (LWW only)

    func testUpsert_createsIfNotExists() async throws {
        let model = try makeModel(name: "profile", sync: .lwwMap)
        let entry = try await model.upsert("p1", ["name": "Alice"])

        XCTAssertEqual(entry.id, "p1")
        let found = await model.find("p1")
        XCTAssertEqual(found?.data["name"] as? String, "Alice")
    }

    func testUpsert_updatesWithNewerTimestamp() async throws {
        let model = try makeModel(name: "profile", sync: .lwwMap)
        _ = try await model.upsert("p1", ["name": "Alice"])

        // Small delay ensures newer timestamp
        try await Task.sleep(nanoseconds: 1_000_000)
        _ = try await model.upsert("p1", ["name": "Bob"])

        let found = await model.find("p1")
        XCTAssertEqual(found?.data["name"] as? String, "Bob")
    }

    func testUpsert_throwsOnGSet() async throws {
        let model = try makeModel(name: "story", sync: .gset)

        do {
            _ = try await model.upsert("s1", ["content": "hello"])
            XCTFail("Should throw — upsert is LWW only")
        } catch {
            // Expected
        }
    }

    // MARK: - Delete

    func testDelete_tombstoneOnLWW() async throws {
        let model = try makeModel(name: "profile", sync: .lwwMap)
        _ = try await model.upsert("p1", ["name": "Alice"])

        let tombstone = try await model.delete("p1")
        XCTAssertTrue(tombstone.isDeleted)
    }

    func testDelete_throwsOnGSet() async throws {
        let model = try makeModel(name: "story", sync: .gset)
        _ = try await model.create(["content": "hello"])

        do {
            _ = try await model.delete("story_123")
            XCTFail("Should throw — GSet is immutable")
        } catch {
            // Expected
        }
    }

    // MARK: - handleSync

    func testHandleSync_gsetMergesRemoteEntry() async throws {
        let model = try makeModel(name: "story", sync: .gset)

        let remoteEntry = ModelEntry(
            id: "remote_1",
            data: ["content": "from remote"],
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            signature: Data(),
            authorDeviceId: "remote-device"
        )
        let merged = await model.handleSync(remoteEntry)

        XCTAssertEqual(merged.count, 1)
        let found = await model.find("remote_1")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.data["content"] as? String, "from remote")
    }

    func testHandleSync_lwwRespectsTimestamp() async throws {
        let model = try makeModel(name: "profile", sync: .lwwMap)
        _ = try await model.upsert("p1", ["name": "Alice"])

        // Remote entry with older timestamp should lose
        let olderEntry = ModelEntry(
            id: "p1",
            data: ["name": "OldBob"],
            timestamp: 1000,
            signature: Data(),
            authorDeviceId: "remote-device"
        )
        let merged = await model.handleSync(olderEntry)
        XCTAssertEqual(merged.count, 0, "Older timestamp should not update")

        let found = await model.find("p1")
        XCTAssertEqual(found?.data["name"] as? String, "Alice")
    }

    // MARK: - allSorted

    func testAllSorted() async throws {
        let model = try makeModel()
        // Create with small delays to ensure different timestamps
        _ = try await model.create(["content": "first"])
        try await Task.sleep(nanoseconds: 2_000_000)
        _ = try await model.create(["content": "second"])
        try await Task.sleep(nanoseconds: 2_000_000)
        _ = try await model.create(["content": "third"])

        let desc = await model.allSorted(order: .desc)
        XCTAssertEqual(desc.first?.data["content"] as? String, "third")

        let asc = await model.allSorted(order: .asc)
        XCTAssertEqual(asc.first?.data["content"] as? String, "first")
    }
}
