import XCTest
@testable import ObscuraKit

/// Scenario 8: ORM Layer
/// CRUD, fan-out targets, field validation, sync
final class ORMTests: XCTestCase {

    func makeEntry(_ id: String, data: [String: Any] = [:], timestamp: UInt64 = 0, authorDeviceId: String = "dev1") -> ModelEntry {
        ModelEntry(
            id: id,
            data: data,
            timestamp: timestamp != 0 ? timestamp : UInt64(Date().timeIntervalSince1970 * 1000),
            signature: Data(),
            authorDeviceId: authorDeviceId
        )
    }

    // MARK: - 8.1: Auto-generation (ID, timestamp, signature, author)

    func testScenario8_1_StoryCreation() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let id = "story_\(UInt64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
        let entry = makeEntry(id, data: ["content": "hello world"], authorDeviceId: "device-abc")

        let result = await gset.add(entry)

        XCTAssertEqual(result.id, id)
        XCTAssertTrue(result.id.hasPrefix("story_"))
        XCTAssertGreaterThan(result.timestamp, 0)
        XCTAssertEqual(result.authorDeviceId, "device-abc")
    }

    // MARK: - 8.2: Local persistence via finder

    func testScenario8_2_LocalPersistence() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let entry = makeEntry("story_001", data: ["content": "persisted"])
        _ = await gset.add(entry)

        // Create a NEW GSet pointing at same store (simulates app restart)
        let gset2 = GSet(store: store, modelName: "story")
        let fetched = await gset2.get("story_001")

        XCTAssertNotNil(fetched, "Entry should persist in store across GSet instances")
        XCTAssertEqual(fetched?.data["content"] as? String, "persisted")
    }

    // MARK: - 8.3: Fan-out targeting (all friend devices)

    func testScenario8_3_FanOutTargets() async throws {
        let friends = try FriendActor()

        // Add friends with devices
        await friends.add("user1", "alice", status: .accepted, devices: [
            ["deviceId": "d1", "deviceUUID": "uuid1"],
            ["deviceId": "d2", "deviceUUID": "uuid2"],
        ])
        await friends.add("user2", "bob", status: .accepted, devices: [
            ["deviceId": "d3", "deviceUUID": "uuid3"],
        ])
        await friends.add("user3", "carol", status: .pendingReceived)

        // Accepted friends only
        let accepted = await friends.getAccepted()
        XCTAssertEqual(accepted.count, 2, "Only accepted friends")

        // All devices across accepted friends
        let allDevices = accepted.flatMap(\.devices)
        XCTAssertEqual(allDevices.count, 3, "3 devices across 2 friends")
    }

    // MARK: - 8.4: Self-sync targeting (own devices)

    func testScenario8_4_SelfSyncTargets() async throws {
        let deviceActor = try DeviceActor()

        await deviceActor.addOwnDevice(OwnDevice(deviceUUID: "uuid1", deviceId: "d1", deviceName: "iPhone"))
        await deviceActor.addOwnDevice(OwnDevice(deviceUUID: "uuid2", deviceId: "d2", deviceName: "iPad"))

        let targets = await deviceActor.getSelfSyncTargets()
        XCTAssertEqual(targets.count, 2)
    }

    // MARK: - 8.5: Receiver queries synced data

    func testScenario8_5_ReceiverQueriesSyncedData() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        // Simulate receiving synced entries from remote
        let remote = [
            makeEntry("story_r1", data: ["content": "from alice"], authorDeviceId: "alice-dev"),
            makeEntry("story_r2", data: ["content": "from bob"], authorDeviceId: "bob-dev"),
        ]
        let added = await gset.merge(remote)
        XCTAssertEqual(added.count, 2)

        // Query all
        let all = await gset.getAll()
        XCTAssertEqual(all.count, 2)

        // Filter by author
        let aliceStories = await gset.filter { $0.authorDeviceId == "alice-dev" }
        XCTAssertEqual(aliceStories.count, 1)
        XCTAssertEqual(aliceStories[0].data["content"] as? String, "from alice")
    }

    // MARK: - 8.6: Reverse direction sync

    func testScenario8_6_ReverseSync() async throws {
        let aliceStore = try ModelStore()
        let bobStore = try ModelStore()

        let aliceSet = GSet(store: aliceStore, modelName: "story")
        let bobSet = GSet(store: bobStore, modelName: "story")

        // Alice creates a story
        let aliceEntry = makeEntry("story_a1", data: ["content": "alice's story"], authorDeviceId: "alice-dev")
        _ = await aliceSet.add(aliceEntry)

        // Bob creates a story
        let bobEntry = makeEntry("story_b1", data: ["content": "bob's story"], authorDeviceId: "bob-dev")
        _ = await bobSet.add(bobEntry)

        // Sync: Alice → Bob
        let aliceAll = await aliceSet.getAll()
        let addedToBob = await bobSet.merge(aliceAll)
        XCTAssertEqual(addedToBob.count, 1)

        // Sync: Bob → Alice
        let bobAll = await bobSet.getAll()
        let addedToAlice = await aliceSet.merge(bobAll)
        XCTAssertEqual(addedToAlice.count, 1)

        // Both should have 2 entries
        let aliceSize = await aliceSet.size()
        let bobSize = await bobSet.size()
        XCTAssertEqual(aliceSize, 2)
        XCTAssertEqual(bobSize, 2)
    }

    // MARK: - 8.7: LWW conflict resolution

    func testScenario8_7_LWWConflictResolution() async throws {
        let store = try ModelStore()
        let lww = LWWMap(store: store, modelName: "streak")

        // Alice sets count=5 at time 1000
        _ = await lww.set(makeEntry("streak_1", data: ["count": 5], timestamp: 1000, authorDeviceId: "alice"))

        // Bob sets count=3 at time 2000 (newer)
        _ = await lww.set(makeEntry("streak_1", data: ["count": 3], timestamp: 2000, authorDeviceId: "bob"))

        let result = await lww.get("streak_1")
        XCTAssertEqual(result?.timestamp, 2000, "Newer timestamp wins")

        // Alice tries to set count=10 at time 500 (older — should lose)
        _ = await lww.set(makeEntry("streak_1", data: ["count": 10], timestamp: 500, authorDeviceId: "alice"))

        let final_ = await lww.get("streak_1")
        XCTAssertEqual(final_?.timestamp, 2000, "Older update rejected")
    }
}
