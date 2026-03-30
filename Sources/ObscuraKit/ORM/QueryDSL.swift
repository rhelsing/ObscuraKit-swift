import Foundation

// MARK: - Query DSL
//
// Clean string-based query syntax matching the Kotlin DSL:
//
//   story.where { "author" == "alice" }.exec()
//   story.where { "likes" >= 5; "likes" <= 25 }.exec()
//   story.where { "author".oneOf(["alice", "bob"]) }.exec()
//   story.where { "title".contains("hello") }.exec()
//
// Full chain:
//   story.where { "published" == true }
//       .orderBy("likes")
//       .limit(10)
//       .exec()

/// A single query condition built by the DSL.
public struct QueryCondition {
    let field: String
    let op: String
    let value: Any
}

/// Result builder that collects query conditions.
@resultBuilder
public struct QueryDSLBuilder {
    public static func buildBlock(_ conditions: [QueryCondition]...) -> [QueryCondition] {
        conditions.flatMap { $0 }
    }

    public static func buildExpression(_ condition: QueryCondition) -> [QueryCondition] {
        [condition]
    }

    public static func buildExpression(_ conditions: [QueryCondition]) -> [QueryCondition] {
        conditions
    }
}

// MARK: - String operators for DSL

/// Makes "field" == value produce a QueryCondition.
public func == (field: String, value: Any) -> QueryCondition {
    QueryCondition(field: field, op: "eq", value: value)
}

/// "field" != value
public func != (field: String, value: Any) -> QueryCondition {
    QueryCondition(field: field, op: "not", value: value)
}

/// "field" > value
public func > (field: String, value: Any) -> QueryCondition {
    QueryCondition(field: field, op: "greaterThan", value: value)
}

/// "field" >= value
public func >= (field: String, value: Any) -> QueryCondition {
    QueryCondition(field: field, op: "atLeast", value: value)
}

/// "field" < value
public func < (field: String, value: Any) -> QueryCondition {
    QueryCondition(field: field, op: "lessThan", value: value)
}

/// "field" <= value
public func <= (field: String, value: Any) -> QueryCondition {
    QueryCondition(field: field, op: "atMost", value: value)
}

// MARK: - String extensions for named operators

public extension String {
    /// "author".oneOf(["alice", "bob"])
    func oneOf(_ values: [Any]) -> QueryCondition {
        QueryCondition(field: self, op: "oneOf", value: values)
    }

    /// "author".noneOf(["alice", "bob"])
    func noneOf(_ values: [Any]) -> QueryCondition {
        QueryCondition(field: self, op: "noneOf", value: values)
    }

    /// "title".contains("hello")
    func contains(_ value: String) -> QueryCondition {
        QueryCondition(field: self, op: "contains", value: value)
    }

    /// "title".startsWith("Hello")
    func startsWith(_ value: String) -> QueryCondition {
        QueryCondition(field: self, op: "startsWith", value: value)
    }

    /// "title".endsWith("world")
    func endsWith(_ value: String) -> QueryCondition {
        QueryCondition(field: self, op: "endsWith", value: value)
    }
}

// MARK: - Model DSL integration

extension Model {
    /// Query with clean DSL syntax.
    ///
    /// ```swift
    /// story.where { "author" == "alice" }.exec()
    /// story.where { "likes" >= 5; "likes" <= 25 }.exec()
    /// story.where { "author".oneOf(["alice", "bob"]) }.exec()
    /// ```
    public func `where`(@QueryDSLBuilder _ build: () -> [QueryCondition]) -> QueryBuilder {
        var conditions: [String: Any] = [:]
        for cond in build() {
            let key = "data.\(cond.field)"
            if cond.op == "eq" {
                conditions[key] = cond.value
            } else {
                // Merge multiple ops on the same field (e.g., atLeast + atMost)
                if var existing = conditions[key] as? [String: Any] {
                    existing[cond.op] = cond.value
                    conditions[key] = existing
                } else {
                    conditions[key] = [cond.op: cond.value]
                }
            }
        }
        return QueryBuilder(model: self, conditions: conditions)
    }
}

// MARK: - TypedModel DSL integration

extension TypedModel {
    /// Query with clean DSL syntax on typed models.
    public func `where`(@QueryDSLBuilder _ build: () -> [QueryCondition]) -> TypedDSLQuery<T> {
        TypedDSLQuery(typedModel: self, conditions: build())
    }
}

/// Query built from DSL that returns typed results.
public class TypedDSLQuery<T: SyncModel> {
    private let typedModel: TypedModel<T>
    private let conditions: [QueryCondition]
    private var sortField: String?
    private var sortOrder: SortOrder = .desc
    private var limitCount: Int?

    init(typedModel: TypedModel<T>, conditions: [QueryCondition]) {
        self.typedModel = typedModel
        self.conditions = conditions
    }

    public func orderBy(_ field: String, _ order: SortOrder = .desc) -> TypedDSLQuery<T> {
        self.sortField = "data.\(field)"
        self.sortOrder = order
        return self
    }

    public func limit(_ n: Int) -> TypedDSLQuery<T> {
        self.limitCount = n
        return self
    }

    public func exec() async -> [TypedEntry<T>] {
        var condMap: [String: Any] = [:]
        for cond in conditions {
            let key = "data.\(cond.field)"
            if cond.op == "eq" {
                condMap[key] = cond.value
            } else {
                if var existing = condMap[key] as? [String: Any] {
                    existing[cond.op] = cond.value
                    condMap[key] = existing
                } else {
                    condMap[key] = [cond.op: cond.value]
                }
            }
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

    public func first() async -> TypedEntry<T>? {
        await exec().first
    }

    public func count() async -> Int {
        await exec().count
    }

    /// Reactive observation of this query. Emits typed results on every DB write.
    ///
    /// ```swift
    /// for await msgs in messages.where { "conversationId" == friendId }.observe().values { ... }
    /// ```
    public func observe() -> TypedObservation<T> {
        var condMap: [String: Any] = [:]
        for cond in conditions {
            let key = "data.\(cond.field)"
            if cond.op == "eq" {
                condMap[key] = cond.value
            } else {
                if var existing = condMap[key] as? [String: Any] {
                    existing[cond.op] = cond.value
                    condMap[key] = existing
                } else {
                    condMap[key] = [cond.op: cond.value]
                }
            }
        }

        var query = typedModel.model.where(condMap)
        if let field = sortField {
            query = query.orderBy(field, sortOrder)
        }
        if let limit = limitCount {
            query = query.limit(limit)
        }

        let rawObservation = query.observe()
        return TypedObservation(observation: rawObservation)
    }
}
