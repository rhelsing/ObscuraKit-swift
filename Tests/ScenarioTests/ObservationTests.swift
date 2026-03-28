import XCTest
@testable import ObscuraKit

/// Test reactive observation — GRDB ValueObservation pushes changes to AsyncStream.
/// These prove that SwiftUI views will re-render automatically on data changes.
final class ObservationTests: XCTestCase {

    // MARK: - Friends observation

    func testFriendsObservationEmitsOnAdd() async throws {
        let actor = try FriendActor()

        var emitted: [[Friend]] = []
        let expectation = XCTestExpectation(description: "stream emits")

        let task = Task {
            for await friends in actor.observeAccepted().values {
                emitted.append(friends)
                if emitted.count >= 2 { // initial + after add
                    expectation.fulfill()
                    break
                }
            }
        }

        // Wait for initial emission (empty)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Add a friend — should trigger second emission
        await actor.add("alice-id", "alice", status: .accepted)

        await fulfillment(of: [expectation], timeout: 5)
        task.cancel()

        // First emission: empty (initial state)
        XCTAssertEqual(emitted[0].count, 0)
        // Second emission: 1 friend (after add)
        XCTAssertEqual(emitted[1].count, 1)
        XCTAssertEqual(emitted[1][0].username, "alice")
    }

    func testFriendsObservationEmitsOnStatusChange() async throws {
        let actor = try FriendActor()

        // Add a pending friend first
        await actor.add("bob-id", "bob", status: .pendingReceived)

        var emitted: [[Friend]] = []
        let expectation = XCTestExpectation(description: "accepted emits")

        let task = Task {
            for await friends in actor.observeAccepted().values {
                emitted.append(friends)
                if emitted.count >= 2 {
                    expectation.fulfill()
                    break
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        // Update status to accepted — should trigger emission
        await actor.updateStatus("bob-id", .accepted)

        await fulfillment(of: [expectation], timeout: 5)
        task.cancel()

        XCTAssertEqual(emitted[0].count, 0, "Initially no accepted friends")
        XCTAssertEqual(emitted[1].count, 1, "After accept, one friend")
    }

    // MARK: - Messages observation

    func testMessagesObservationEmitsOnAdd() async throws {
        let actor = try MessageActor()

        var emitted: [[Message]] = []
        let expectation = XCTestExpectation(description: "messages emit")

        let task = Task {
            for await messages in actor.observeMessages("alice").values {
                emitted.append(messages)
                if emitted.count >= 2 {
                    expectation.fulfill()
                    break
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await actor.add("alice", Message(messageId: "m1", conversationId: "alice", content: "hello"))

        await fulfillment(of: [expectation], timeout: 5)
        task.cancel()

        XCTAssertEqual(emitted[0].count, 0, "Initially empty")
        XCTAssertEqual(emitted[1].count, 1, "After add, one message")
        XCTAssertEqual(emitted[1][0].content, "hello")
    }

    // MARK: - Devices observation

    func testDevicesObservationEmitsOnAdd() async throws {
        let actor = try DeviceActor()

        var emitted: [[OwnDevice]] = []
        let expectation = XCTestExpectation(description: "devices emit")

        let task = Task {
            for await devices in actor.observeOwnDevices().values {
                emitted.append(devices)
                if emitted.count >= 2 {
                    expectation.fulfill()
                    break
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await actor.addOwnDevice(OwnDevice(deviceUUID: "uuid1", deviceId: "dev1", deviceName: "iPhone"))

        await fulfillment(of: [expectation], timeout: 5)
        task.cancel()

        XCTAssertEqual(emitted[0].count, 0)
        XCTAssertEqual(emitted[1].count, 1)
        XCTAssertEqual(emitted[1][0].deviceName, "iPhone")
    }

    // MARK: - Conversation list observation

    func testConversationListUpdates() async throws {
        let actor = try MessageActor()

        var emitted: [[String]] = []
        let expectation = XCTestExpectation(description: "conversations emit")

        let task = Task {
            for await ids in actor.observeConversationIds().values {
                emitted.append(ids)
                if emitted.count >= 3 {
                    expectation.fulfill()
                    break
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await actor.add("alice", Message(messageId: "m1", conversationId: "alice", content: "hi"))
        try await Task.sleep(nanoseconds: 100_000_000)
        await actor.add("bob", Message(messageId: "m2", conversationId: "bob", content: "hey"))

        await fulfillment(of: [expectation], timeout: 5)
        task.cancel()

        XCTAssertEqual(emitted[0].count, 0, "Initially no conversations")
        XCTAssertEqual(emitted[1].count, 1, "After first message, 1 conversation")
        XCTAssertEqual(emitted[2].count, 2, "After second, 2 conversations")
    }
}
