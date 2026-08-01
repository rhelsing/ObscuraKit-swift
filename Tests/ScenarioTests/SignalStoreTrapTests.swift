import XCTest
@testable import ObscuraKit

/// `SignalStore.receive` must survive a peer-supplied timestamp from the future.
///
/// `payload.timestamp` is peer-supplied and unclamped. Staleness checks must
/// avoid subtracting a future `UInt64`, because underflow traps.
///
/// A trap is not an error: `processEnvelope`'s `do/catch` cannot contain it, so the app dies. And any
/// authenticated user can deliver a MODEL_SIGNAL — friendship is not required to send (`KIT_API.md`
/// §4.1) — while Kotlin's sender stamps `System.currentTimeMillis()`. An Android peer with a slightly
/// fast clock would otherwise cause a remote crash.
///
/// These tests exist because a trap cannot be caught: there is no way to assert "it does not crash"
/// except by running the call and reaching the next line.
final class SignalStoreTrapTests: XCTestCase {

    private func payload(timestamp: UInt64) -> ModelSignalPayload {
        ModelSignalPayload(
            model: "directMessage", signalRaw: "typing", conversationId: "a_b",
            senderUsername: "peer", authorDeviceId: "device_peer", timestamp: timestamp
        )
    }

    /// One millisecond into the future — the realistic case, ordinary clock skew.
    func testASignalTimestampedOneMillisecondAheadDoesNotCrash() async {
        let store = SignalStore()
        let future = UInt64(Date().timeIntervalSince1970 * 1000) + 1

        await store.receive(payload(timestamp: future))

        // Reaching this line IS the assertion — a trap would have killed the process.
        let active = await store.getActive(model: "directMessage", signal: "typing",
                                          data: ["conversationId": "a_b"])
        XCTAssertEqual(active, ["peer"], "a future-stamped signal is treated as fresh, not dropped")
    }

    /// The adversarial case: as far in the future as the type allows.
    func testAnAbsurdlyFutureTimestampDoesNotCrash() async {
        let store = SignalStore()

        await store.receive(payload(timestamp: UInt64.max))

        let active = await store.getActive(model: "directMessage", signal: "typing",
                                          data: ["conversationId": "a_b"])
        XCTAssertEqual(active, ["peer"])
    }

    /// The behaviour the check is actually for must still work.
    func testAGenuinelyStaleSignalIsStillDropped() async {
        let store = SignalStore()
        let old = UInt64(Date().timeIntervalSince1970 * 1000) - 60_000

        await store.receive(payload(timestamp: old))

        let active = await store.getActive(model: "directMessage", signal: "typing",
                                          data: ["conversationId": "a_b"])
        XCTAssertTrue(active.isEmpty, "a signal from a minute ago is stale and must not show as typing")
    }
}
