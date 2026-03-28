import Foundation

/// GSet - Grow-only Set CRDT
///
/// Used for immutable content: stories, comments, messages, friend requests.
/// Add-only, merge = union, idempotent, convergent.
public class GSet {
    private let store: ModelStore
    private let modelName: String
    private var elements: [String: ModelEntry] = [:]
    private var loaded = false

    public init(store: ModelStore, modelName: String) {
        self.store = store
        self.modelName = modelName
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        let entries = await store.getAll(modelName)
        for entry in entries {
            elements[entry.id] = entry
        }
        loaded = true
    }

    /// Add an entry. Idempotent — existing ID returns existing entry.
    public func add(_ entry: ModelEntry) async -> ModelEntry {
        await ensureLoaded()
        if let existing = elements[entry.id] {
            return existing
        }
        await store.put(modelName, entry)
        elements[entry.id] = entry
        return entry
    }

    /// Merge remote entries. Returns entries that were actually added.
    public func merge(_ entries: [ModelEntry]) async -> [ModelEntry] {
        await ensureLoaded()
        var added: [ModelEntry] = []
        for entry in entries {
            if elements[entry.id] == nil {
                await store.put(modelName, entry)
                elements[entry.id] = entry
                added.append(entry)
            }
        }
        return added
    }

    public func get(_ id: String) async -> ModelEntry? {
        await ensureLoaded()
        return elements[id]
    }

    public func has(_ id: String) async -> Bool {
        await ensureLoaded()
        return elements[id] != nil
    }

    public func getAll() async -> [ModelEntry] {
        await ensureLoaded()
        return Array(elements.values)
    }

    public func size() async -> Int {
        await ensureLoaded()
        return elements.count
    }

    public func filter(_ predicate: (ModelEntry) -> Bool) async -> [ModelEntry] {
        await ensureLoaded()
        return elements.values.filter(predicate)
    }

    public func getAllSorted(order: SortOrder = .desc) async -> [ModelEntry] {
        await ensureLoaded()
        let entries = Array(elements.values)
        switch order {
        case .desc:
            return entries.sorted { $0.timestamp > $1.timestamp }
        case .asc:
            return entries.sorted { $0.timestamp < $1.timestamp }
        }
    }
}
