import XCTest
@testable import ObscuraKit

/// Tests for ECS model signals — typing indicators, read receipts.
/// Online: signal arrives at receiver. Offline: signals are dropped (ephemeral).
final class SignalTests: XCTestCase {

    /// Online: Alice sends typing signal, Bob receives it in SignalStore.
    func testTypingSignal_receivedByFriend() async throws {
        let alice = try await ObscuraTestClient.register()
        await rateLimitDelay()
        let bob = try await ObscuraTestClient.register()
        await rateLimitDelay()

        try await alice.connectWebSocket()
        try await bob.connectWebSocket()
        await rateLimitDelay()
        try await ObscuraTestClient.becomeFriends(alice, bob)

        // Define directMessage model on both
        let msgDef = ModelDefinition(name: "directMessage", sync: .gset, syncScope: .friends,
                                     fields: ["conversationId": .string, "content": .string, "senderUsername": .string])
        alice.client.schema([msgDef])
        bob.client.schema([msgDef])

        let aliceMessages = alice.client.register(DirectMessageTest.self)
        let convId = [alice.userId!, bob.userId!].sorted().joined(separator: "_")

        // Alice sends typing signal
        await aliceMessages.typing(conversationId: convId)

        // Bob should receive it (MODEL_SIGNAL type 31)
        let received = try await bob.waitForMessage(timeout: 10)
        XCTAssertEqual(received.type, 31, "Should be MODEL_SIGNAL")

        // Check SignalStore has the typing indicator
        let active = await SignalStoreRegistry.shared.store.getActive(
            model: "directMessage", signal: "typing",
            data: ["conversationId": convId]
        )
        XCTAssertFalse(active.isEmpty, "Bob's SignalStore should have Alice's typing indicator")

        alice.disconnectWebSocket()
        bob.disconnectWebSocket()
    }

    /// Offline: signals from while offline should be dropped (stale > 5s).
    func testTypingSignal_droppedWhenStale() async throws {
        // Directly test the SignalStore's staleness check
        let store = SignalStore()

        // Create a signal with a timestamp 10 seconds in the past
        let stalePayload = ModelSignalPayload(
            model: "directMessage",
            signal: .typing,
            data: ["conversationId": "conv1"],
            authorDeviceId: "device1"
        )
        // Manually create a stale version
        let staleData = """
        {"model":"directMessage","signal":"typing","data":{"conversationId":"conv1"},"authorDeviceId":"device1","timestamp":\(UInt64(Date().timeIntervalSince1970 * 1000) - 10_000)}
        """.data(using: .utf8)!
        let stale = try JSONDecoder().decode(ModelSignalPayload.self, from: staleData)

        await store.receive(stale)

        let active = await store.getActive(
            model: "directMessage", signal: "typing",
            data: ["conversationId": "conv1"]
        )
        XCTAssertTrue(active.isEmpty, "Stale signal (>5s old) should be dropped")
    }

    /// Signal auto-expires after 3 seconds.
    func testTypingSignal_autoExpires() async throws {
        let store = SignalStore()

        let payload = ModelSignalPayload(
            model: "directMessage",
            signal: .typing,
            data: ["conversationId": "conv1"],
            authorDeviceId: "device1"
        )
        await store.receive(payload)

        // Should be active immediately
        let activeBefore = await store.isActive(
            model: "directMessage", signal: "typing",
            data: ["conversationId": "conv1"]
        )
        XCTAssertTrue(activeBefore)

        // Wait for expiry (5 seconds + buffer)
        try await Task.sleep(nanoseconds: 5_500_000_000)

        let activeAfter = await store.isActive(
            model: "directMessage", signal: "typing",
            data: ["conversationId": "conv1"]
        )
        XCTAssertFalse(activeAfter, "Signal should auto-expire after 5 seconds")
    }

    /// stoppedTyping removes the typing indicator immediately.
    func testStoppedTyping_removesImmediately() async throws {
        let store = SignalStore()

        let typing = ModelSignalPayload(
            model: "directMessage", signal: .typing,
            data: ["conversationId": "conv1"], authorDeviceId: "device1"
        )
        await store.receive(typing)
        let beforeStop = await store.isActive(model: "directMessage", signal: "typing", data: ["conversationId": "conv1"])
        XCTAssertTrue(beforeStop)

        // Stop typing
        await store.remove(model: "directMessage", signal: "typing",
                           data: ["conversationId": "conv1"], authorDeviceId: "device1")

        let afterStop = await store.isActive(model: "directMessage", signal: "typing", data: ["conversationId": "conv1"])
        XCTAssertFalse(afterStop, "stoppedTyping should remove indicator immediately")
    }
}

// Test model
private struct DirectMessageTest: SyncModel {
    static let modelName = "directMessage"
    static let sync: SyncStrategy = .gset
    var conversationId: String
    var content: String
    var senderUsername: String
}
