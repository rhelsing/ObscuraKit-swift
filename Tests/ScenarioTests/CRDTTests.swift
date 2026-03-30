import XCTest
@testable import ObscuraKit

/// Unit tests for GSet and LWWMap CRDTs.
/// All tests use in-memory ModelStore. No server, no network.
/// Proves the conflict resolution contracts that the ORM relies on.
final class CRDTTests: XCTestCase {

    private func makeStore() throws -> ModelStore {
        try ModelStore()
    }

    private func entry(_ id: String, data: [String: Any] = [:], timestamp: UInt64 = 0, device: String = "device1") -> ModelEntry {
        ModelEntry(
            id: id,
            data: data,
            timestamp: timestamp != 0 ? timestamp : UInt64(Date().timeIntervalSince1970 * 1000),
            signature: Data(),
            authorDeviceId: device
        )
    }

    // MARK: - GSet: Add

    func testGSet_add() async throws {
        let gset = GSet(store: try makeStore(), modelName: "story")
        let e = entry("s1", data: ["content": "hello"])
        let result = await gset.add(e)
        XCTAssertEqual(result.id, "s1")

        let found = await gset.get("s1")
        XCTAssertNotNil(found)
    }

    func testGSet_addIdempotent() async throws {
        let gset = GSet(store: try makeStore(), modelName: "story")
        let e1 = entry("s1", data: ["content": "first"], timestamp: 1000)
        let e2 = entry("s1", data: ["content": "second"], timestamp: 2000)

        _ = await gset.add(e1)
        let result = await gset.add(e2)

        // GSet is add-only: duplicate ID returns the ORIGINAL entry
        XCTAssertEqual(result.timestamp, 1000, "Duplicate add should return original, not overwrite")
    }

    func testGSet_size() async throws {
        let gset = GSet(store: try makeStore(), modelName: "story")
        _ = await gset.add(entry("s1"))
        _ = await gset.add(entry("s2"))
        _ = await gset.add(entry("s3"))
        _ = await gset.add(entry("s1")) // duplicate

        let size = await gset.size()
        XCTAssertEqual(size, 3)
    }

    // MARK: - GSet: Merge

    func testGSet_mergeFromTwoSources() async throws {
        let store = try makeStore()
        let gset = GSet(store: store, modelName: "story")

        // Device 1 adds entries
        _ = await gset.add(entry("s1", device: "device1"))
        _ = await gset.add(entry("s2", device: "device1"))

        // Device 2's entries arrive via sync
        let remote = [
            entry("s3", device: "device2"),
            entry("s4", device: "device2"),
        ]
        let added = await gset.merge(remote)

        XCTAssertEqual(added.count, 2, "Both remote entries should be new")
        let mergedSize = await gset.size()
        XCTAssertEqual(mergedSize, 4, "Union of both sources")
    }

    func testGSet_mergeIdempotent() async throws {
        let gset = GSet(store: try makeStore(), modelName: "story")
        _ = await gset.add(entry("s1"))

        let added = await gset.merge([entry("s1")])
        XCTAssertEqual(added.count, 0, "Re-merging existing entry should add nothing")
    }

    // MARK: - GSet: Sort & Filter

    func testGSet_sortedOutput() async throws {
        let gset = GSet(store: try makeStore(), modelName: "story")
        _ = await gset.add(entry("s1", timestamp: 3000))
        _ = await gset.add(entry("s2", timestamp: 1000))
        _ = await gset.add(entry("s3", timestamp: 2000))

        let desc = await gset.getAllSorted(order: .desc)
        XCTAssertEqual(desc.map(\.id), ["s1", "s3", "s2"])

        let asc = await gset.getAllSorted(order: .asc)
        XCTAssertEqual(asc.map(\.id), ["s2", "s3", "s1"])
    }

    func testGSet_filter() async throws {
        let gset = GSet(store: try makeStore(), modelName: "story")
        _ = await gset.add(entry("s1", device: "device1"))
        _ = await gset.add(entry("s2", device: "device2"))
        _ = await gset.add(entry("s3", device: "device1"))

        let filtered = await gset.filter { $0.authorDeviceId == "device1" }
        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - GSet: Persistence

    func testGSet_persistsAcrossReload() async throws {
        let store = try makeStore()

        // First GSet instance writes data
        let gset1 = GSet(store: store, modelName: "story")
        _ = await gset1.add(entry("s1", data: ["content": "hello"]))
        _ = await gset1.add(entry("s2", data: ["content": "world"]))

        // New GSet instance on same store — simulates reload
        let gset2 = GSet(store: store, modelName: "story")
        let reloadSize = await gset2.size()
        XCTAssertEqual(reloadSize, 2)
        let reloadS1 = await gset2.get("s1")
        let reloadS2 = await gset2.get("s2")
        XCTAssertNotNil(reloadS1)
        XCTAssertNotNil(reloadS2)
    }

    // MARK: - LWWMap: Set

    func testLWWMap_set() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        let e = entry("p1", data: ["name": "Alice"], timestamp: 1000)
        let result = await lww.set(e)
        XCTAssertEqual(result.id, "p1")
    }

    func testLWWMap_newerTimestampWins() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww.set(entry("p1", data: ["name": "Alice"], timestamp: 1000))
        _ = await lww.set(entry("p1", data: ["name": "Bob"], timestamp: 2000))

        let result = await lww.get("p1")
        XCTAssertEqual(result?.data["name"] as? String, "Bob")
        XCTAssertEqual(result?.timestamp, 2000)
    }

    func testLWWMap_olderTimestampLoses() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww.set(entry("p1", data: ["name": "Bob"], timestamp: 2000))
        _ = await lww.set(entry("p1", data: ["name": "Alice"], timestamp: 1000))

        let result = await lww.get("p1")
        XCTAssertEqual(result?.data["name"] as? String, "Bob", "Newer timestamp should win regardless of write order")
    }

    func testLWWMap_concurrentConflictConverges() async throws {
        // Two devices write the same key with different timestamps
        // Result should be the same regardless of merge order
        let device1Entry = entry("p1", data: ["name": "Alice"], timestamp: 1000, device: "device1")
        let device2Entry = entry("p1", data: ["name": "Bob"], timestamp: 2000, device: "device2")

        // Order 1: device1 first
        let lww1 = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww1.set(device1Entry)
        _ = await lww1.set(device2Entry)
        let result1 = await lww1.get("p1")

        // Order 2: device2 first
        let lww2 = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww2.set(device2Entry)
        _ = await lww2.set(device1Entry)
        let result2 = await lww2.get("p1")

        // Both should converge to "Bob" (timestamp 2000 wins)
        XCTAssertEqual(result1?.data["name"] as? String, "Bob")
        XCTAssertEqual(result2?.data["name"] as? String, "Bob")
    }

    // MARK: - LWWMap: Merge

    func testLWWMap_mergeFromRemote() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww.set(entry("p1", data: ["name": "Alice"], timestamp: 1000))

        let remote = [entry("p1", data: ["name": "Bob"], timestamp: 2000, device: "device2")]
        let updated = await lww.merge(remote)

        XCTAssertEqual(updated.count, 1)
        let result = await lww.get("p1")
        XCTAssertEqual(result?.data["name"] as? String, "Bob")
    }

    func testLWWMap_mergeOlderLoses() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww.set(entry("p1", data: ["name": "Bob"], timestamp: 2000))

        let remote = [entry("p1", data: ["name": "Alice"], timestamp: 1000)]
        let updated = await lww.merge(remote)

        XCTAssertEqual(updated.count, 0, "Older remote entry should not update local")
    }

    // MARK: - LWWMap: Tombstone Deletion

    func testLWWMap_tombstoneDelete() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww.set(entry("p1", data: ["name": "Alice"], timestamp: 1000))

        let tombstone = await lww.delete("p1", authorDeviceId: "device1")
        XCTAssertTrue(tombstone.isDeleted)

        // get still returns the entry (it's a tombstone, not gone)
        let result = await lww.get("p1")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.isDeleted)
    }

    func testLWWMap_tombstoneFilteredFromGetAllSorted() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww.set(entry("p1", data: ["name": "Alice"], timestamp: 1000))
        _ = await lww.set(entry("p2", data: ["name": "Bob"], timestamp: 2000))
        _ = await lww.delete("p1", authorDeviceId: "device1")

        let sorted = await lww.getAllSorted()
        XCTAssertEqual(sorted.count, 1, "Deleted entries should be filtered from sorted results")
        XCTAssertEqual(sorted[0].id, "p2")
    }

    func testLWWMap_tombstoneWinsOverOlderWrite() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        _ = await lww.set(entry("p1", data: ["name": "Alice"], timestamp: 1000))
        _ = await lww.delete("p1", authorDeviceId: "device1")

        // Try to set with an older timestamp — tombstone should win
        _ = await lww.set(entry("p1", data: ["name": "Zombie"], timestamp: 500))

        let result = await lww.get("p1")
        XCTAssertTrue(result!.isDeleted, "Tombstone should win over older write")
    }

    // MARK: - LWWMap: Future Timestamp Clamping

    func testLWWMap_futureTimestampClamped() async throws {
        let lww = LWWMap(store: try makeStore(), modelName: "profile")
        let farFuture = UInt64(Date().timeIntervalSince1970 * 1000) + 120_000 // 2 minutes in the future

        _ = await lww.set(entry("p1", data: ["name": "Cheater"], timestamp: farFuture))

        let result = await lww.get("p1")
        XCTAssertNotNil(result)
        // Clamped to max 60 seconds in the future
        let maxAllowed = UInt64(Date().timeIntervalSince1970 * 1000) + 61_000
        XCTAssertLessThan(result!.timestamp, maxAllowed, "Far-future timestamp should be clamped")
        XCTAssertLessThan(result!.timestamp, farFuture, "Should not keep the cheated timestamp")
    }

    // MARK: - LWWMap: Persistence

    func testLWWMap_persistsAcrossReload() async throws {
        let store = try makeStore()

        let lww1 = LWWMap(store: store, modelName: "profile")
        _ = await lww1.set(entry("p1", data: ["name": "Alice"], timestamp: 1000))

        let lww2 = LWWMap(store: store, modelName: "profile")
        let result = await lww2.get("p1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.data["name"] as? String, "Alice")
    }

    // MARK: - Model Isolation

    func testModelsIsolated() async throws {
        let store = try makeStore()
        let stories = GSet(store: store, modelName: "story")
        let profiles = LWWMap(store: store, modelName: "profile")

        _ = await stories.add(entry("s1"))
        _ = await profiles.set(entry("p1"))

        let storyCount = await stories.size()
        let profileCount = await profiles.size()
        XCTAssertEqual(storyCount, 1)
        XCTAssertEqual(profileCount, 1)

        let storyLookup = await stories.get("p1")
        let profileLookup = await profiles.get("s1")
        XCTAssertNil(storyLookup, "Profile entry should not appear in story GSet")
        XCTAssertNil(profileLookup, "Story entry should not appear in profile LWWMap")
    }
}
