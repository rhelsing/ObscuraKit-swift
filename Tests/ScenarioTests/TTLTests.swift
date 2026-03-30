import XCTest
@testable import ObscuraKit

/// Unit tests for TTLManager — ephemeral content expiration.
/// No server, no network.
final class TTLTests: XCTestCase {

    // MARK: - TTL Parsing

    func testTTL_seconds() {
        XCTAssertEqual(TTL.seconds(30).milliseconds, 30_000)
    }

    func testTTL_minutes() {
        XCTAssertEqual(TTL.minutes(5).milliseconds, 300_000)
    }

    func testTTL_hours() {
        XCTAssertEqual(TTL.hours(24).milliseconds, 86_400_000)
    }

    func testTTL_days() {
        XCTAssertEqual(TTL.days(7).milliseconds, 604_800_000)
    }

    // MARK: - TTL Lifecycle

    func testSchedule_setsExpiration() async throws {
        let store = try ModelStore()
        let ttl = TTLManager(store: store)

        await ttl.schedule(modelName: "story", id: "s1", ttl: .hours(1))

        let remaining = await ttl.timeRemaining(modelName: "story", id: "s1")
        XCTAssertNotNil(remaining)
        // Should be close to 1 hour (3600000ms) — allow 5 seconds tolerance
        XCTAssertGreaterThan(remaining!, 3_595_000)
    }

    func testIsExpired_notExpired() async throws {
        let store = try ModelStore()
        let ttl = TTLManager(store: store)

        await ttl.schedule(modelName: "story", id: "s1", ttl: .hours(1))
        let expired = await ttl.isExpired(modelName: "story", id: "s1")
        XCTAssertFalse(expired)
    }

    func testIsExpired_alreadyExpired() async throws {
        let store = try ModelStore()
        let ttl = TTLManager(store: store)

        // Schedule with 0 seconds — immediately expired
        await store.setTTL(modelName: "story", id: "s1", expiresAt: UInt64(Date().timeIntervalSince1970 * 1000) - 1000)
        let expired = await ttl.isExpired(modelName: "story", id: "s1")
        XCTAssertTrue(expired)
    }

    func testIsExpired_noTTL() async throws {
        let store = try ModelStore()
        let ttl = TTLManager(store: store)

        let expired = await ttl.isExpired(modelName: "story", id: "nonexistent")
        XCTAssertFalse(expired, "No TTL set should not be expired")
    }

    // MARK: - TTL Integration with Model

    func testCreate_schedulesTTL() async throws {
        let store = try ModelStore()
        let def = ModelDefinition(name: "story", sync: .gset, ttl: .hours(24), fields: ["content": .string])
        let model = Model(name: "story", definition: def, store: store)
        model.deviceId = "d1"

        let ttlManager = TTLManager(store: store)
        model.ttlManager = ttlManager

        _ = try await model.create(["content": "ephemeral"])

        // TTL should be scheduled
        let entries = await model.all()
        XCTAssertEqual(entries.count, 1)

        let remaining = await ttlManager.timeRemaining(modelName: "story", id: entries[0].id)
        XCTAssertNotNil(remaining, "TTL should be scheduled after create")
        XCTAssertGreaterThan(remaining!, 86_000_000) // ~24 hours
    }

    func testCreate_noTTL_doesNotSchedule() async throws {
        let store = try ModelStore()
        let def = ModelDefinition(name: "profile", sync: .lwwMap) // no TTL
        let model = Model(name: "profile", definition: def, store: store)
        model.deviceId = "d1"

        let ttlManager = TTLManager(store: store)
        model.ttlManager = ttlManager

        _ = try await model.upsert("p1", ["name": "Alice"])

        let remaining = await ttlManager.timeRemaining(modelName: "profile", id: "p1")
        XCTAssertNil(remaining, "No TTL configured = no TTL scheduled")
    }

    // MARK: - Cleanup

    func testCleanup_removesExpiredEntries() async throws {
        let store = try ModelStore()
        let def = ModelDefinition(name: "story", sync: .gset)
        let model = Model(name: "story", definition: def, store: store)
        model.deviceId = "d1"

        let ttlManager = TTLManager(store: store)
        ttlManager.setModelResolver { name in name == "story" ? model : nil }

        // Create entry and set TTL in the past (expired)
        _ = try await model.create(["content": "expired"])
        let entries = await model.all()
        let entryId = entries[0].id

        await store.setTTL(modelName: "story", id: entryId, expiresAt: UInt64(Date().timeIntervalSince1970 * 1000) - 1000)

        // Cleanup should remove it
        let cleaned = await ttlManager.cleanup()
        XCTAssertEqual(cleaned, 1)
    }
}
