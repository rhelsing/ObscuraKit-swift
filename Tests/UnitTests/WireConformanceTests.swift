import Foundation
import XCTest
import SwiftProtobuf
@testable import ObscuraKit

/// Vector-driven L3 wire conformance, consuming the shared
/// `proto/conformance/wire.json` (obscura-proto SPEC §3). Every kit runs the
/// same file.
///
/// Pins the enum <-> app-facing-form mappings introduced by the v2 client.proto
/// renumbering (which a single mis-copied case would silently break
/// cross-platform) via the production `WireCodec`, and that a `ModelSync`
/// round-trips through the wire by VALUE. Byte-canonicity is intentionally NOT
/// asserted (SPEC §3.3).
///
/// The `wire`-name → generated-enum-case maps below are a test harness:
/// SwiftProtobuf does not expose the proto enum names, so we bind them once here.
/// The production mapping under test is `WireCodec`.
final class WireConformanceTests: XCTestCase {

    private let typeByWire: [String: Obscura_V2_ClientMessage.TypeEnum] = [
        "TYPE_TEXT": .text,
        "TYPE_FRIEND_REQUEST": .friendRequest,
        "TYPE_MODEL_SYNC": .modelSync,
        "TYPE_MODEL_SIGNAL": .modelSignal,
    ]
    private let opByWire: [String: Obscura_V2_ModelSync.Op] = [
        "OP_CREATE": .create,
        "OP_UPDATE": .update,
        "OP_DELETE": .delete,
    ]
    private let kindByWire: [String: Obscura_V2_SignalKind] = [
        "SIGNAL_KIND_TYPING": .typing,
        "SIGNAL_KIND_STOPPED_TYPING": .stoppedTyping,
        "SIGNAL_KIND_READ": .read,
    ]

    func testWireConformance() throws {
        let v = try ConformanceVectors.load("wire.json")

        for m in (v["messageTypes"] as? [[String: Any]] ?? []) {
            let wire = m["wire"] as? String ?? "", app = m["app"] as? String ?? ""
            guard let t = typeByWire[wire] else { XCTFail("unmapped wire messageType \(wire)"); continue }
            XCTAssertEqual(WireCodec.decodeMessageType(t), app, "messageType \(wire) -> \(app)")
        }

        for m in (v["modelSyncOps"] as? [[String: Any]] ?? []) {
            let wire = m["wire"] as? String ?? "", app = m["app"] as? String ?? ""
            guard let op = opByWire[wire] else { XCTFail("unmapped wire op \(wire)"); continue }
            XCTAssertEqual(WireCodec.decodeOp(op), app, "decode \(wire)")
            XCTAssertEqual(WireCodec.encodeOp(app), op, "encode \(app)")
        }

        for m in (v["signalKinds"] as? [[String: Any]] ?? []) {
            let wire = m["wire"] as? String ?? "", app = m["app"] as? String ?? ""
            guard let k = kindByWire[wire] else { XCTFail("unmapped wire signalKind \(wire)"); continue }
            XCTAssertEqual(WireCodec.decodeSignalKind(k), app, "decode \(wire)")
            XCTAssertEqual(WireCodec.encodeSignalKind(app), k, "encode \(app)")
        }

        for rt in (v["roundTrip"] as? [[String: Any]] ?? []) {
            try roundTrip(rt["modelSync"] as? [String: Any] ?? [:], name: rt["name"] as? String ?? "?")
        }
    }

    /// Serialize to protobuf bytes and parse back — a true wire round-trip.
    private func roundTrip(_ ms: [String: Any], name: String) throws {
        let model = ms["model"] as? String ?? ""
        let id = ms["id"] as? String ?? ""
        let appOp = ms["op"] as? String ?? ""
        let ts = conformanceUInt64(ms["timestamp"])
        let dataMap = ms["data"] as? [String: Any] ?? [:]

        var proto = Obscura_V2_ModelSync()
        proto.model = model
        proto.id = id
        proto.op = WireCodec.encodeOp(appOp)
        proto.timestamp = ts
        proto.data = try JSONSerialization.data(withJSONObject: dataMap)
        proto.authorDeviceID = "d0"

        let decoded = try Obscura_V2_ModelSync(serializedData: proto.serializedData())

        XCTAssertEqual(decoded.model, model, "[\(name)] model")
        XCTAssertEqual(decoded.id, id, "[\(name)] id")
        XCTAssertEqual(WireCodec.decodeOp(decoded.op), appOp, "[\(name)] op")
        XCTAssertEqual(decoded.timestamp, ts, "[\(name)] timestamp")
        // data round-trips by VALUE (parsed map), not bytes — key order is irrelevant.
        let decodedData = (try JSONSerialization.jsonObject(with: decoded.data) as? [String: Any]) ?? [:]
        XCTAssertEqual(
            NSDictionary(dictionary: decodedData),
            NSDictionary(dictionary: dataMap),
            "[\(name)] data value"
        )
    }
}
