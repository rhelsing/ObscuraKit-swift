import XCTest
@testable import ObscuraKit

/// The §4 classification table.
///
/// This is the piece that makes SPEC §0.9 checkable rather than aspirational — "never ack before
/// persisting" means nothing until something says, per arm, what persisting means for that arm.
///
/// Mirrors `ObscuraKit-Kotlin`'s `PayloadClassTest`. The two kits must agree here in a way they need
/// not agree elsewhere: a divergence means one of them acks something the other stores.
final class PayloadClassTests: XCTestCase {

    /// Every arm `client.proto` declares, as the generated oneof cases. Swift's generated enum is not
    /// `CaseIterable` — it has associated values — so the list is written out, and
    /// ``testTheArmListMatchesTheGeneratedOneof`` guards it against drift.
    private static let allArms: [Obscura_Client_V1_ClientMessage.OneOf_Payload] = [
        .text(.init()),
        .friendRequest(.init()), .friendResponse(.init()), .friendSync(.init()),
        .sessionReset(.init()),
        .deviceLinkApproval(.init()), .deviceAnnounce(.init()), .deviceRecoveryAnnounce(.init()),
        .historyChunk(.init()), .settingsSync(.init()), .readSync(.init()),
        .syncBlob(.init()), .sentSync(.init()),
        .contentReference(.init()), .chunkedContentReference(.init()), .syncRequest(.init()),
        .modelSync(.init()), .modelSignal(.init()),
    ]

    /// **The load-bearing test.** A new arm added to `client.proto` must not slip through
    /// unclassified — which, before the classification existed, meant being acked and destroyed.
    ///
    /// Swift cannot enumerate the oneof, so this leans on `WireCodec.decodeMessageType`, which has a
    /// case per arm and returns `""` for anything it does not know. An arm added to the proto but
    /// not to that switch fails here.
    func testTheArmListMatchesTheGeneratedOneof() {
        XCTAssertEqual(Self.allArms.count, 18, "client.proto declares 18 payload arms")

        for arm in Self.allArms {
            XCTAssertFalse(WireCodec.decodeMessageType(arm).isEmpty,
                           "an arm with no name in WireCodec is an arm nothing has classified")
        }
    }

    /// The one decision in §4.1 that was not a coin flip. Declining to ack an arm we do not
    /// understand looks conservative and is the opposite: any authenticated user may send to any
    /// device, a never-acked message redelivers forever, and the server's queue caps at 1000 per
    /// device and evicts **oldest-first, silently**. So refusing to ack unknown arms hands a stranger
    /// a remote wipe of the recipient's real undelivered mail.
    func testAnUnsetPayloadIsInboxedRatherThanLeftUnacked() {
        XCTAssertEqual(classify(nil), .inboxed)
    }

    func testModelSyncIsTheAppsDataPath() {
        XCTAssertEqual(classify(.modelSync(.init())), .inboxed)
    }

    /// The only class permitted to ack without persisting, and it is a closed list. If this ever
    /// grows, the growth is a decision about durability, not a routing tweak.
    func testTypingIndicatorsAreTheOnlyDroppableArm() {
        let droppable = Self.allArms.filter { classify($0) == .droppable }

        XCTAssertEqual(droppable.count, 1)
        XCTAssertEqual(WireCodec.decodeMessageType(droppable.first), "MODEL_SIGNAL")
    }

    /// §4.2's distinction, and the reason `.unimplemented` exists at all: the inbox fallback keys on
    /// absence from the **classification table**, not absence from the handler. If these landed in
    /// the inbox it would become the place unimplemented kit work goes to be forgotten.
    func testClassifiedButUnimplementedArmsAreNotSweptIntoTheInbox() {
        let unimplemented: [Obscura_Client_V1_ClientMessage.OneOf_Payload] = [
            .deviceRecoveryAnnounce(.init()), .historyChunk(.init()), .syncRequest(.init()),
            .settingsSync(.init()), .readSync(.init()),
        ]

        for arm in unimplemented {
            XCTAssertEqual(classify(arm), .unimplemented,
                           "\(WireCodec.decodeMessageType(arm)) is classified in §4 but implemented "
                           + "by neither kit — it must not become inbox fodder")
        }
    }

    /// Kit-owned state stays kit-owned; none of it may reach an app-readable inbox.
    func testFriendAndDeviceArmsAreKitInternal() {
        let kitInternal: [Obscura_Client_V1_ClientMessage.OneOf_Payload] = [
            .friendRequest(.init()), .friendResponse(.init()), .friendSync(.init()),
            .deviceAnnounce(.init()), .deviceLinkApproval(.init()),
            .sessionReset(.init()), .syncBlob(.init()), .sentSync(.init()),
        ]

        for arm in kitInternal {
            XCTAssertEqual(classify(arm), .kitInternal,
                           "\(WireCodec.decodeMessageType(arm)) mutates kit-owned state")
        }
    }

    /// Cross-kit agreement, spelled out: these are the exact classifications
    /// `ObscuraKit-Kotlin`'s `PayloadClassTest` asserts. The kits may differ in how they store a row;
    /// they may not differ in whether a given arm is stored at all.
    /// Arms this kit deliberately classifies differently from Kotlin, with the reason. Anything not
    /// in this set must match exactly — the point of the test below is that drift has to be declared
    /// here, in writing, rather than just happening.
    private static let divergesFromKotlin: [String: String] = [
        "DEVICE_LINK_APPROVAL":
            "Kotlin classifies this kit-internal and HANDLES it; this kit cannot receive one "
            + "(CLAUDE.md). Kit-internal-with-no-handler now throws, which would never ack a LIVE "
            + "flow and wedge the server queue — so it is bucketed unimplemented (drop + ack, "
            + "loudly) until the handler exists. Delete this entry when it does.",
    ]

    func testEveryArmHasTheSameClassAsTheKotlinKit() {
        let expected: [String: PayloadClass] = [
            "MODEL_SYNC": .inboxed,
            "FRIEND_REQUEST": .kitInternal, "FRIEND_RESPONSE": .kitInternal, "FRIEND_SYNC": .kitInternal,
            "DEVICE_ANNOUNCE": .kitInternal,
            "SESSION_RESET": .kitInternal, "SYNC_BLOB": .kitInternal, "SENT_SYNC": .kitInternal,
            "TEXT": .kitInternal,
            "MODEL_SIGNAL": .droppable,
            "DEVICE_RECOVERY_ANNOUNCE": .unimplemented, "HISTORY_CHUNK": .unimplemented,
            "SYNC_REQUEST": .unimplemented, "SETTINGS_SYNC": .unimplemented,
            "READ_SYNC": .unimplemented,
            // See `divergesFromKotlin` below.
            "DEVICE_LINK_APPROVAL": .unimplemented,
            // §4's normative table, not §4.3's deletion plan — the deletion has not happened and a
            // public sender still exists, so dropping these would have the receiver ack away an AES
            // key that was just shipped over Signal.
            "CONTENT_REFERENCE": .inboxed, "CHUNKED_CONTENT_REFERENCE": .inboxed,
        ]

        XCTAssertEqual(expected.count, Self.allArms.count, "every arm needs a cross-kit expectation")
        for arm in Self.allArms {
            let name = WireCodec.decodeMessageType(arm)
            XCTAssertEqual(classify(arm), expected[name], "\(name) does not match its expectation")
        }

        // The declared divergences must all still be real arms, so the list cannot rot after an arm
        // is deleted or a handler is finally written.
        let armNames = Set(Self.allArms.map { WireCodec.decodeMessageType($0) })
        for name in Self.divergesFromKotlin.keys {
            XCTAssertTrue(armNames.contains(name), "\(name) is declared divergent but is not an arm")
        }
    }
}
