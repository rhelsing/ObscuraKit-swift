import Foundation
import GRDB

public struct Message: Codable, Sendable, Equatable {
    public var messageId: String
    public var conversationId: String
    public var timestamp: UInt64
    public var content: String
    public var isSent: Bool
    public var authorDeviceId: String?

    public init(messageId: String, conversationId: String, timestamp: UInt64 = 0, content: String, isSent: Bool = false, authorDeviceId: String? = nil) {
        self.messageId = messageId
        self.conversationId = conversationId
        self.timestamp = timestamp != 0 ? timestamp : UInt64(Date().timeIntervalSince1970 * 1000)
        self.content = content
        self.isSent = isSent
        self.authorDeviceId = authorDeviceId
    }
}

public actor MessageActor {
    private let db: DatabaseQueue

    public nonisolated var dbQueue: DatabaseQueue { db }

    public init(db: DatabaseQueue) throws {
        self.db = db
        try Self.createTables(db)
    }

    public init() throws {
        self.db = try DatabaseQueue()
        try db.write { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        try Self.createTables(db)
    }

    // MARK: - Reactive Streams

    /// Stream of messages for a conversation. Emits on every change.
    public nonisolated func observeMessages(_ conversationId: String, limit: Int = 100) -> AsyncValueObservation<[Message]> {
        let observation = ValueObservation.tracking { db -> [Message] in
            try Row.fetchAll(db, sql: """
                SELECT * FROM messages WHERE conversation_id = ?
                ORDER BY timestamp ASC LIMIT ?
            """, arguments: [conversationId, limit])
                .compactMap { Self.rowToMessage($0) }
        }
        return AsyncValueObservation(observation: observation, in: db)
    }

    /// Stream of all conversation IDs.
    public nonisolated func observeConversationIds() -> AsyncValueObservation<[String]> {
        let observation = ValueObservation.tracking { db -> [String] in
            try String.fetchAll(db, sql: "SELECT DISTINCT conversation_id FROM messages")
        }
        return AsyncValueObservation(observation: observation, in: db)
    }

    private static func createTables(_ db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    message_id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    is_sent INTEGER NOT NULL DEFAULT 0,
                    author_device_id TEXT,
                    stored_at INTEGER NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id, timestamp)
            """)
        }
    }

    public func add(_ conversationId: String, _ message: Message) async {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        try? await db.write { db in
            // Idempotent: skip if exists
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE message_id = ?",
                                          arguments: [message.messageId]) ?? 0
            guard exists == 0 else { return }

            try db.execute(sql: """
                INSERT INTO messages (message_id, conversation_id, timestamp, content, is_sent, author_device_id, stored_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [message.messageId, conversationId, message.timestamp, message.content,
                             message.isSent ? 1 : 0, message.authorDeviceId, now])
        }
    }

    public func getMessage(_ messageId: String) async -> Message? {
        try? await db.read { db -> Message? in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [messageId]) else { return nil }
            return Self.rowToMessage(row)
        }
    }

    public func getMessages(_ conversationId: String, limit: Int = 100, offset: Int = 0) async -> [Message] {
        (try? await db.read { db -> [Message] in
            try Row.fetchAll(db, sql: """
                SELECT * FROM messages WHERE conversation_id = ?
                ORDER BY timestamp ASC LIMIT ? OFFSET ?
            """, arguments: [conversationId, limit, offset])
                .compactMap { Self.rowToMessage($0) }
        }) ?? []
    }

    public func getConversationIds() async -> [String] {
        (try? await db.read { db -> [String] in
            try String.fetchAll(db, sql: "SELECT DISTINCT conversation_id FROM messages")
        }) ?? []
    }

    public func migrateMessages(from: String, to: String) async -> Int {
        guard from != to else { return 0 }
        return (try? await db.write { db -> Int in
            try db.execute(sql: "UPDATE messages SET conversation_id = ? WHERE conversation_id = ?",
                           arguments: [to, from])
            return db.changesCount
        }) ?? 0
    }

    public func deleteByAuthorDevice(_ deviceId: String) async -> Int {
        (try? await db.write { db -> Int in
            try db.execute(sql: "DELETE FROM messages WHERE author_device_id = ?", arguments: [deviceId])
            return db.changesCount
        }) ?? 0
    }

    public func clearConversation(_ conversationId: String) async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE conversation_id = ?", arguments: [conversationId])
        }
    }

    public func clearAll() async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM messages")
        }
    }

    private static func rowToMessage(_ row: Row) -> Message {
        Message(
            messageId: row["message_id"],
            conversationId: row["conversation_id"],
            timestamp: UInt64(row["timestamp"] as Int64),
            content: row["content"],
            isSent: (row["is_sent"] as Int64) != 0,
            authorDeviceId: row["author_device_id"]
        )
    }
}
