import XCTest
@testable import ObscuraKit

/// Scenario 8: ORM Layer — against actual server
/// Model CRUD, CRDT sync via encrypted messages
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

    // MARK: - 8.1: Auto-generation

    func testScenario8_1_AutoGeneration() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let id = "story_\(UInt64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
        let entry = makeEntry(id, data: ["content": "hello world"], authorDeviceId: "device-abc")

        let result = await gset.add(entry)
        XCTAssertTrue(result.id.hasPrefix("story_"))
        XCTAssertGreaterThan(result.timestamp, 0)
        XCTAssertEqual(result.authorDeviceId, "device-abc")
    }

    // MARK: - 8.2: Local persistence

    func testScenario8_2_Persistence() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        _ = await gset.add(makeEntry("story_001", data: ["content": "persisted"]))

        // New GSet instance pointing at same store (simulates restart)
        let gset2 = GSet(store: store, modelName: "story")
        let fetched = await gset2.get("story_001")

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.data["content"] as? String, "persisted")
    }

    // MARK: - 8.3: Fan-out via encrypted message to friend

    func testScenario8_3_ModelSyncViaServer() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        // Bob connects to receive
        try await bob.connectWebSocket()
        await rateLimitDelay()

        // Alice sends MODEL_SYNC message
        guard let messenger = alice.messenger else { throw ObscuraClient.ObscuraError.noMessenger }
        let bundles = try await messenger.fetchPreKeyBundles(bob.userId!)
        await rateLimitDelay()

        if let bundle = bundles.first {
            try await messenger.processServerBundle(bundle, userId: bob.userId!)
        }

        var sync = Obscura_V2_ModelSync()
        sync.model = "story"
        sync.id = "story_\(UInt64(Date().timeIntervalSince1970 * 1000))_abc"
        sync.op = .create
        sync.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        sync.data = Data("{\"content\":\"from alice\"}".utf8)
        sync.authorDeviceID = alice.deviceId ?? "unknown"

        var msg = Obscura_V2_ClientMessage()
        msg.type = .modelSync
        msg.modelSync = sync
        msg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let targetDeviceId = bundles.first?["deviceId"] as? String ?? bob.userId!
        try await messenger.queueMessage(
            targetDeviceId: targetDeviceId,
            clientMessageData: try msg.serializedData(),
            targetUserId: bob.userId!
        )
        _ = try await messenger.flushMessages()
        await rateLimitDelay()

        // Bob receives MODEL_SYNC
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 30, "Type should be MODEL_SYNC (30)")
        XCTAssertEqual(received.sourceUserId, alice.userId!)

        bob.disconnectWebSocket()
    }

    // MARK: - 8.5: Receiver can query synced data

    func testScenario8_5_ReceiverQueriesSyncedData() async throws {
        let store = try ModelStore()
        let gset = GSet(store: store, modelName: "story")

        let remote = [
            makeEntry("story_r1", data: ["content": "from alice"], authorDeviceId: "alice-dev"),
            makeEntry("story_r2", data: ["content": "from bob"], authorDeviceId: "bob-dev"),
        ]
        let added = await gset.merge(remote)
        XCTAssertEqual(added.count, 2)

        let aliceStories = await gset.filter { $0.authorDeviceId == "alice-dev" }
        XCTAssertEqual(aliceStories.count, 1)
    }

    // MARK: - 8.6: Bidirectional sync

    func testScenario8_6_BidirectionalSync() async throws {
        let aliceStore = try ModelStore()
        let bobStore = try ModelStore()
        let aliceSet = GSet(store: aliceStore, modelName: "story")
        let bobSet = GSet(store: bobStore, modelName: "story")

        _ = await aliceSet.add(makeEntry("story_a1", data: ["content": "alice's"]))
        _ = await bobSet.add(makeEntry("story_b1", data: ["content": "bob's"]))

        let addedToBob = await bobSet.merge(await aliceSet.getAll())
        let addedToAlice = await aliceSet.merge(await bobSet.getAll())

        XCTAssertEqual(addedToBob.count, 1)
        XCTAssertEqual(addedToAlice.count, 1)

        let aliceSize = await aliceSet.size()
        let bobSize = await bobSet.size()
        XCTAssertEqual(aliceSize, 2)
        XCTAssertEqual(bobSize, 2)
    }

    // MARK: - 8.7: LWW conflict resolution

    func testScenario8_7_ConflictResolution() async throws {
        let store = try ModelStore()
        let lww = LWWMap(store: store, modelName: "streak")

        _ = await lww.set(makeEntry("s1", data: ["count": 5], timestamp: 1000))
        _ = await lww.set(makeEntry("s1", data: ["count": 3], timestamp: 2000))

        let result = await lww.get("s1")
        XCTAssertEqual(result?.timestamp, 2000, "Newer wins")

        _ = await lww.set(makeEntry("s1", data: ["count": 10], timestamp: 500))
        let final_ = await lww.get("s1")
        XCTAssertEqual(final_?.timestamp, 2000, "Older rejected")
    }
}
