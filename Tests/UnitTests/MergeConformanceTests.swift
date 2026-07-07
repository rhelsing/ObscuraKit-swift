import Foundation
import XCTest
@testable import ObscuraKit

/// Vector-driven L3 CRDT merge conformance, consuming the shared
/// `proto/conformance/merge.json` (obscura-proto SPEC §2). Every kit runs the
/// same file.
///
/// Cases with multiple `applyOrders` assert CONVERGENCE: the same ops applied in
/// different arrival orders MUST resolve identically. This is what pins the LWW
/// `(timestamp, authorDeviceId)` total order — a non-deterministic tie-break
/// passes single-order tests but diverges here.
///
/// Ops are applied via the merge (incoming-sync) path — where reconciliation
/// happens and where bugs hide — against the real `LWWMap`/`GSet` + an in-memory
/// `ModelStore`.
final class MergeConformanceTests: XCTestCase {

    func testMergeConformance() async throws {
        let vectors = try ConformanceVectors.load("merge.json")
        let cases = vectors["cases"] as? [[String: Any]] ?? []
        XCTAssertFalse(cases.isEmpty, "no merge cases loaded")

        for c in cases {
            let name = c["name"] as? String ?? "?"
            let orders = (c["applyOrders"] as? [String]) ?? ["forward"]
            for order in orders {
                try await runCase(c, order: order, label: "\(name) [\(order)]")
            }
        }
    }

    private func runCase(_ c: [String: Any], order: String, label: String) async throws {
        let sync = c["sync"] as? String ?? "gset"
        var ops = (c["ops"] as? [[String: Any]] ?? []).map(entryFromOp)
        if order == "reverse" { ops.reverse() }

        let expected = ((c["expect"] as? [String: Any])?["entries"] as? [[String: Any]]) ?? []
        let store = try ModelStore()
        var winners: [String: ModelEntry] = [:]

        if sync == "lww" {
            let map = LWWMap(store: store, modelName: "m")
            for op in ops { _ = await map.merge([op]) }
            for e in expected { if let id = e["id"] as? String { winners[id] = await map.get(id) } }
        } else {
            let set = GSet(store: store, modelName: "m")
            for op in ops { _ = await set.merge([op]) }
            for e in expected { if let id = e["id"] as? String { winners[id] = await set.get(id) } }
        }

        for exp in expected {
            let id = exp["id"] as? String ?? "?"
            guard let actual = winners[id] else {
                XCTFail("[\(label)] expected entry '\(id)' missing after merge")
                continue
            }
            if let deleted = exp["deleted"] as? Bool {
                XCTAssertEqual(actual.isDeleted, deleted, "[\(label)] [\(id)] wrong deleted state")
            }
            if let author = exp["authorDeviceId"] as? String {
                XCTAssertEqual(actual.authorDeviceId, author, "[\(label)] [\(id)] wrong winning author")
            }
            if let data = exp["data"] as? [String: Any] {
                XCTAssertEqual(
                    NSDictionary(dictionary: actual.data),
                    NSDictionary(dictionary: data),
                    "[\(label)] [\(id)] wrong winning data"
                )
            }
        }
    }

    private func entryFromOp(_ op: [String: Any]) -> ModelEntry {
        ModelEntry(
            id: op["id"] as? String ?? "",
            data: op["data"] as? [String: Any] ?? [:],
            timestamp: conformanceUInt64(op["ts"]),
            signature: Data(),
            authorDeviceId: op["authorDeviceId"] as? String ?? ""
        )
    }
}
