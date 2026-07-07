import Foundation

/// Single source of truth for the L2 wire enum <-> app-facing-form mappings.
///
/// The v2 client.proto renumbered its enums (TYPE_/OP_/SIGNAL_KIND_ prefixes,
/// moving TEXT/CREATE off wire-0 so 0 can mean UNSPECIFIED). A kit that maps
/// these inconsistently silently breaks cross-platform interop, so the mappings
/// are consolidated here and pinned by `proto/conformance/wire.json` (see
/// obscura-proto SPEC §3). Mirrors the Kotlin kit's `WireCodec`.
///
/// Internal on purpose: SwiftProtobuf generates the `Obscura_V2_*` types with
/// `internal` visibility, so this codec (which references them) is internal too.
/// Tests reach it via `@testable import ObscuraKit`.
enum WireCodec {

    // MARK: ModelSync.Op <-> app string ("CREATE" / "UPDATE" / "DELETE")

    static func encodeOp(_ app: String) -> Obscura_V2_ModelSync.Op {
        switch app.uppercased() {
        case "UPDATE": return .update
        case "DELETE": return .delete
        case "CREATE": return .create
        // Legacy/unknown local writes are treated as CREATE (the historical default).
        default: return .create
        }
    }

    static func decodeOp(_ op: Obscura_V2_ModelSync.Op) -> String {
        switch op {
        case .update: return "UPDATE"
        case .delete: return "DELETE"
        case .create: return "CREATE"
        // OP_UNSPECIFIED (wire 0) is never sent by a conforming kit; treat as CREATE.
        default: return "CREATE"
        }
    }

    // MARK: SignalKind <-> app string ("typing" / "stoppedTyping" / "read")

    static func encodeSignalKind(_ app: String) -> Obscura_V2_SignalKind {
        switch app {
        case "typing": return .typing
        case "stoppedTyping": return .stoppedTyping
        case "read": return .read
        default: return .unspecified
        }
    }

    static func decodeSignalKind(_ kind: Obscura_V2_SignalKind) -> String {
        switch kind {
        case .typing: return "typing"
        case .stoppedTyping: return "stoppedTyping"
        case .read: return "read"
        default: return ""
        }
    }

    // MARK: ClientMessage.Type -> app string

    /// App-facing name for a content message type. Only the types with an
    /// app-level meaning are mapped; everything else returns "" (the type is
    /// still handled by its own routeMessage branch, not by string).
    static func decodeMessageType(_ type: Obscura_V2_ClientMessage.TypeEnum) -> String {
        switch type {
        case .text: return "TEXT"
        case .friendRequest: return "FRIEND_REQUEST"
        case .modelSync: return "MODEL_SYNC"
        case .modelSignal: return "MODEL_SIGNAL"
        default: return ""
        }
    }
}
