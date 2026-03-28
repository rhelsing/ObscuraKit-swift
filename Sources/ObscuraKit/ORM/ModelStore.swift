import Foundation
import GRDB

/// Persistence layer for ORM model entries.
/// Mirrors src/v2/orm/storage/ModelStore.js
public class ModelStore {
    private let db: DatabaseQueue

    public init(db: DatabaseQueue) throws {
        self.db = db
        try Self.createTables(db)
    }

    /// In-memory store for testing
    public init() throws {
        self.db = try DatabaseQueue()
        try Self.createTables(db)
    }

    private static func createTables(_ db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS model_entries (
                    model_name TEXT NOT NULL,
                    id TEXT NOT NULL,
                    data TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    signature BLOB NOT NULL,
                    author_device_id TEXT NOT NULL,
                    PRIMARY KEY (model_name, id)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS associations (
                    parent_type TEXT NOT NULL,
                    parent_id TEXT NOT NULL,
                    child_type TEXT NOT NULL,
                    child_id TEXT NOT NULL,
                    PRIMARY KEY (parent_type, parent_id, child_type, child_id)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS ttl (
                    model_name TEXT NOT NULL,
                    id TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    PRIMARY KEY (model_name, id)
                )
            """)
        }
    }

    // MARK: - Model Entries

    public func put(_ modelName: String, _ entry: ModelEntry) async {
        let jsonData = try? JSONSerialization.data(withJSONObject: entry.data)
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        try? await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO model_entries (model_name, id, data, timestamp, signature, author_device_id)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [modelName, entry.id, jsonString, entry.timestamp, entry.signature, entry.authorDeviceId])
        }
    }

    public func get(_ modelName: String, _ id: String) async -> ModelEntry? {
        try? await db.read { db -> ModelEntry? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, data, timestamp, signature, author_device_id
                FROM model_entries WHERE model_name = ? AND id = ?
            """, arguments: [modelName, id]) else { return nil }
            return Self.rowToEntry(row)
        }
    }

    public func getAll(_ modelName: String) async -> [ModelEntry] {
        (try? await db.read { db -> [ModelEntry] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, data, timestamp, signature, author_device_id
                FROM model_entries WHERE model_name = ?
            """, arguments: [modelName])
            return rows.compactMap { Self.rowToEntry($0) }
        }) ?? []
    }

    public func delete(_ modelName: String, _ id: String) async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM model_entries WHERE model_name = ? AND id = ?",
                           arguments: [modelName, id])
        }
    }

    public func has(_ modelName: String, _ id: String) async -> Bool {
        let count = try? await db.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM model_entries WHERE model_name = ? AND id = ?",
                            arguments: [modelName, id]) ?? 0
        }
        return (count ?? 0) > 0
    }

    public func clearModel(_ modelName: String) async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM model_entries WHERE model_name = ?", arguments: [modelName])
        }
    }

    // MARK: - Associations

    public func addAssociation(parentType: String, parentId: String, childType: String, childId: String) async {
        try? await db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO associations (parent_type, parent_id, child_type, child_id)
                VALUES (?, ?, ?, ?)
            """, arguments: [parentType, parentId, childType, childId])
        }
    }

    public func getChildren(parentType: String, parentId: String, childType: String) async -> [String] {
        (try? await db.read { db -> [String] in
            try String.fetchAll(db, sql: """
                SELECT child_id FROM associations
                WHERE parent_type = ? AND parent_id = ? AND child_type = ?
            """, arguments: [parentType, parentId, childType])
        }) ?? []
    }

    // MARK: - TTL

    public func setTTL(modelName: String, id: String, expiresAt: UInt64) async {
        try? await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO ttl (model_name, id, expires_at)
                VALUES (?, ?, ?)
            """, arguments: [modelName, id, expiresAt])
        }
    }

    public func getTTL(modelName: String, id: String) async -> UInt64? {
        try? await db.read { db -> UInt64? in
            try UInt64.fetchOne(db, sql: "SELECT expires_at FROM ttl WHERE model_name = ? AND id = ?",
                               arguments: [modelName, id])
        }
    }

    public func getExpired() async -> [(modelName: String, id: String)] {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        return (try? await db.read { db -> [(String, String)] in
            let rows = try Row.fetchAll(db, sql: "SELECT model_name, id FROM ttl WHERE expires_at <= ?",
                                        arguments: [now])
            return rows.map { ($0["model_name"] as String, $0["id"] as String) }
        }) ?? []
    }

    // MARK: - Helpers

    private static func rowToEntry(_ row: Row) -> ModelEntry? {
        let jsonString: String = row["data"]
        let data: [String: Any]
        if let jsonData = jsonString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            data = parsed
        } else {
            data = [:]
        }

        return ModelEntry(
            id: row["id"],
            data: data,
            timestamp: UInt64(row["timestamp"] as Int64),
            signature: row["signature"],
            authorDeviceId: row["author_device_id"]
        )
    }
}
