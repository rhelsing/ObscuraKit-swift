import Foundation
import CryptoKit
import GRDB

/// Sync strategy for a model — determines CRDT type.
public enum SyncStrategy: String, Sendable {
    case gset    // Grow-only set. Immutable content (stories, comments, messages).
    case lwwMap  // Last-writer-wins map. Mutable state (profiles, settings).
}

/// Sync scope — determines who receives MODEL_SYNC broadcasts.
public enum SyncScope: Sendable {
    case friends      // All accepted friends + own devices
    case ownDevices   // Only own devices (private models like settings)
    case group        // Look up members from parent model's data.members field
}

/// TTL configuration for ephemeral models.
public enum TTL: Sendable {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)

    public var milliseconds: UInt64 {
        switch self {
        case .seconds(let n): return UInt64(n) * 1000
        case .minutes(let n): return UInt64(n) * 60 * 1000
        case .hours(let n): return UInt64(n) * 3600 * 1000
        case .days(let n): return UInt64(n) * 86400 * 1000
        }
    }
}

/// Model definition — passed to SchemaBuilder to create a Model instance.
public struct ModelDefinition: Sendable {
    public let name: String
    public let sync: SyncStrategy
    public let syncScope: SyncScope
    public let ttl: TTL?
    public let fields: [String: FieldType]
    public let belongsTo: [String]
    public let hasMany: [String]
    public let isPrivate: Bool

    public init(
        name: String,
        sync: SyncStrategy,
        syncScope: SyncScope = .friends,
        ttl: TTL? = nil,
        fields: [String: FieldType] = [:],
        belongsTo: [String] = [],
        hasMany: [String] = [],
        isPrivate: Bool = false
    ) {
        self.name = name
        self.sync = sync
        self.syncScope = syncScope
        self.ttl = ttl
        self.fields = fields
        self.belongsTo = belongsTo
        self.hasMany = hasMany
        self.isPrivate = isPrivate
    }
}

/// Field type for schema validation.
public enum FieldType: String, Sendable {
    case string
    case number
    case boolean
    case optionalString = "string?"
    case optionalNumber = "number?"
    case optionalBoolean = "boolean?"

    public var isOptional: Bool {
        switch self {
        case .optionalString, .optionalNumber, .optionalBoolean: return true
        default: return false
        }
    }
}

/// ORM Model — the generic class for all model types.
/// Wraps a CRDT (GSet or LWWMap) with schema validation, signing, and query support.
/// Mirrors src/v2/orm/Model.js
public class Model {
    public let name: String
    public let definition: ModelDefinition
    private let crdt: AnyCRDT
    private let store: ModelStore
    public var deviceId: String = ""

    /// Exposed for QueryBuilder observation
    internal var storeDB: DatabaseQueue { store.dbQueue }

    /// Callback for broadcasting — set by SyncManager
    internal var onBroadcast: ((String, ModelEntry) async -> Void)?

    /// TTL manager — set by schema()
    internal var ttlManager: TTLManager?

    /// Model resolver for include() eager loading — set by SyncManager
    internal var modelResolver: ((String) -> Model?)?

    public init(name: String, definition: ModelDefinition, store: ModelStore) {
        self.name = name
        self.definition = definition
        self.store = store

        switch definition.sync {
        case .gset:
            self.crdt = AnyCRDT(gset: GSet(store: store, modelName: name))
        case .lwwMap:
            self.crdt = AnyCRDT(lwwMap: LWWMap(store: store, modelName: name))
        }
    }

    // MARK: - CRUD

    /// Create a new entry. Validates fields, generates ID, signs, persists, broadcasts.
    public func create(_ data: [String: Any]) async throws -> ModelEntry {
        try validate(data)

        let id = "\(name)_\(UInt64(Date().timeIntervalSince1970 * 1000))_\(randomId())"
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let entry = ModelEntry(
            id: id,
            data: data,
            timestamp: timestamp,
            signature: sign(id: id, data: data, timestamp: timestamp),
            authorDeviceId: deviceId
        )

        let result = await crdt.add(entry)

        // Track belongs_to associations
        for parent in definition.belongsTo {
            let foreignKey = "\(parent)Id"
            if let parentId = data[foreignKey] as? String {
                await store.addAssociation(parentType: parent, parentId: parentId, childType: name, childId: id)
            }
        }

        // Schedule TTL if configured
        if let ttl = definition.ttl {
            await ttlManager?.schedule(modelName: name, id: id, ttl: ttl)
        }

        // Broadcast via SyncManager
        await onBroadcast?(name, result)

        return result
    }

    /// Upsert (create or update). LWW models only.
    public func upsert(_ id: String, _ data: [String: Any]) async throws -> ModelEntry {
        guard definition.sync == .lwwMap else {
            throw ModelError.invalidOperation("upsert only works on LWW models")
        }
        try validate(data)

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let entry = ModelEntry(
            id: id,
            data: data,
            timestamp: timestamp,
            signature: sign(id: id, data: data, timestamp: timestamp),
            authorDeviceId: deviceId
        )

        let result = await crdt.set(entry)
        await onBroadcast?(name, result)
        return result
    }

    /// Find by ID.
    public func find(_ id: String) async -> ModelEntry? {
        await crdt.get(id)
    }

    /// Get all entries.
    public func all() async -> [ModelEntry] {
        await crdt.getAll()
    }

    /// Get all entries sorted by timestamp.
    public func allSorted(order: SortOrder = .desc) async -> [ModelEntry] {
        await crdt.getAllSorted(order: order)
    }

    /// Delete by ID (LWW tombstone). Throws on GSet models.
    public func delete(_ id: String) async throws -> ModelEntry {
        guard definition.sync == .lwwMap else {
            throw ModelError.invalidOperation("cannot delete from GSet model (immutable)")
        }
        guard let lww = crdt.lwwMap else {
            throw ModelError.invalidOperation("internal: no LWWMap")
        }
        let tombstone = await lww.delete(id, authorDeviceId: deviceId)
        await onBroadcast?(name, tombstone)
        return tombstone
    }

    /// Build a query. Returns a QueryBuilder for chaining.
    public func `where`(_ conditions: [String: Any]) -> QueryBuilder {
        let qb = QueryBuilder(model: self, conditions: conditions)
        qb.modelResolver = modelResolver
        return qb
    }

    // MARK: - Reactive Observation

    /// Observe all entries for this model. Emits on every DB write.
    /// SwiftUI: `for await entries in client.model("story")!.observe().values { ... }`
    public func observe() -> AsyncValueObservation<[ModelEntry]> {
        let modelName = self.name
        let observation = ValueObservation.tracking { db -> [ModelEntry] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, data, timestamp, signature, author_device_id
                FROM model_entries WHERE model_name = ?
                ORDER BY timestamp DESC
            """, arguments: [modelName])
            return rows.compactMap { row -> ModelEntry? in
                let jsonString: String = row["data"]
                let data: [String: Any]
                if let jsonData = jsonString.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    data = parsed
                } else {
                    data = [:]
                }
                let entry = ModelEntry(
                    id: row["id"],
                    data: data,
                    timestamp: UInt64(row["timestamp"] as Int64),
                    signature: row["signature"],
                    authorDeviceId: row["author_device_id"]
                )
                // Exclude tombstones
                if entry.isDeleted { return nil }
                return entry
            }
        }
        return AsyncValueObservation(observation: observation, in: store.dbQueue)
    }

    /// Handle incoming MODEL_SYNC from a remote peer.
    public func handleSync(_ entry: ModelEntry) async -> [ModelEntry] {
        let merged = await crdt.merge([entry])

        // Track associations for merged entries
        for mergedEntry in merged {
            for parent in definition.belongsTo {
                let foreignKey = "\(parent)Id"
                if let parentId = mergedEntry.data[foreignKey] as? String {
                    await store.addAssociation(parentType: parent, parentId: parentId, childType: name, childId: mergedEntry.id)
                }
            }
        }

        return merged
    }

    /// Batch load children into parent entries for eager loading.
    /// Adds a "children" key to each parent's data with matching child entries.
    public func loadInto(_ parents: [ModelEntry], foreignKey: String) async -> [[String: Any]] {
        let allEntries = await crdt.getAll()
        var results: [[String: Any]] = []

        for parent in parents {
            let children = allEntries.filter { entry in
                (entry.data[foreignKey] as? String) == parent.id
            }
            var parentData = parent.data
            parentData["\(name)s"] = children.map { $0.data }
            results.append(parentData)
        }
        return results
    }

    // MARK: - Validation

    private func validate(_ data: [String: Any]) throws {
        for (field, type) in definition.fields {
            let value = data[field]

            if value == nil || value is NSNull {
                if !type.isOptional {
                    throw ModelError.validationFailed("missing required field: \(field)")
                }
                continue
            }

            switch type {
            case .string, .optionalString:
                if !(value is String) { throw ModelError.validationFailed("field '\(field)' must be a string") }
            case .number, .optionalNumber:
                if !(value is Int || value is Double || value is UInt64 || value is Float) {
                    throw ModelError.validationFailed("field '\(field)' must be a number")
                }
            case .boolean, .optionalBoolean:
                if !(value is Bool) { throw ModelError.validationFailed("field '\(field)' must be a boolean") }
            }
        }
    }

    // MARK: - Signing

    private func sign(id: String, data: [String: Any], timestamp: UInt64) -> Data {
        let payload = "\(name):\(id):\(timestamp):\(deviceId)"
        let hash = SHA256.hash(data: Data(payload.utf8))
        return Data(hash)
    }

    // MARK: - Helpers

    private func randomId(_ length: Int = 8) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    public enum ModelError: Error, LocalizedError {
        case validationFailed(String)
        case invalidOperation(String)

        public var errorDescription: String? {
            switch self {
            case .validationFailed(let msg): return "Validation: \(msg)"
            case .invalidOperation(let msg): return "Invalid: \(msg)"
            }
        }
    }
}

// MARK: - AnyCRDT (type-erased wrapper)

/// Wraps GSet or LWWMap so Model doesn't need to be generic.
internal class AnyCRDT {
    private let gset_: GSet?
    internal let lwwMap: LWWMap?

    init(gset: GSet) { self.gset_ = gset; self.lwwMap = nil }
    init(lwwMap: LWWMap) { self.gset_ = nil; self.lwwMap = lwwMap }

    func add(_ entry: ModelEntry) async -> ModelEntry {
        if let gset = gset_ { return await gset.add(entry) }
        if let lww = lwwMap { return await lww.add(entry) }
        return entry
    }

    func set(_ entry: ModelEntry) async -> ModelEntry {
        if let lww = lwwMap { return await lww.set(entry) }
        return await add(entry)
    }

    func get(_ id: String) async -> ModelEntry? {
        if let gset = gset_ { return await gset.get(id) }
        if let lww = lwwMap { return await lww.get(id) }
        return nil
    }

    func getAll() async -> [ModelEntry] {
        if let gset = gset_ { return await gset.getAll() }
        if let lww = lwwMap { return await lww.getAll() }
        return []
    }

    func getAllSorted(order: SortOrder) async -> [ModelEntry] {
        if let gset = gset_ { return await gset.getAllSorted(order: order) }
        if let lww = lwwMap { return await lww.getAllSorted(order: order) }
        return []
    }

    func merge(_ entries: [ModelEntry]) async -> [ModelEntry] {
        if let gset = gset_ { return await gset.merge(entries) }
        if let lww = lwwMap { return await lww.merge(entries) }
        return []
    }
}
