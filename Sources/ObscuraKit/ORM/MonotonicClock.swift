import Foundation

/// Monotonic timestamp source for this replica's local writes.
///
/// LWW conflict resolution uses a total order on (timestamp, authorDeviceId) with the
/// device id as the tie-break (obscura-proto SPEC §2). That tie-break makes *cross-device*
/// concurrent writes converge deterministically, but it cannot order two writes that share
/// the SAME (timestamp, authorDeviceId) — which happens when one device issues two writes to
/// the same entry within one wall-clock millisecond. Left alone, the later local write could
/// lose to the earlier one.
///
/// This clock guarantees a replica's own successive writes get strictly-increasing timestamps
/// (a Lamport clock seeded by wall time), while remaining ~wall-clock for cross-device
/// comparison. Mirrors ObscuraKit-Kotlin MonotonicClock.
actor MonotonicClock {
    static let shared = MonotonicClock()

    private var last: UInt64 = 0

    /// A timestamp ≥ now and strictly greater than any previously returned.
    func now() -> UInt64 {
        let wall = UInt64(Date().timeIntervalSince1970 * 1000)
        last = wall > last ? wall : last + 1
        return last
    }
}
