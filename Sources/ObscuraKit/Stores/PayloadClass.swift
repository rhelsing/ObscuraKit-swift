import Foundation

/// What a payload arm is allowed to do on receipt (`obscura-proto/KIT_API.md` §4).
///
/// Every arm MUST be classified, because **the classification is what makes SPEC §0.9 checkable
/// rather than aspirational**. "Never ack before persisting" is not a rule the code can follow until
/// something says, per arm, *what persisting means for this one*.
///
/// Ported from `ObscuraKit-Kotlin`'s `PayloadClass.kt` (PR #49). §10 has Kotlin design first and
/// Swift port the proven shape — the two kits co-designing is how they ended up disagreeing on
/// behaviour while agreeing on the wire.
enum PayloadClass: Equatable {
    /// Application content. Goes in the inbox; the app drains it. Ack only after the row commits.
    case inboxed

    /// Mutates kit-owned state (friend graph, devices, sessions). Ack only after the kit's write.
    case kitInternal

    /// Ephemeral by design, no durable delivery guarantee. MAY be acked without persistence.
    case droppable

    /// Classified in §4 as kit-internal, and implemented by **neither** kit.
    ///
    /// Kept distinct from ``kitInternal`` on purpose. These arms are acked and destroyed today, and
    /// the temptation is to sweep them into the inbox with the unknown arms — but §4.2 is explicit
    /// that the fallback keys on **absence from the classification table**, not absence from the
    /// handler. If unimplemented kit work landed in the inbox, the inbox would become the place it
    /// goes to be forgotten, and §4's classification would stop meaning anything.
    ///
    /// Each has a recorded resolution in §4.2. Note that "unimplemented" is about the RECEIVE side
    /// only — `DEVICE_RECOVERY_ANNOUNCE` has a live public sender in this kit
    /// (`ObscuraClient.announceRecovery`) and no handler at all, which is a real gap and not merely
    /// an unused arm.
    case unimplemented
}

/// The §4 classification table, as code.
///
/// The `default` branch is load-bearing: an arm this kit has never heard of is **inboxed unparsed**
/// (§4.1), not left unacked. That is not a coin-flip between two reasonable options — declining to
/// ack composes with the server's eviction into a remote wipe:
///
/// > any authenticated user may send to any device → a never-acked message is never deleted and
/// > redelivers forever → the server's queue caps at 1000 per device and evicts **oldest-first,
/// > silently** → a stranger looping unknown arms pushes the recipient's real undelivered mail off
/// > the back of the queue.
///
/// Declining to ack is right when the failure is *ours and transient* — disk full, a migration not
/// yet applied, something that will work next launch. An unknown arm is neither, so the retry is
/// unbounded by construction.
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

    // ⚠️ **A DELIBERATE DIVERGENCE FROM KOTLIN, and the only one.** Kotlin classifies this
    // `KIT_INTERNAL` and handles it; this kit sends `DEVICE_LINK_APPROVAL` and **cannot receive
    // one** — the gap recorded in `CLAUDE.md`, in code the reset keeps.
    //
    // It is bucketed `.unimplemented` rather than `.kitInternal` because of what the two do at the
    // ack. `.kitInternal` with no handler now THROWS (see `routeMessage`'s `default`), which is
    // right for an arm nobody sends — it leaves the message on the server until a handler exists.
    // But device linking is a LIVE flow: obscura-pix uses it, and Kotlin sends the approval. So
    // throwing would mean an envelope that can never be handled and is never acked, redelivering on
    // every reconnect, filling a server queue that caps at 1000 and evicts oldest-first. That is the
    // remote-wedge shape this design exists to avoid, arrived at from the other direction.
    //
    // So it is dropped and acked, loudly, which is what this kit already did — the linking payload
    // (p2p private key, recovery public key, friends export, approver's device list) is lost and the
    // user retries linking. **The real fix is the handler**, not this classification. When it lands,
    // move this case up to `.kitInternal` and delete the divergence entry in `PayloadClassTests`.
    case .deviceLinkApproval?:
        return .unimplemented

    // Typing indicators. `client.proto` says "in-memory only", and §4 permits acking these without
    // persistence — the ONLY class for which that is allowed.
    case .modelSignal?:
        return .droppable

    // Legacy. Deleted by `RESET.md`; still routed while it exists.
    case .text?:
        return .kitInternal

    // Attachment references. §4 classifies these INBOXED and §4.3 resolves them as Phase 3
    // deletions — but the deletion has NOT happened: both arms are still in client.proto and the
    // kits still expose public senders. Classifying them unimplemented while a live public API can
    // send them means the kit uploads the blob, ships the AES key over Signal, and the RECEIVER
    // acks and destroys the key. They follow §4's normative table until arms and senders are
    // deleted together: inboxing an arm nobody sends costs nothing, dropping one somebody CAN send
    // costs the message.
    case .contentReference?, .chunkedContentReference?:
        return .inboxed

    // Classified, unimplemented on RECEIVE — see the enum case. Not inbox fodder.
    //
    // This comment used to claim none of these has a live sender and that `deviceRecoveryAnnounce`
    // is "gated behind a default-off flag". Both were false of THIS kit. There is no
    // `enableRecoveryPhrase` anywhere in the Swift source — that config flag exists only in
    // ObscuraKit-Kotlin — and `ObscuraClient.announceRecovery(_:)` is a live public sender with no
    // gate in front of it. `SYNC_REQUEST` no longer has one: `requestSync()` is deleted, because it
    // sent a message both kits classify unimplemented and drop.
    //
    // `FRIEND_SYNC` joins them, and it is a DELETION rather than an omission. Both halves of the arm
    // are gone from this kit. `FriendSync` carries no `user_id`, so `routeMessage` keyed the friend
    // it created on `sourceUserId` — which the self-guard directly above it had just proven is OUR
    // OWN userId. It put the user in their own friends list, hence into `getAccepted()`, hence into
    // the fan-out of `announceDevices()` and `announceRecovery()`; `remove` removed self. The
    // sender's `sendFriendSync(userId:)` parameter was bound and never referenced, which is the same
    // fact seen from the other end. obscura-pix never references FRIEND_SYNC.
    //
    // It lands here rather than in `.kitInternal` for the same reason `.deviceLinkApproval` does: a
    // `.kitInternal` arm with no handler THROWS, and an inbound FRIEND_SYNC from a peer kit that
    // still sends one would then never ack, redeliver forever, and push the recipient's real mail
    // off the back of a server queue that caps at 1000 and evicts oldest-first. Dropped and acked,
    // loudly, is the safe shape for an arm somebody else may still send.
    case .friendSync?,
         .deviceRecoveryAnnounce?, .historyChunk?, .syncRequest?,
         .settingsSync?, .readSync?:
        return .unimplemented

    // Unknown or future arm, and an unset payload. Inbox it unparsed rather than destroy it.
    default:
        return .inboxed
    }
}
