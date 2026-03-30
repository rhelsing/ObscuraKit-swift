import XCTest
@testable import ObscuraKit

/// Tests for filtered observation — model.where { ... }.observe()
/// Proves the observation only emits matching entries, not everything.
final class FilteredObserveTests: XCTestCase {

    func testFilteredObserve_onlyMatchingEntries() async throws {
        let store = try ModelStore()
        let def = ModelDefinition(name: "msg", sync: .gset,
                                  fields: ["conversationId": .string, "content": .string])
        let model = Model(name: "msg", definition: def, store: store)
        model.deviceId = "d1"

        // Seed with messages in two conversations
        _ = try await model.create(["conversationId": "conv1", "content": "hello conv1"])
        _ = try await model.create(["conversationId": "conv2", "content": "hello conv2"])
        _ = try await model.create(["conversationId": "conv1", "content": "second in conv1"])

        // Observe only conv1
        let query = model.where(["data.conversationId": "conv1"])
        let observation = query.observe()

        var lastResult: [ModelEntry] = []
        let task = Task {
            for await entries in observation.values {
                lastResult = entries
                break // Just get the first emission
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // Should only have conv1 messages
        XCTAssertEqual(lastResult.count, 2)
        for entry in lastResult {
            XCTAssertEqual(entry.data["conversationId"] as? String, "conv1")
        }
    }

    func testFilteredObserve_emitsOnNewMatch() async throws {
        let store = try ModelStore()
        let def = ModelDefinition(name: "msg", sync: .gset,
                                  fields: ["conversationId": .string, "content": .string])
        let model = Model(name: "msg", definition: def, store: store)
        model.deviceId = "d1"

        let query = model.where(["data.conversationId": "conv1"])
        let observation = query.observe()

        var emissions: [[ModelEntry]] = []
        let task = Task {
            for await entries in observation.values {
                emissions.append(entries)
                if emissions.count >= 2 { break }
            }
        }

        // Wait for initial emission (empty)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Create a matching entry
        _ = try await model.create(["conversationId": "conv1", "content": "new message"])

        // Wait for second emission
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        XCTAssertGreaterThanOrEqual(emissions.count, 2)
        // First emission: empty (no entries yet)
        XCTAssertEqual(emissions[0].count, 0)
        // Second emission: 1 matching entry
        XCTAssertEqual(emissions[1].count, 1)
        XCTAssertEqual(emissions[1][0].data["content"] as? String, "new message")
    }

    func testFilteredObserve_nonMatchingWriteDoesNotChangeResult() async throws {
        let store = try ModelStore()
        let def = ModelDefinition(name: "msg", sync: .gset,
                                  fields: ["conversationId": .string, "content": .string])
        let model = Model(name: "msg", definition: def, store: store)
        model.deviceId = "d1"

        _ = try await model.create(["conversationId": "conv1", "content": "original"])

        let query = model.where(["data.conversationId": "conv1"])
        let observation = query.observe()

        var emissions: [[ModelEntry]] = []
        let task = Task {
            for await entries in observation.values {
                emissions.append(entries)
                if emissions.count >= 2 { break }
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        // Write to a DIFFERENT conversation
        _ = try await model.create(["conversationId": "conv2", "content": "other"])

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // Both emissions should have exactly 1 entry (conv1's "original")
        // The conv2 write triggers a table notification but the filter excludes it
        for emission in emissions {
            XCTAssertEqual(emission.count, 1)
            XCTAssertEqual(emission[0].data["conversationId"] as? String, "conv1")
        }
    }
}
