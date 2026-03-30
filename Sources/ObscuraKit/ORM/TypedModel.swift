import Foundation
import GRDB

// MARK: - SyncModel Protocol

/// Protocol for typed ORM models. Conform to this + Codable to get type-safe CRUD + sync.
///
/// ```swift
/// struct Story: SyncModel {
///     static let modelName = "story"
///     static let sync: SyncStrategy = .gset
///     static let scope: SyncScope = .friends
///     static let ttl: TTL? = .hours(24)
///
///     var content: String
///     var mediaUrl: String?
///     var authorUsername: String
/// }
///
/// // Usage:
/// let stories = client.register(Story.self)
/// try await stories.create(Story(content: "sunset", authorUsername: "alice"))
/// let all = try await stories.all()
/// let filtered = try await stories.where(\.authorUsername, .equals("alice")).exec()
/// for await updated in stories.observe().values { ... }
/// ```
public protocol SyncModel: Codable, Sendable {
    static var modelName: String { get }
    static var sync: SyncStrategy { get }
    static var scope: SyncScope { get }
    static var ttl: TTL? { get }
}

/// Default implementations — most models just need name + sync strategy.
public extension SyncModel {
    static var scope: SyncScope { .friends }
    static var ttl: TTL? { nil }
}

// MARK: - TypedModel<T>

/// Type-safe wrapper around Model. Provides typed CRUD, queries, and observation.
/// Created via `client.register(Story.self)`.
public class TypedModel<T: SyncModel> {
    internal let model: Model
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    internal init(model: Model) {
        self.model = model
    }

    // MARK: - CRUD

    /// Create a new entry from a typed value.
    @discardableResult
    public func create(_ value: T) async throws -> TypedEntry<T> {
        let data = try toDictionary(value)
        let entry = try await model.create(data)
        return TypedEntry(entry: entry, value: value)
    }

    /// Find by ID and decode to typed value.
    public func find(_ id: String) async -> TypedEntry<T>? {
        guard let entry = await model.find(id) else { return nil }
        guard let value = fromDictionary(entry.data) else { return nil }
        return TypedEntry(entry: entry, value: value)
    }

    /// Get all entries as typed values.
    public func all() async -> [TypedEntry<T>] {
        let entries = await model.all()
        return entries.compactMap { entry in
            guard let value = fromDictionary(entry.data) else { return nil }
            return TypedEntry(entry: entry, value: value)
        }
    }

    /// Get all entries sorted by timestamp.
    public func allSorted(order: SortOrder = .desc) async -> [TypedEntry<T>] {
        let entries = await model.allSorted(order: order)
        return entries.compactMap { entry in
            guard let value = fromDictionary(entry.data) else { return nil }
            return TypedEntry(entry: entry, value: value)
        }
    }

    /// Upsert (LWW models only).
    @discardableResult
    public func upsert(_ id: String, _ value: T) async throws -> TypedEntry<T> {
        let data = try toDictionary(value)
        let entry = try await model.upsert(id, data)
        return TypedEntry(entry: entry, value: value)
    }

    /// Delete by ID (LWW tombstone).
    public func delete(_ id: String) async throws {
        _ = try await model.delete(id)
    }

    // MARK: - Typed Queries

    /// Query with a KeyPath condition.
    /// `stories.where(\.authorUsername, .equals("alice")).exec()`
    public func `where`<V: Sendable>(_ keyPath: KeyPath<T, V>, _ op: QueryOp) -> TypedQuery<T> {
        let fieldName = Mirror.fieldName(of: T.self, keyPath: keyPath) ?? "unknown"
        return TypedQuery(model: self, conditions: [("data.\(fieldName)", op)])
    }

    /// Query with multiple conditions.
    public func `where`(_ conditions: [(KeyPath<T, Any>, QueryOp)]) -> TypedQuery<T> {
        // Simplified: use the untyped where for complex queries
        TypedQuery(model: self, conditions: [])
    }

    /// All entries matching a closure predicate.
    public func filter(_ predicate: @Sendable (T) -> Bool) async -> [TypedEntry<T>] {
        let entries = await model.all()
        return entries.compactMap { entry in
            guard let value = fromDictionary(entry.data) else { return nil }
            guard predicate(value) else { return nil }
            return TypedEntry(entry: entry, value: value)
        }
    }

    // MARK: - Observation

    /// Reactive observation of all entries. Emits typed values on every DB write.
    public func observe() -> TypedObservation<T> {
        TypedObservation(observation: model.observe())
    }

    // MARK: - Encoding / Decoding

    private func toDictionary(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Model.ModelError.validationFailed("Could not encode to dictionary")
        }
        return dict
    }

    internal func fromDictionary(_ dict: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}

// MARK: - TypedEntry<T>

/// A model entry with both the raw entry (id, timestamp, etc.) and the decoded typed value.
public struct TypedEntry<T: SyncModel>: Sendable {
    public let entry: ModelEntry
    public let value: T

    public var id: String { entry.id }
    public var timestamp: UInt64 { entry.timestamp }
    public var authorDeviceId: String { entry.authorDeviceId }
}

// MARK: - TypedObservation<T>

/// Bridges AsyncValueObservation<[ModelEntry]> to typed values.
public struct TypedObservation<T: SyncModel> {
    private let observation: AsyncValueObservation<[ModelEntry]>

    init(observation: AsyncValueObservation<[ModelEntry]>) {
        self.observation = observation
    }

    /// Typed async stream. Emits decoded values on every DB write.
    public var values: AsyncStream<[T]> {
        let decoder = JSONDecoder()
        return AsyncStream { continuation in
            let task = Task {
                for await entries in observation.values {
                    let typed: [T] = entries.compactMap { entry in
                        guard let data = try? JSONSerialization.data(withJSONObject: entry.data),
                              let value = try? decoder.decode(T.self, from: data) else { return nil }
                        return value
                    }
                    continuation.yield(typed)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Query Operators

/// Query operator for typed queries.
public enum QueryOp: Sendable {
    case equals(Any)
    case not(Any)
    case greaterThan(Any)
    case atLeast(Any)
    case lessThan(Any)
    case atMost(Any)
    case oneOf([Any])
    case noneOf([Any])
    case contains(String)
    case startsWith(String)
    case endsWith(String)

    /// Convert to the untyped condition map format.
    internal var conditionValue: Any {
        switch self {
        case .equals(let v): return v
        case .not(let v): return ["not": v]
        case .greaterThan(let v): return ["greaterThan": v]
        case .atLeast(let v): return ["atLeast": v]
        case .lessThan(let v): return ["lessThan": v]
        case .atMost(let v): return ["atMost": v]
        case .oneOf(let v): return ["oneOf": v]
        case .noneOf(let v): return ["noneOf": v]
        case .contains(let v): return ["contains": v]
        case .startsWith(let v): return ["startsWith": v]
        case .endsWith(let v): return ["endsWith": v]
        }
    }
}

// MARK: - TypedQuery<T>

/// Typed query builder. Chains where/orderBy/limit and returns typed results.
public class TypedQuery<T: SyncModel> {
    private let typedModel: TypedModel<T>
    private var conditions: [(String, QueryOp)]
    private var sortField: String?
    private var sortOrder: SortOrder = .desc
    private var limitCount: Int?

    init(model: TypedModel<T>, conditions: [(String, QueryOp)]) {
        self.typedModel = model
        self.conditions = conditions
    }

    /// Add another where condition.
    public func `where`<V: Sendable>(_ keyPath: KeyPath<T, V>, _ op: QueryOp) -> TypedQuery<T> {
        let fieldName = Mirror.fieldName(of: T.self, keyPath: keyPath) ?? "unknown"
        conditions.append(("data.\(fieldName)", op))
        return self
    }

    /// Sort by a field.
    public func orderBy<V: Sendable>(_ keyPath: KeyPath<T, V>, _ order: SortOrder = .desc) -> TypedQuery<T> {
        let fieldName = Mirror.fieldName(of: T.self, keyPath: keyPath) ?? "unknown"
        self.sortField = "data.\(fieldName)"
        self.sortOrder = order
        return self
    }

    /// Limit results.
    public func limit(_ n: Int) -> TypedQuery<T> {
        self.limitCount = n
        return self
    }

    /// Execute and return typed results.
    public func exec() async -> [TypedEntry<T>] {
        // Build untyped conditions
        var condMap: [String: Any] = [:]
        for (field, op) in conditions {
            condMap[field] = op.conditionValue
        }

        var query = typedModel.model.where(condMap)
        if let field = sortField {
            query = query.orderBy(field, sortOrder)
        }
        if let limit = limitCount {
            query = query.limit(limit)
        }

        let entries = await query.exec()
        return entries.compactMap { entry in
            guard let value = typedModel.fromDictionary(entry.data) else { return nil }
            return TypedEntry(entry: entry, value: value)
        }
    }

    /// Execute and return the first match.
    public func first() async -> TypedEntry<T>? {
        let results = await exec()
        return results.first
    }

    /// Execute and return count.
    public func count() async -> Int {
        await exec().count
    }
}

// MARK: - Mirror Helper

extension Mirror {
    /// Extract the property name from a KeyPath using Mirror reflection.
    static func fieldName<Root, Value>(of type: Root.Type, keyPath: KeyPath<Root, Value>) -> String? {
        // Create a dummy instance if possible (Codable types can be decoded from empty)
        // Otherwise fall back to type introspection
        let mirror = Mirror(reflecting: keyPath)
        // KeyPath string representation contains the field name
        let description = String(describing: keyPath)
        // Format is \Type.fieldName — extract after the dot
        if let dotIndex = description.lastIndex(of: ".") {
            return String(description[description.index(after: dotIndex)...])
        }
        return nil
    }
}

// MARK: - ObscuraClient Extension

extension ObscuraClient {
    /// Register a typed model and return a TypedModel<T> for type-safe CRUD.
    ///
    /// ```swift
    /// let stories = client.register(Story.self)
    /// try await stories.create(Story(content: "sunset", authorUsername: "alice"))
    /// ```
    public func register<T: SyncModel>(_ type: T.Type) -> TypedModel<T> {
        let def = ModelDefinition(
            name: T.modelName,
            sync: T.sync,
            syncScope: T.scope,
            ttl: T.ttl
        )

        // Use existing schema infrastructure
        if _ormModels[T.modelName] == nil {
            schema([def])
        }

        let model = _ormModels[T.modelName]!
        return TypedModel(model: model)
    }
}
