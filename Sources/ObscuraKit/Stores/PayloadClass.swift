import Foundation

/// What a payload arm is allowed to do on receipt (`obscura-proto/KIT_API.md` §4).
///
/// Every arm MUST be classified, because **the classification is what makes SPEC §0.9 checkable
/// rather than aspirational**. "Never ack before persisting" is not a rule the code can follow until
/// something says, per arm, *what persisting means for this one*.
enum PayloadClass: Equatable {
    /// Application content. Goes in the inbox; the app drains it. Ack only after the row commits.
    case inboxed

    /// Mutates kit-owned state (friend graph, devices, sessions). Ack only after the kit's write.
    case kitInternal

    /// Ephemeral by design, no durable delivery guarantee. MAY be acked without persistence.
    case droppable

    /// Declared arms with no receive contract. Diagnose, drop, and ack them so an unsupported arm
    /// cannot wedge the queue. Unknown future arms remain distinct and are inboxed.
    case unimplemented
}

/// The §4 classification table, as code.
///
/// An arm this kit has never heard of is **inboxed unparsed** (§4.1). Leaving it unacked would turn
/// an unsupported sender into an unbounded retry:
///
/// > any authenticated user may send to any device → a never-acked message is never deleted and
/// > redelivers forever → the server's queue caps at 1000 per device and evicts **oldest-first,
/// > silently** → a stranger looping unknown arms pushes the recipient's real undelivered mail off
/// > the back of the queue.
///
/// Refusing to ack is reserved for transient local failures that can succeed on a later attempt.
///
/// - Note: Swift's generated oneof has no `PAYLOAD_NOT_SET` case; an unset payload is `nil`, which
///   lands in the same `default` and is inboxed for the same reason.
func classify(_ payload: Obscura_Client_V1_ClientMessage.OneOf_Payload?) -> PayloadClass {
    switch payload {
    // The app's entire data path.
    case .modelSync?:
        return .inboxed

    // Kit-owned state, all with live handlers in `ObscuraClient.routeMessage`.
    case .friendRequest?, .friendResponse?,
         .deviceAnnounce?, .sessionReset?, .syncBlob?, .sentSync?:
        return .kitInternal

    // Swift sends this live arm but has no receive handler. Drop and acknowledge it loudly rather
    // than leaving a permanently unprocessable envelope on the server. Move it to kitInternal when
    // the receive handler lands.
    case .deviceLinkApproval?:
        return .unimplemented

    // Typing indicators. `client.proto` says "in-memory only", and §4 permits acking these without
    // persistence — the ONLY class for which that is allowed.
    case .modelSignal?:
        return .droppable

    // Legacy compatibility receive path.
    case .text?:
        return .kitInternal

    // Public senders still emit these arms, so dropping them would destroy the only copy of the
    // attachment key. Remove senders and receive classification together.
    case .contentReference?, .chunkedContentReference?:
        return .inboxed

    // Declared but unsupported on receive. DEVICE_RECOVERY_ANNOUNCE has a public sender in this kit,
    // which is a live gap; the remaining arms have no current sender here.
    case .friendSync?,
         .deviceRecoveryAnnounce?, .historyChunk?, .syncRequest?,
         .settingsSync?, .readSync?:
        return .unimplemented

    // Unknown or future arm, and an unset payload. Inbox it unparsed rather than destroy it.
    default:
        return .inboxed
    }
}
