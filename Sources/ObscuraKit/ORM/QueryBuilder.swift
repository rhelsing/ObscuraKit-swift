import Foundation
import GRDB

/// Chainable query builder for ORM models.
/// Mirrors src/v2/orm/QueryBuilder.js
///
/// Usage:
///   model.where(["data.author": "alice"]).orderBy("data.likes").limit(10).exec()
///   model.where(["data.likes": ["atLeast": 5, "atMost": 25]]).exec()
///   model.where(["data.title": ["contains": "hello"]]).first()
///
/// Operators: equals/eq, not/ne, greaterThan/gt, atLeast/gte,
///            lessThan/lt, atMost/lte, oneOf/in, noneOf/nin,
///            contains, startsWith, endsWith
public class QueryBuilder {
    private let model: Model
    private var conditions: [String: Any]
    private var sortField: String?
    private var sortOrder: SortOrder = .desc
    private var limitCount: Int?
    private var includes: [String] = []

    init(model: Model, conditions: [String: Any]) {
        self.model = model
        self.conditions = conditions
    }

    /// Eager-load a child association by name.
    /// The child model must be registered and have a belongs_to relationship.
    public func include(_ childModelName: String) -> QueryBuilder {
        includes.append(childModelName)
        return self
    }

    /// Sort results by a field. Auto-prefixes "data." if not already present.
    /// `orderBy("likes")` and `orderBy("data.likes")` are equivalent.
    public func orderBy(_ field: String, _ order: SortOrder = .desc) -> QueryBuilder {
        self.sortField = field.hasPrefix("data.") || field == "timestamp" || field == "id" || field == "authorDeviceId"
            ? field : "data.\(field)"
        self.sortOrder = order
        return self
    }

    /// Limit the number of results.
    public func limit(_ n: Int) -> QueryBuilder {
        self.limitCount = n
        return self
    }

    /// Set a resolver for looking up child models by name (for include).
    internal var modelResolver: ((String) -> Model?)?

    /// Execute the query and return matching entries.
    public func exec() async -> [ModelEntry] {
        var entries = await model.all()

        // Filter
        entries = entries.filter { matchesConditions($0) }

        // Sort
        if let field = sortField {
            entries.sort { a, b in
                let valA = resolveField(a, field)
                let valB = resolveField(b, field)
                let cmp = compareValues(valA, valB)
                return sortOrder == .asc ? cmp < 0 : cmp > 0
            }
        }

        // Limit
        if let limit = limitCount {
            entries = Array(entries.prefix(limit))
        }

        // Eager load associations
        if !includes.isEmpty, let resolver = modelResolver {
            for i in 0..<entries.count {
                var entryData = entries[i].data
                for childModelName in includes {
                    if let childModel = resolver(childModelName) {
                        let childEntries = await childModel.all()
                        let foreignKey = "\(model.name)Id"
                        let matching = childEntries.filter { child in
                            (child.data[foreignKey] as? String) == entries[i].id
                        }
                        entryData["\(childModelName)s"] = matching.map { $0.data }
                    }
                }
                entries[i] = ModelEntry(
                    id: entries[i].id,
                    data: entryData,
                    timestamp: entries[i].timestamp,
                    signature: entries[i].signature,
                    authorDeviceId: entries[i].authorDeviceId
                )
            }
        }

        return entries
    }

    /// Execute and return the first matching entry.
    public func first() async -> ModelEntry? {
        let results = await exec()
        return results.first
    }

    /// Execute and return the count of matching entries.
    public func count() async -> Int {
        let results = await exec()
        return results.count
    }

    /// Reactive observation of query results. Emits on every DB write that affects this model.
    /// Filtering happens in-memory after GRDB notifies of a table change.
    ///
    /// ```swift
    /// for await msgs in model.where(["data.conversationId": friendId]).observe().values { ... }
    /// ```
    public func observe() -> AsyncValueObservation<[ModelEntry]> {
        let modelName = model.name
        let conditions = self.conditions
        let sortField = self.sortField
        let sortOrder = self.sortOrder
        let limitCount = self.limitCount

        let observation = ValueObservation.tracking { db -> [ModelEntry] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, data, timestamp, signature, author_device_id
                FROM model_entries WHERE model_name = ?
                ORDER BY timestamp DESC
            """, arguments: [modelName])

            var entries: [ModelEntry] = rows.compactMap { row -> ModelEntry? in
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
                if entry.isDeleted { return nil }
                return entry
            }

            // Apply in-memory filters (same logic as exec())
            entries = entries.filter { entry in
                for (key, condition) in conditions {
                    let value = QueryBuilder.resolveFieldStatic(entry, key)
                    if let ops = condition as? [String: Any] {
                        for (op, target) in ops {
                            if !QueryBuilder.applyOperatorStatic(op, value: value, target: target) {
                                return false
                            }
                        }
                    } else {
                        if !QueryBuilder.isEqualStatic(value, condition) {
                            return false
                        }
                    }
                }
                return true
            }

            // Sort
            if let field = sortField {
                entries.sort { a, b in
                    let valA = QueryBuilder.resolveFieldStatic(a, field)
                    let valB = QueryBuilder.resolveFieldStatic(b, field)
                    let cmp = QueryBuilder.compareValuesStatic(valA, valB)
                    return sortOrder == .asc ? cmp < 0 : cmp > 0
                }
            }

            // Limit
            if let limit = limitCount {
                entries = Array(entries.prefix(limit))
            }

            return entries
        }
        return AsyncValueObservation(observation: observation, in: model.storeDB)
    }

    // MARK: - Matching

    private func matchesConditions(_ entry: ModelEntry) -> Bool {
        for (key, condition) in conditions {
            let value = resolveField(entry, key)

            // Operator map: ["atLeast": 5, "atMost": 25]
            if let ops = condition as? [String: Any] {
                for (op, target) in ops {
                    if !applyOperator(op, value: value, target: target) {
                        return false
                    }
                }
            } else {
                // Simple equality
                if !isEqual(value, condition) {
                    return false
                }
            }
        }
        return true
    }

    private func applyOperator(_ op: String, value: Any?, target: Any) -> Bool {
        switch op {
        // Equality
        case "equals", "eq":
            return isEqual(value, target)
        case "not", "ne":
            return !isEqual(value, target)

        // Comparison
        case "greaterThan", "gt":
            return compareValues(value, target) > 0
        case "atLeast", "gte":
            return compareValues(value, target) >= 0
        case "lessThan", "lt":
            return compareValues(value, target) < 0
        case "atMost", "lte":
            return compareValues(value, target) <= 0

        // Set membership
        case "oneOf", "in":
            guard let list = target as? [Any] else { return false }
            return list.contains { isEqual(value, $0) }
        case "noneOf", "nin":
            guard let list = target as? [Any] else { return true }
            return !list.contains { isEqual(value, $0) }

        // String matching
        case "contains":
            guard let s = value as? String, let t = target as? String else { return false }
            return s.contains(t)
        case "startsWith":
            guard let s = value as? String, let t = target as? String else { return false }
            return s.hasPrefix(t)
        case "endsWith":
            guard let s = value as? String, let t = target as? String else { return false }
            return s.hasSuffix(t)

        default:
            return false
        }
    }

    // MARK: - Field Resolution

    /// Resolve a dot-notation field path against a ModelEntry.
    /// "data.author" → entry.data["author"]
    /// "timestamp" → entry.timestamp
    /// "authorDeviceId" → entry.authorDeviceId
    static func resolveFieldStatic(_ entry: ModelEntry, _ path: String) -> Any? {
        let parts = path.split(separator: ".").map(String.init)

        if parts.first == "data" && parts.count > 1 {
            var current: Any? = entry.data
            for part in parts.dropFirst() {
                guard let dict = current as? [String: Any] else { return nil }
                current = dict[part]
            }
            return current
        }

        switch path {
        case "id": return entry.id
        case "timestamp": return entry.timestamp
        case "authorDeviceId": return entry.authorDeviceId
        default: return entry.data[path]
        }
    }

    private func resolveField(_ entry: ModelEntry, _ path: String) -> Any? {
        let parts = path.split(separator: ".").map(String.init)

        if parts.first == "data" && parts.count > 1 {
            var current: Any? = entry.data
            for part in parts.dropFirst() {
                guard let dict = current as? [String: Any] else { return nil }
                current = dict[part]
            }
            return current
        }

        switch path {
        case "id": return entry.id
        case "timestamp": return entry.timestamp
        case "authorDeviceId": return entry.authorDeviceId
        default:
            // Try top-level data field
            return entry.data[path]
        }
    }

    // MARK: - Static Helpers (for GRDB observation closures)

    static func applyOperatorStatic(_ op: String, value: Any?, target: Any) -> Bool {
        switch op {
        case "equals", "eq": return isEqualStatic(value, target)
        case "not", "ne": return !isEqualStatic(value, target)
        case "greaterThan", "gt": return compareValuesStatic(value, target) > 0
        case "atLeast", "gte": return compareValuesStatic(value, target) >= 0
        case "lessThan", "lt": return compareValuesStatic(value, target) < 0
        case "atMost", "lte": return compareValuesStatic(value, target) <= 0
        case "oneOf", "in":
            guard let list = target as? [Any] else { return false }
            return list.contains { isEqualStatic(value, $0) }
        case "noneOf", "nin":
            guard let list = target as? [Any] else { return true }
            return !list.contains { isEqualStatic(value, $0) }
        case "contains":
            guard let s = value as? String, let t = target as? String else { return false }
            return s.contains(t)
        case "startsWith":
            guard let s = value as? String, let t = target as? String else { return false }
            return s.hasPrefix(t)
        case "endsWith":
            guard let s = value as? String, let t = target as? String else { return false }
            return s.hasSuffix(t)
        default: return false
        }
    }

    static func isEqualStatic(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a, let b = b else { return false }
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? Bool, let b = b as? Bool { return a == b }
        if let a = toDoubleStatic(a), let b = toDoubleStatic(b) { return a == b }
        return "\(a)" == "\(b)"
    }

    static func compareValuesStatic(_ a: Any?, _ b: Any?) -> Int {
        if a == nil && b == nil { return 0 }
        if a == nil { return -1 }
        if b == nil { return 1 }
        if let a = toDoubleStatic(a!), let b = toDoubleStatic(b!) {
            if a < b { return -1 }; if a > b { return 1 }; return 0
        }
        if let a = a as? String, let b = b as? String {
            return a.compare(b) == .orderedAscending ? -1 : (a == b ? 0 : 1)
        }
        return 0
    }

    private static func toDoubleStatic(_ value: Any) -> Double? {
        if let n = value as? Int { return Double(n) }
        if let n = value as? Double { return n }
        if let n = value as? Float { return Double(n) }
        if let n = value as? UInt64 { return Double(n) }
        return nil
    }

    // MARK: - Comparison Helpers

    private func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a, let b = b else { return false }

        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? Bool, let b = b as? Bool { return a == b }
        if let a = toDouble(a), let b = toDouble(b) { return a == b }

        return "\(a)" == "\(b)"
    }

    private func compareValues(_ a: Any?, _ b: Any?) -> Int {
        if a == nil && b == nil { return 0 }
        if a == nil { return -1 }
        if b == nil { return 1 }

        if let a = toDouble(a!), let b = toDouble(b!) {
            if a < b { return -1 }
            if a > b { return 1 }
            return 0
        }

        if let a = a as? String, let b = b as? String {
            return a.compare(b) == .orderedAscending ? -1 : (a == b ? 0 : 1)
        }

        return 0
    }

    private func toDouble(_ value: Any) -> Double? {
        if let n = value as? Int { return Double(n) }
        if let n = value as? Double { return n }
        if let n = value as? Float { return Double(n) }
        if let n = value as? UInt64 { return Double(n) }
        return nil
    }
}
