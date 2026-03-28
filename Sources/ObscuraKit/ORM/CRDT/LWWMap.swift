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

    /// Set/update an entry. Only updates if timestamp is newer.
    /// Returns the winning entry (might be existing if it was newer).
    public func set(_ entry: ModelEntry) async -> ModelEntry {
        await ensureLoaded()
        if let existing = entries[entry.id], entry.timestamp <= existing.timestamp {
            return existing
        }
        await store.put(modelName, entry)
        entries[entry.id] = entry
        return entry
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
            if let existing = self.entries[entry.id] {
                if entry.timestamp > existing.timestamp {
                    await store.put(modelName, entry)
                    self.entries[entry.id] = entry
                    updated.append(entry)
                }
            } else {
                await store.put(modelName, entry)
                self.entries[entry.id] = entry
                updated.append(entry)
            }
        }
        return updated
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

    /// Delete via tombstone pattern.
    public func delete(_ id: String, authorDeviceId: String) async -> ModelEntry {
        await ensureLoaded()
        let tombstone = ModelEntry(
            id: id,
            data: ["_deleted": true],
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
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
