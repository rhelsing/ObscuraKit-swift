import XCTest
@testable import ObscuraKit

/// Tests for model.observe() — reactive GRDB ValueObservation on ORM models.
final class ObserveTests: XCTestCase {

    func testObserve_emitsOnCreate() async throws {
        let store = try ModelStore()
        let def = ModelDefinition(name: "story", sync: .gset)
        let model = Model(name: "story", definition: def, store: store)
        model.deviceId = "d1"

        let observation = model.observe()
        var received: [[ModelEntry]] = []

        // Start observing in background
        let task = Task {
            for await entries in observation.values {
                received.append(entries)
                if received.count >= 2 { break }
            }
        }

        // Give observer time to subscribe
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Create an entry — should trigger observation
        _ = try await model.create(["content": "hello"])

        // Wait for observation to fire
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        task.cancel()

        // Should have received at least: initial empty + after create
        XCTAssertGreaterThanOrEqual(received.count, 2)
        // Last emission should have 1 entry
        XCTAssertEqual(received.last?.count, 1)
    }

    func testObserve_excludesTombstones() async throws {
        let store = try ModelStore()
        let def = ModelDefinition(name: "profile", sync: .lwwMap)
        let model = Model(name: "profile", definition: def, store: store)
        model.deviceId = "d1"

        _ = try await model.upsert("p1", ["name": "Alice"])
        _ = try await model.upsert("p2", ["name": "Bob"])
        _ = try await model.delete("p1")

        let observation = model.observe()
        var lastEntries: [ModelEntry] = []

        let task = Task {
            for await entries in observation.values {
                lastEntries = entries
                break // Just get the first emission
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // Should only see Bob (Alice is tombstoned)
        XCTAssertEqual(lastEntries.count, 1)
        XCTAssertEqual(lastEntries.first?.data["name"] as? String, "Bob")
    }
}
