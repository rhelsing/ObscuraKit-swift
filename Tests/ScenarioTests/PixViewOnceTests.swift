import XCTest
@testable import ObscuraKit

/// View-once (pix) regression guard.
///
/// "View once" is enforced in the *app* UI (it hides any pix whose `viewedAt`
/// is set). The kit's job is only the data underneath it:
///   1. viewing stamps `viewedAt` via an LWW upsert WITHOUT dropping the other
///      pix fields, and
///   2. that viewed-receipt merges back to the sender's copy (LWW).
///
/// So the iOS "can view a pix unlimited times" bug is NOT in the kit — these
/// tests pin the kit behavior the app depends on, isolating the defect to the
/// app/bridge layer (the `viewedAt` upsert not firing, or the list not
/// re-filtering, on iOS).
final class PixViewOnceTests: XCTestCase {

    private func makeEntry(_ id: String, data: [String: Any], timestamp: UInt64) -> ModelEntry {
        ModelEntry(id: id, data: data, timestamp: timestamp, signature: Data(), authorDeviceId: "dev")
    }

    /// Viewing a pix stamps `viewedAt` via LWW upsert, preserving every other field.
    func testViewingStampsViewedAtPreservingFields() async throws {
        let store = try ModelStore()
        let pix = LWWMap(store: store, modelName: "pix")

        let base: [String: Any] = [
            "conversationId": "uA_uB", "recipientUsername": "bob",
            "senderUsername": "alice", "mediaRef": "att1",
            "contentKey": "k", "nonce": "n", "displayDuration": 5,
        ]
        _ = await pix.set(makeEntry("pix_1", data: base, timestamp: 1000))

        // Fresh pix → no viewedAt → app treats it as "unopened" / viewable.
        let before = await pix.get("pix_1")
        XCTAssertNil(before?.data["viewedAt"], "a fresh pix must have no viewedAt")

        // View it: upsert the same id with viewedAt at a newer timestamp (LWW wins).
        var viewedData = base
        viewedData["viewedAt"] = 1_700_000_000_000
        _ = await pix.set(makeEntry("pix_1", data: viewedData, timestamp: 2000))

        let after = await pix.get("pix_1")
        XCTAssertNotNil(after?.data["viewedAt"], "viewedAt must be set after viewing — the view-once flag")
        XCTAssertEqual(after?.data["senderUsername"] as? String, "alice", "other fields must survive the upsert")
        XCTAssertEqual(after?.data["mediaRef"] as? String, "att1")
    }

    /// The viewed-receipt (recipient stamps viewedAt) merges back onto the sender's copy.
    func testViewedReceiptMergesToSender() async throws {
        let store = try ModelStore()
        let senderCopy = LWWMap(store: store, modelName: "pix")

        // Sender's own copy: created, not yet viewed.
        _ = await senderCopy.set(makeEntry("pix_2",
            data: ["conversationId": "uA_uB", "senderUsername": "alice", "mediaRef": "att2"],
            timestamp: 1000))

        // Recipient's viewed version arrives via sync (newer timestamp).
        let receipt = makeEntry("pix_2",
            data: ["conversationId": "uA_uB", "senderUsername": "alice", "mediaRef": "att2",
                   "viewedAt": 1_700_000_000_000],
            timestamp: 2000)
        _ = await senderCopy.merge([receipt])

        let merged = await senderCopy.get("pix_2")
        XCTAssertNotNil(merged?.data["viewedAt"], "sender must see viewedAt once the receipt merges (LWW)")
    }

    /// LWW must NOT let a stale (older-timestamp) write clobber a newer viewedAt —
    /// otherwise a late-arriving un-viewed copy could "un-view" a pix.
    func testStaleWriteCannotClearViewedAt() async throws {
        let store = try ModelStore()
        let pix = LWWMap(store: store, modelName: "pix")

        var viewed: [String: Any] = ["conversationId": "uA_uB", "senderUsername": "alice"]
        viewed["viewedAt"] = 1_700_000_000_000
        _ = await pix.set(makeEntry("pix_3", data: viewed, timestamp: 5000))

        // An older, un-viewed version arrives late — must lose to LWW.
        _ = await pix.merge([makeEntry("pix_3",
            data: ["conversationId": "uA_uB", "senderUsername": "alice"], timestamp: 1000)])

        let result = await pix.get("pix_3")
        XCTAssertNotNil(result?.data["viewedAt"], "a stale un-viewed write must not clear viewedAt")
    }
}
