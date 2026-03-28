import XCTest
@testable import ObscuraKit

final class ModelStoreTests: XCTestCase {

    func makeEntry(_ id: String, model: String = "story", data: [String: Any] = [:], timestamp: UInt64 = 1000) -> ModelEntry {
        ModelEntry(id: id, data: data, timestamp: timestamp, signature: Data(), authorDeviceId: "dev1")
    }

    func testPutAndGet() async throws {
        let store = try ModelStore()

        let entry = makeEntry("s1", data: ["content": "hello"])
        await store.put("story", entry)

        let fetched = await store.get("story", "s1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, "s1")
        XCTAssertEqual(fetched?.data["content"] as? String, "hello")
    }

    func testGetAll() async throws {
        let store = try ModelStore()

        await store.put("story", makeEntry("s1"))
        await store.put("story", makeEntry("s2"))
        await store.put("streak", makeEntry("k1"))

        let stories = await store.getAll("story")
        XCTAssertEqual(stories.count, 2)

        let streaks = await store.getAll("streak")
        XCTAssertEqual(streaks.count, 1)
    }

    func testDelete() async throws {
        let store = try ModelStore()

        await store.put("story", makeEntry("s1"))
        let exists = await store.has("story", "s1")
        XCTAssertTrue(exists)

        await store.delete("story", "s1")
        let gone = await store.has("story", "s1")
        XCTAssertFalse(gone)
    }

    func testClearModel() async throws {
        let store = try ModelStore()

        await store.put("story", makeEntry("s1"))
        await store.put("story", makeEntry("s2"))
        await store.put("streak", makeEntry("k1"))

        await store.clearModel("story")

        let stories = await store.getAll("story")
        XCTAssertEqual(stories.count, 0)

        let streaks = await store.getAll("streak")
        XCTAssertEqual(streaks.count, 1, "Other models unaffected")
    }

    func testAssociations() async throws {
        let store = try ModelStore()

        await store.addAssociation(parentType: "story", parentId: "s1", childType: "comment", childId: "c1")
        await store.addAssociation(parentType: "story", parentId: "s1", childType: "comment", childId: "c2")
        await store.addAssociation(parentType: "story", parentId: "s2", childType: "comment", childId: "c3")

        let children = await store.getChildren(parentType: "story", parentId: "s1", childType: "comment")
        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(children.contains("c1"))
        XCTAssertTrue(children.contains("c2"))
    }

    func testTTL() async throws {
        let store = try ModelStore()

        let now = UInt64(Date().timeIntervalSince1970 * 1000)

        // Set TTL in the past (already expired)
        await store.setTTL(modelName: "story", id: "s1", expiresAt: now - 1000)
        // Set TTL in the future (not expired)
        await store.setTTL(modelName: "story", id: "s2", expiresAt: now + 86400000)

        let expired = await store.getExpired()
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired[0].id, "s1")

        let ttl = await store.getTTL(modelName: "story", id: "s2")
        XCTAssertNotNil(ttl)
        XCTAssertEqual(ttl, now + 86400000)
    }

    func testDataPersistsJSON() async throws {
        let store = try ModelStore()

        let entry = ModelEntry(
            id: "s1",
            data: [
                "content": "hello world",
                "count": 42,
                "active": true,
            ],
            timestamp: 1000,
            signature: Data([0xFF]),
            authorDeviceId: "dev1"
        )
        await store.put("story", entry)

        let fetched = await store.get("story", "s1")
        XCTAssertEqual(fetched?.data["content"] as? String, "hello world")
        XCTAssertEqual(fetched?.data["count"] as? Int, 42)
        XCTAssertEqual(fetched?.data["active"] as? Bool, true)
        XCTAssertEqual(fetched?.authorDeviceId, "dev1")
    }
}
