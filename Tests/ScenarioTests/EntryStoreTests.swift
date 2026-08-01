import XCTest
import GRDB
@testable import ObscuraKit

/// Raw entry storage (`obscura-proto/KIT_API.md` §8.1).
///
/// Mirrors `ObscuraKit-Kotlin`'s `EntryStoreTest`. The property under test throughout is **that the
/// kit does not interpret anything**: merge moved to the app, so this store writes what it is given
/// and returns it unchanged.
final class EntryStoreTests: XCTestCase {

    private func makeStore() throws -> EntryStore {
        try EntryStore(db: try DatabaseQueue())
    }

    private func entry(
        _ id: String,
        data: String = #"{"content":"hi"}"#,
        sentAt: UInt64 = 1_000,
        device: String = "device_a"
    ) -> StoredEntry {
        StoredEntry(id: id, data: data, sentAt: sentAt, authorDeviceId: device)
    }

    func testPutThenAllReturnsWhatWasWritten() async throws {
        let store = try makeStore()
        try await store.put(model: "directMessage", entry: entry("dm_1"))

        let all = try await store.all(model: "directMessage")

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, "dm_1")
        XCTAssertEqual(all[0].data, #"{"content":"hi"}"#)
        XCTAssertEqual(all[0].sentAt, 1_000)
        XCTAssertEqual(all[0].authorDeviceId, "device_a")
    }

    /// `put` is a blind upsert: an older write replaces a newer one,
    /// because by the time a write reaches this type the app has already decided who wins.
    ///
    /// Merge policy must not be duplicated here or overrule the app's decision.
    func testPutIsBlindAnOlderWriteOverwritesANewerOne() async throws {
        let store = try makeStore()
        try await store.put(model: "pix", entry: entry("pix_1", data: #"{"v":"new"}"#, sentAt: 9_000))
        try await store.put(model: "pix", entry: entry("pix_1", data: #"{"v":"old"}"#, sentAt: 1_000))

        let all = try await store.all(model: "pix")

        XCTAssertEqual(all.count, 1, "same (model, id) is one row")
        XCTAssertEqual(all[0].data, #"{"v":"old"}"#,
                       "the store must not re-decide the merge; the app already did")
        XCTAssertEqual(all[0].sentAt, 1_000)
    }

    func testModelsDoNotBleedIntoEachOther() async throws {
        let store = try makeStore()
        try await store.put(model: "directMessage", entry: entry("a"))
        try await store.put(model: "story", entry: entry("b"))

        let dms = try await store.all(model: "directMessage")
        let stories = try await store.all(model: "story")
        let profiles = try await store.all(model: "profile")

        XCTAssertEqual(dms.map(\.id), ["a"])
        XCTAssertEqual(stories.map(\.id), ["b"])
        XCTAssertTrue(profiles.isEmpty)
    }

    /// `data` is opaque. The kit stores the string it is handed and returns it byte-for-byte — it
    /// does not parse, re-serialize, validate or normalise. Re-serializing would reorder keys and
    /// change the bytes the app hashed or compared.
    func testDataIsStoredVerbatimIncludingContentTheKitCannotParse() async throws {
        let store = try makeStore()
        let notJSON = "this is not json at all {{{"
        try await store.put(model: "weird", entry: entry("w", data: notJSON))

        let all = try await store.all(model: "weird")

        XCTAssertEqual(all.first?.data, notJSON,
                       "the kit must not validate a shape it is forbidden to read (SPEC §0.4)")
    }

    func testUnicodeAndNestedPayloadsSurviveUnchanged() async throws {
        let store = try makeStore()
        let payload = #"{"content":"sunset 🌅","meta":{"x":0.5,"tags":["a","b"]}}"#
        try await store.put(model: "story", entry: entry("s", data: payload))

        let all = try await store.all(model: "story")

        XCTAssertEqual(all.first?.data, payload)
    }

    func testDeleteRemovesAnEntryFromAll() async throws {
        let store = try makeStore()
        try await store.put(model: "story", entry: entry("s1"))
        try await store.put(model: "story", entry: entry("s2"))

        try await store.delete(model: "story", id: "s1")

        let all = try await store.all(model: "story")
        XCTAssertEqual(all.map(\.id), ["s2"])
    }

    func testDeletingSomethingThatIsNotThereIsANoOp() async throws {
        let store = try makeStore()
        try await store.put(model: "story", entry: entry("s1"))

        try await store.delete(model: "story", id: "nope")

        let all = try await store.all(model: "story")
        XCTAssertEqual(all.count, 1)
    }

    func testAllOnAnUnknownModelIsEmptyRatherThanAnError() async throws {
        let store = try makeStore()

        let all = try await store.all(model: "neverSeen")

        XCTAssertTrue(all.isEmpty)
    }

    /// The merge metadata has to survive the round trip, because it IS the app's merge input:
    /// REPLACE is a total order on `(sentAt, authorDeviceId)` (§8.2). A store that dropped or
    /// rewrote either would make the app's tie-break silently non-deterministic across devices.
    func testMergeMetadataRoundTripsExactly() async throws {
        let store = try makeStore()
        try await store.put(model: "pix", entry: entry("p", sentAt: 1_700_000_000_123, device: "device_zzz"))

        let stored = try await store.all(model: "pix")

        XCTAssertEqual(stored.first?.sentAt, 1_700_000_000_123)
        XCTAssertEqual(stored.first?.authorDeviceId, "device_zzz")
    }
}
