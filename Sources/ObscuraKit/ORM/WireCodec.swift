import Foundation

/// Single source of truth for the wire <-> app-facing-form mappings.
///
/// The message kind is the `ClientMessage.payload` oneof arm; `ModelSync.Op` and
/// `SignalKind` carry `OP_`/`SIGNAL_KIND_` prefixes and move CREATE/typing off
/// wire-0 (so 0 can mean UNSPECIFIED). A kit that maps these inconsistently
/// silently breaks cross-platform interop, so the mappings are consolidated here
/// and pinned by `proto/conformance/wire.json` (see obscura-proto SPEC §3).
/// Mirrors the Kotlin kit's `WireCodec`.
///
/// Internal on purpose: SwiftProtobuf generates the `Obscura_Client_V1_*` types with
/// `internal` visibility, so this codec (which references them) is internal too.
/// Tests reach it via `@testable import ObscuraKit`.
enum WireCodec {

    // MARK: ModelSync.Op <-> app string ("CREATE" / "UPDATE" / "DELETE")

    static func encodeOp(_ app: String) -> Obscura_Client_V1_ModelSync.Op {
        switch app.uppercased() {
        case "UPDATE": return .update
        case "DELETE": return .delete
        case "CREATE": return .create
        // Legacy/unknown local writes are treated as CREATE (the historical default).
        default: return .create
        }
    }

    static func decodeOp(_ op: Obscura_Client_V1_ModelSync.Op) -> String {
        switch op {
        case .update: return "UPDATE"
        case .delete: return "DELETE"
        case .create: return "CREATE"
        // OP_UNSPECIFIED (wire 0) is never sent by a conforming kit; treat as CREATE.
        default: return "CREATE"
        }
    }

    // MARK: SignalKind <-> app string ("typing" / "stoppedTyping" / "read")

    static func encodeSignalKind(_ app: String) -> Obscura_Client_V1_SignalKind {
        switch app {
        case "typing": return .typing
        case "stoppedTyping": return .stoppedTyping
        case "read": return .read
        default: return .unspecified
        }
    }

    static func decodeSignalKind(_ kind: Obscura_Client_V1_SignalKind) -> String {
        switch kind {
        case .typing: return "typing"
        case .stoppedTyping: return "stoppedTyping"
        case .read: return "read"
        default: return ""
        }
    }

    // MARK: ClientMessage.payload oneof -> app string

    /// App-facing message-kind string: the set `payload` arm's field name,
    /// upper-snake. An unset payload (or `.none`) maps to "".
    static func decodeMessageType(_ payload: Obscura_Client_V1_ClientMessage.OneOf_Payload?) -> String {
        switch payload {
        case .text?: return "TEXT"
        case .friendRequest?: return "FRIEND_REQUEST"
        case .friendResponse?: return "FRIEND_RESPONSE"
        case .sessionReset?: return "SESSION_RESET"
        case .deviceLinkApproval?: return "DEVICE_LINK_APPROVAL"
        case .deviceAnnounce?: return "DEVICE_ANNOUNCE"
        case .deviceRecoveryAnnounce?: return "DEVICE_RECOVERY_ANNOUNCE"
        case .historyChunk?: return "HISTORY_CHUNK"
        case .settingsSync?: return "SETTINGS_SYNC"
        case .readSync?: return "READ_SYNC"
        case .syncBlob?: return "SYNC_BLOB"
        case .sentSync?: return "SENT_SYNC"
        case .contentReference?: return "CONTENT_REFERENCE"
        case .chunkedContentReference?: return "CHUNKED_CONTENT_REFERENCE"
        case .syncRequest?: return "SYNC_REQUEST"
        case .modelSync?: return "MODEL_SYNC"
        case .friendSync?: return "FRIEND_SYNC"
        case .modelSignal?: return "MODEL_SIGNAL"
        case .none: return ""
        }
    }
}
