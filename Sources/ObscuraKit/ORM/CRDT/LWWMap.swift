import Foundation

/// LWWMap - Last-Writer-Wins Map CRDT
///
/// Used for mutable state: streaks, settings, profiles, reactions.
/// Each key has value + timestamp. Highest timestamp wins on conflict.
public class LWWMap {
    private let store: ModelStore
    private let modelName: String
    private var entries: [String: ModelEntry] = [:]
    private var loaded = false

    public init(store: ModelStore, modelName: String) {
        self.store = store
        self.modelName = modelName
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        let entries = await store.getAll(modelName)
        for entry in entries {
            self.entries[entry.id] = entry
        }
        loaded = true
    }

    /// Set/update an entry. Only updates if it wins the LWW conflict.
    /// Returns the winning entry (might be existing if it was newer).
    /// Rejects timestamps more than 60 seconds in the future to prevent spoofing.
    public func set(_ entry: ModelEntry) async -> ModelEntry {
        await ensureLoaded()
        let effective = clampFutureTimestamp(entry)
        let existing = entries[effective.id]
        if supersedes(effective, over: existing) {
            await store.put(modelName, effective)
            entries[effective.id] = effective
            return effective
        }
        // supersedes(x, over: nil) is always true, so a false result implies existing != nil.
        return existing!
    }

    /// Alias for set, consistent interface with GSet.
    public func add(_ entry: ModelEntry) async -> ModelEntry {
        return await set(entry)
    }

    /// Merge remote entries. Returns entries that actually updated local state.
    public func merge(_ entries: [ModelEntry]) async -> [ModelEntry] {
        await ensureLoaded()
        var updated: [ModelEntry] = []
        for entry in entries {
            let effective = clampFutureTimestamp(entry)
            let existing = self.entries[effective.id]
            if supersedes(effective, over: existing) {
                await store.put(modelName, effective)
                self.entries[effective.id] = effective
                updated.append(effective)
            }
        }
        return updated
    }

    /// Reject a spoofed far-future timestamp that would otherwise win every future
    /// LWW conflict forever. Applied on BOTH the local-write (set) and the
    /// incoming-sync (merge) paths — a timestamp arriving over sync is no more
    /// trustworthy than a local one.
    private func clampFutureTimestamp(_ entry: ModelEntry) -> ModelEntry {
        let maxTimestamp = UInt64(Date().timeIntervalSince1970 * 1000) + 60_000
        guard entry.timestamp > maxTimestamp else { return entry }
        return ModelEntry(id: entry.id, data: entry.data, timestamp: maxTimestamp, signature: entry.signature, authorDeviceId: entry.authorDeviceId)
    }

    /// Does `incoming` win the LWW conflict against `existing`?
    ///
    /// Total order on (timestamp, authorDeviceId): a strictly-greater timestamp
    /// wins; on an equal timestamp the lexicographically-higher authorDeviceId
    /// wins. The device-id tie-break makes resolution deterministic and
    /// order-independent across replicas (a true CRDT) instead of "whichever
    /// write happened to arrive first" — which would let two devices converge to
    /// different states on an equal-timestamp conflict. Equal timestamp AND equal
    /// author is the same logical write (idempotent → existing is kept).
    private func supersedes(_ incoming: ModelEntry, over existing: ModelEntry?) -> Bool {
        guard let existing = existing else { return true }
        if incoming.timestamp != existing.timestamp { return incoming.timestamp > existing.timestamp }
        return incoming.authorDeviceId > existing.authorDeviceId
    }

    public func get(_ id: String) async -> ModelEntry? {
        await ensureLoaded()
        return entries[id]
    }

    public func has(_ id: String) async -> Bool {
        await ensureLoaded()
        return entries[id] != nil
    }

    public func getAll() async -> [ModelEntry] {
        await ensureLoaded()
        return Array(entries.values)
    }

    public func size() async -> Int {
        await ensureLoaded()
        return entries.count
    }

    /// Delete via tombstone pattern. Preserves the prior entry's fields (plus
    /// _deleted) so a delete on a 1:1 model still carries the routing field (e.g.
    /// conversationId) when broadcast; otherwise scoped routing can't resolve the
    /// audience and could fall through to a broadcast. Mirrors ObscuraKit-Kotlin.
    public func delete(_ id: String, authorDeviceId: String) async -> ModelEntry {
        await ensureLoaded()
        var data = entries[id]?.data ?? [:]
        data["_deleted"] = true
        let tombstone = ModelEntry(
            id: id,
            data: data,
            timestamp: await MonotonicClock.shared.now(),
            signature: Data(),
            authorDeviceId: authorDeviceId
        )
        await store.put(modelName, tombstone)
        entries[id] = tombstone
        return tombstone
    }

    /// Filter entries, excluding tombstones by default.
    public func filter(_ predicate: (ModelEntry) -> Bool, includeTombstones: Bool = false) async -> [ModelEntry] {
        await ensureLoaded()
        var result = Array(entries.values)
        if !includeTombstones {
            result = result.filter { !$0.isDeleted }
        }
        return result.filter(predicate)
    }

    /// Get all non-deleted entries sorted by timestamp.
    public func getAllSorted(order: SortOrder = .desc) async -> [ModelEntry] {
        await ensureLoaded()
        let live = entries.values.filter { !$0.isDeleted }
        switch order {
        case .desc:
            return live.sorted { $0.timestamp > $1.timestamp }
        case .asc:
            return live.sorted { $0.timestamp < $1.timestamp }
        }
    }
}
