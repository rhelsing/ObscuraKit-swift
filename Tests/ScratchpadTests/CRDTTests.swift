import XCTest
@testable import ObscuraKit

final class CRDTTests: XCTestCase {

    func makeEntry(_ id: String, timestamp: UInt64 = 1000, data: [String: Any] = [:]) -> ModelEntry {
        ModelEntry(id: id, data: data, timestamp: timestamp, signature: Data(), authorDeviceId: "dev1")
    }

    // MARK: - GSet

    func testGSetAddAndGet() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let entry = makeEntry("s1", data: ["content": "hello"])
        let result = await gset.add(entry)
        XCTAssertEqual(result.id, "s1")

        let fetched = await gset.get("s1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, "s1")
    }

    func testGSetIdempotent() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let e1 = makeEntry("s1", timestamp: 1000, data: ["content": "first"])
        let e2 = makeEntry("s1", timestamp: 2000, data: ["content": "second"])

        _ = await gset.add(e1)
        let result = await gset.add(e2)

        // Should return the FIRST entry (idempotent, not overwrite)
        XCTAssertEqual(result.timestamp, 1000)
        let size1 = await gset.size()
        XCTAssertEqual(size1, 1)
    }

    func testGSetMergeDuplicateIgnored() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let e1 = makeEntry("s1")
        let e2 = makeEntry("s2")
        let e3 = makeEntry("s1") // duplicate

        _ = await gset.add(e1)
        _ = await gset.add(e2)

        let added = await gset.merge([e3])
        XCTAssertEqual(added.count, 0, "Duplicate should not be added")
        let size2 = await gset.size()
        XCTAssertEqual(size2, 2)
    }

    func testGSetMergeDisjointSets() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        _ = await gset.add(makeEntry("s1"))
        _ = await gset.add(makeEntry("s2"))

        let remote = [makeEntry("s3"), makeEntry("s4")]
        let added = await gset.merge(remote)

        XCTAssertEqual(added.count, 2)
        let size3 = await gset.size()
        XCTAssertEqual(size3, 4)
    }

    func testGSetSorted() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        _ = await gset.add(makeEntry("s1", timestamp: 100))
        _ = await gset.add(makeEntry("s2", timestamp: 300))
        _ = await gset.add(makeEntry("s3", timestamp: 200))

        let desc = await gset.getAllSorted(order: .desc)
        XCTAssertEqual(desc.map(\.id), ["s2", "s3", "s1"])

        let asc = await gset.getAllSorted(order: .asc)
        XCTAssertEqual(asc.map(\.id), ["s1", "s3", "s2"])
    }

    // MARK: - LWWMap

    func testLWWMapSetNewerWins() async throws {
        let store = try ModelStore()
        let lww = LWWMap(store: store, modelName: "streak")

        let old = makeEntry("k1", timestamp: 1000, data: ["count": 1])
        let new_ = makeEntry("k1", timestamp: 2000, data: ["count": 5])

        _ = await lww.set(old)
        let result = await lww.set(new_)

        XCTAssertEqual(result.timestamp, 2000, "Newer timestamp should win")
    }

    func testLWWMapOlderLoses() async throws {
        let store = try ModelStore()
        let lww = LWWMap(store: store, modelName: "streak")

        let new_ = makeEntry("k1", timestamp: 2000, data: ["count": 5])
        let old = makeEntry("k1", timestamp: 1000, data: ["count": 1])

        _ = await lww.set(new_)
        let result = await lww.set(old)

        XCTAssertEqual(result.timestamp, 2000, "Existing newer entry should win")
    }

    func testLWWMapDeleteTombstone() async throws {
        let store = try ModelStore()
        let lww = LWWMap(store: store, modelName: "streak")

        _ = await lww.set(makeEntry("k1", timestamp: 1000, data: ["count": 1]))
        _ = await lww.delete("k1", authorDeviceId: "dev1")

        let all = await lww.getAllSorted()
        XCTAssertEqual(all.count, 0, "Deleted entries excluded from getAllSorted")

        let raw = await lww.getAll()
        XCTAssertEqual(raw.count, 1, "Tombstone still exists in raw getAll")

        let entry = await lww.get("k1")
        XCTAssertTrue(entry?.isDeleted ?? false)
    }

    func testLWWMapMerge() async throws {
        let store = try ModelStore()
        let lww = LWWMap(store: store, modelName: "settings")

        // Local has k1@1000
        _ = await lww.set(makeEntry("k1", timestamp: 1000))

        // Remote sends k1@2000 (newer) and k2@500 (new key)
        let remote = [
            makeEntry("k1", timestamp: 2000),
            makeEntry("k2", timestamp: 500),
        ]
        let updated = await lww.merge(remote)

        XCTAssertEqual(updated.count, 2, "Both should update (k1 newer, k2 new)")

        let k1 = await lww.get("k1")
        XCTAssertEqual(k1?.timestamp, 2000)
    }

    func testLWWMapMergeOlderIgnored() async throws {
        let store = try ModelStore()
        let lww = LWWMap(store: store, modelName: "settings")

        _ = await lww.set(makeEntry("k1", timestamp: 2000))

        let remote = [makeEntry("k1", timestamp: 1000)]
        let updated = await lww.merge(remote)

        XCTAssertEqual(updated.count, 0, "Older remote entry should be ignored")

        let k1 = await lww.get("k1")
        XCTAssertEqual(k1?.timestamp, 2000)
    }
}
