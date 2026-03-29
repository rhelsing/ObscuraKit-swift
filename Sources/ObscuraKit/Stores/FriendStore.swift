import Foundation
import GRDB

public enum FriendStatus: String, Codable, Sendable {
    case pendingSent = "pending_sent"
    case pendingReceived = "pending_received"
    case accepted = "accepted"
}

public struct Friend: Codable, Sendable, Equatable {
    public var userId: String
    public var username: String
    public var status: FriendStatus
    public var devices: [[String: String]]
    public var recoveryPublicKey: Data?
    public var devicesUpdatedAt: UInt64
    public var isVerified: Bool
    public var verifiedAt: UInt64?
    public var createdAt: UInt64
    public var updatedAt: UInt64

    public init(userId: String, username: String, status: FriendStatus, devices: [[String: String]] = [], recoveryPublicKey: Data? = nil) {
        self.userId = userId
        self.username = username
        self.status = status
        self.devices = devices
        self.recoveryPublicKey = recoveryPublicKey
        self.devicesUpdatedAt = 0
        self.isVerified = false
        self.verifiedAt = nil
        self.createdAt = UInt64(Date().timeIntervalSince1970 * 1000)
        self.updatedAt = self.createdAt
    }
}

public actor FriendActor {
    private let db: DatabaseQueue

    /// Exposed for GRDB ValueObservation (read-only observation from any isolation)
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

    // MARK: - Reactive Streams (GRDB ValueObservation)

    /// Stream of accepted friends. Emits on every change to the friends table.
    /// Subscribe once in SwiftUI — re-renders automatically.
    public nonisolated func observeAccepted() -> AsyncValueObservation<[Friend]> {
        let observation = ValueObservation.tracking { db -> [Friend] in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM friends WHERE status = ?",
                                        arguments: [FriendStatus.accepted.rawValue])
            return rows.compactMap { Self.rowToFriend($0) }
        }
        return AsyncValueObservation(observation: observation, in: db)
    }

    /// Stream of pending friend requests received (incoming).
    public nonisolated func observePending() -> AsyncValueObservation<[Friend]> {
        let observation = ValueObservation.tracking { db -> [Friend] in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM friends WHERE status = ?",
                                        arguments: [FriendStatus.pendingReceived.rawValue])
            return rows.compactMap { Self.rowToFriend($0) }
        }
        return AsyncValueObservation(observation: observation, in: db)
    }

    /// Stream of pending friend requests sent (outgoing).
    public nonisolated func observePendingSent() -> AsyncValueObservation<[Friend]> {
        let observation = ValueObservation.tracking { db -> [Friend] in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM friends WHERE status = ?",
                                        arguments: [FriendStatus.pendingSent.rawValue])
            return rows.compactMap { Self.rowToFriend($0) }
        }
        return AsyncValueObservation(observation: observation, in: db)
    }

    /// Stream of all friends.
    public nonisolated func observeAll() -> AsyncValueObservation<[Friend]> {
        let observation = ValueObservation.tracking { db -> [Friend] in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM friends")
            return rows.compactMap { Self.rowToFriend($0) }
        }
        return AsyncValueObservation(observation: observation, in: db)
    }

    private static func createTables(_ db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS friends (
                    user_id TEXT PRIMARY KEY,
                    username TEXT NOT NULL,
                    status TEXT NOT NULL,
                    devices TEXT NOT NULL DEFAULT '[]',
                    recovery_public_key BLOB,
                    devices_updated_at INTEGER NOT NULL DEFAULT 0,
                    is_verified INTEGER NOT NULL DEFAULT 0,
                    verified_at INTEGER,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
            """)
        }
    }

    public func add(_ userId: String, _ username: String, status: FriendStatus, devices: [[String: String]] = []) async {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let devicesJson = (try? JSONSerialization.data(withJSONObject: devices)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try? await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO friends (user_id, username, status, devices, devices_updated_at, is_verified, created_at, updated_at)
                VALUES (?, ?, ?, ?, 0, 0, ?, ?)
            """, arguments: [userId, username, status.rawValue, devicesJson, now, now])
        }
    }

    public func getFriend(_ userId: String) async -> Friend? {
        try? await db.read { db -> Friend? in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM friends WHERE user_id = ?", arguments: [userId]) else { return nil }
            return Self.rowToFriend(row)
        }
    }

    public func getAccepted() async -> [Friend] {
        (try? await db.read { db -> [Friend] in
            try Row.fetchAll(db, sql: "SELECT * FROM friends WHERE status = ?", arguments: [FriendStatus.accepted.rawValue])
                .compactMap { Self.rowToFriend($0) }
        }) ?? []
    }

    public func getPending() async -> [Friend] {
        (try? await db.read { db -> [Friend] in
            try Row.fetchAll(db, sql: "SELECT * FROM friends WHERE status = ?", arguments: [FriendStatus.pendingReceived.rawValue])
                .compactMap { Self.rowToFriend($0) }
        }) ?? []
    }

    public func updateStatus(_ userId: String, _ newStatus: FriendStatus) async {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        try? await db.write { db in
            try db.execute(sql: "UPDATE friends SET status = ?, updated_at = ? WHERE user_id = ?",
                           arguments: [newStatus.rawValue, now, userId])
        }
    }

    public func updateDevices(_ userId: String, devices: [[String: String]], timestamp: UInt64? = nil) async {
        let ts = timestamp ?? UInt64(Date().timeIntervalSince1970 * 1000)
        let devicesJson = (try? JSONSerialization.data(withJSONObject: devices)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try? await db.write { db in
            // LWW: only update if newer
            try db.execute(sql: """
                UPDATE friends SET devices = ?, devices_updated_at = ?, updated_at = ?
                WHERE user_id = ? AND devices_updated_at < ?
            """, arguments: [devicesJson, ts, ts, userId, ts])
        }
    }

    public func remove(_ userId: String) async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM friends WHERE user_id = ?", arguments: [userId])
        }
    }

    public func clearAll() async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM friends")
        }
    }

    public func getAll() async -> [Friend] {
        (try? await db.read { db -> [Friend] in
            try Row.fetchAll(db, sql: "SELECT * FROM friends").compactMap { Self.rowToFriend($0) }
        }) ?? []
    }

    public func isFriend(_ userId: String) async -> Bool {
        let friend = await getFriend(userId)
        return friend?.status == .accepted
    }

    private static func rowToFriend(_ row: Row) -> Friend? {
        let devicesJson: String = row["devices"]
        let devices: [[String: String]] = {
            guard let data = devicesJson.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
            else { return [] }
            return parsed
        }()

        var friend = Friend(
            userId: row["user_id"],
            username: row["username"],
            status: FriendStatus(rawValue: row["status"]) ?? .pendingSent,
            devices: devices,
            recoveryPublicKey: row["recovery_public_key"]
        )
        friend.devicesUpdatedAt = UInt64(row["devices_updated_at"] as Int64)
        friend.isVerified = (row["is_verified"] as Int64) != 0
        friend.verifiedAt = (row["verified_at"] as Int64?).map { UInt64($0) }
        friend.createdAt = UInt64(row["created_at"] as Int64)
        friend.updatedAt = UInt64(row["updated_at"] as Int64)
        return friend
    }
}
