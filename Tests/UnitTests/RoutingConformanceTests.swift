import Foundation
import XCTest
@testable import ObscuraKit

/// Vector-driven L3 delivery-targeting conformance, consuming the shared
/// `proto/conformance/routing.json` (obscura-proto SPEC §1). Every kit runs the
/// same file.
///
/// The confidentiality boundary — which recipients a 1:1 payload reaches, and the
/// fail-loud refusal to broadcast an unresolved 1:1 — is defined by data, not code.
///
/// This drives the real `SyncManager.resolveTargets` (the pure targeting decision)
/// and mirrors `broadcast`'s fan-out to expand the resolution to a recipient set.
///
/// Harness note: the vector's `audience` config is mapped to Swift's
/// `(SyncScope, isPrivate)` here, mirroring the audience-parse half of
/// `defineModelsFromJson`. A pure `fromWire` that would route this through
/// production parsing (and make the schema.json vector pass) lands with
/// ws-debt-full-swift; the routing DECISION under test is already production.
/// One device per user (deviceId == userId), so recipient userIds == targets.
final class RoutingConformanceTests: XCTestCase {

    func testRoutingConformance() throws {
        let vectors = try ConformanceVectors.load("routing.json")
        let topo = vectors["topology"] as? [String: Any] ?? [:]
        let selfId = topo["selfUserId"] as? String ?? ""

        let acceptedFriends: [Friend] = (topo["friends"] as? [[String: Any]] ?? []).compactMap { f in
            guard let uid = f["userId"] as? String,
                  let uname = f["username"] as? String,
                  (f["status"] as? String) == "accepted" else { return nil }
            return Friend(userId: uid, username: uname, status: .accepted)
        }
        let allFriendIds = acceptedFriends.map { $0.userId }

        let cases = vectors["cases"] as? [[String: Any]] ?? []
        XCTAssertFalse(cases.isEmpty, "no routing cases loaded")

        for c in cases {
            let name = c["name"] as? String ?? "?"
            let schema = c["schema"] as? [String: Any] ?? [:]
            let entryData = (c["entry"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
            let expect = c["expect"] as? [String: Any] ?? [:]

            let (scope, isPrivate) = scope(for: schema["audience"] as? [String: Any])
            let resolution = SyncManager.resolveTargets(
                scope: scope,
                isPrivate: isPrivate,
                entryData: entryData,
                acceptedFriends: acceptedFriends
            )

            if let expectedError = expect["error"] as? String {
                // Fail-loud: broadcast MUST raise + send nothing. resolveTargets returns
                // .refuse, which broadcast turns into ObscuraError.directRoutingUnresolved.
                guard case .refuse = resolution else {
                    XCTFail("[\(name)] expected fail-loud \(expectedError) but resolution was \(resolution)")
                    continue
                }
                XCTAssertEqual(
                    expectedError, "DIRECT_ROUTING_UNRESOLVED",
                    "[\(name)] only DIRECT_ROUTING_UNRESOLVED is modeled by .refuse"
                )
            } else {
                let expected = Set((expect["recipients"] as? [String]) ?? [])
                let actual = recipients(of: resolution, selfId: selfId, allFriendIds: allFriendIds)
                XCTAssertEqual(actual, expected, "[\(name)] delivered to the wrong recipient set")
            }
        }
    }

    private func scope(for audience: [String: Any]?) -> (SyncScope, Bool) {
        switch (audience?["kind"] as? String) ?? "friends" {
        case "self": return (.ownDevices, true)
        case "recipient", "conversation": return (.direct, false)
        default: return (.friends, false)
        }
    }

    /// Expand a Resolution to its recipient userId set, mirroring `broadcast`'s
    /// fan-out (every non-refuse branch also self-syncs, so selfId is included).
    private func recipients(
        of r: SyncManager.Resolution,
        selfId: String,
        allFriendIds: [String]
    ) -> Set<String> {
        switch r {
        case .selfOnly: return [selfId]
        case .allFriends: return Set(allFriendIds).union([selfId])
        case .scoped(let ids): return Set(ids).union([selfId])
        case .refuse: return []
        }
    }
}
