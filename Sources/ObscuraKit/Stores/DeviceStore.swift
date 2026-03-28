import Foundation
import GRDB

public struct DeviceIdentity: Codable, Sendable, Equatable {
    public var coreUsername: String
    public var deviceId: String
    public var deviceUUID: String
    public var p2pPublicKey: Data?
    public var p2pPrivateKey: Data?
    public var recoveryPublicKey: Data?
    public var linkPending: Bool

    public init(coreUsername: String, deviceId: String, deviceUUID: String, linkPending: Bool = false) {
        self.coreUsername = coreUsername
        self.deviceId = deviceId
        self.deviceUUID = deviceUUID
        self.linkPending = linkPending
    }
}

public struct OwnDevice: Codable, Sendable, Equatable {
    public var deviceUUID: String
    public var deviceId: String
    public var deviceName: String
    public var signalIdentityKey: Data?
    public var registrationId: UInt32?

    public init(deviceUUID: String, deviceId: String, deviceName: String) {
        self.deviceUUID = deviceUUID
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

public actor DeviceActor {
    private let db: DatabaseQueue

    public nonisolated var dbQueue: DatabaseQueue { db }

    public init(db: DatabaseQueue) throws {
        self.db = db
        try Self.createTables(db)
    }

    public init() throws {
        self.db = try DatabaseQueue()
        try Self.createTables(db)
    }

    // MARK: - Reactive Streams

    /// Stream of own devices. Emits on every change.
    public nonisolated func observeOwnDevices() -> AsyncValueObservation<[OwnDevice]> {
        let observation = ValueObservation.tracking { db -> [OwnDevice] in
            try Row.fetchAll(db, sql: "SELECT * FROM own_devices").map { row in
                var d = OwnDevice(deviceUUID: row["device_uuid"], deviceId: row["device_id"], deviceName: row["device_name"])
                d.signalIdentityKey = row["signal_identity_key"]
                d.registrationId = (row["registration_id"] as Int64?).map { UInt32($0) }
                return d
            }
        }
        return AsyncValueObservation(observation: observation, in: db)
    }

    /// Stream of identity state (exists or not).
    public nonisolated func observeHasIdentity() -> AsyncValueObservation<Bool> {
        let observation = ValueObservation.tracking { db -> Bool in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM device_identity WHERE id = 1") ?? 0
            return count > 0
        }
        return AsyncValueObservation(observation: observation, in: db)
    }

    private static func createTables(_ db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS device_identity (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    core_username TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    device_uuid TEXT NOT NULL,
                    p2p_public_key BLOB,
                    p2p_private_key BLOB,
                    recovery_public_key BLOB,
                    link_pending INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS own_devices (
                    device_uuid TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    device_name TEXT NOT NULL,
                    signal_identity_key BLOB,
                    registration_id INTEGER
                )
            """)
        }
    }

    public func storeIdentity(_ identity: DeviceIdentity) async {
        try? await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO device_identity (id, core_username, device_id, device_uuid, p2p_public_key, p2p_private_key, recovery_public_key, link_pending)
                VALUES (1, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [identity.coreUsername, identity.deviceId, identity.deviceUUID,
                             identity.p2pPublicKey, identity.p2pPrivateKey, identity.recoveryPublicKey,
                             identity.linkPending ? 1 : 0])
        }
    }

    public func getIdentity() async -> DeviceIdentity? {
        try? await db.read { db -> DeviceIdentity? in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM device_identity WHERE id = 1") else { return nil }
            var identity = DeviceIdentity(
                coreUsername: row["core_username"],
                deviceId: row["device_id"],
                deviceUUID: row["device_uuid"],
                linkPending: (row["link_pending"] as Int64) != 0
            )
            identity.p2pPublicKey = row["p2p_public_key"]
            identity.p2pPrivateKey = row["p2p_private_key"]
            identity.recoveryPublicKey = row["recovery_public_key"]
            return identity
        }
    }

    public func hasIdentity() async -> Bool {
        await getIdentity() != nil
    }

    public func deleteIdentity() async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM device_identity WHERE id = 1")
        }
    }

    public func addOwnDevice(_ device: OwnDevice) async {
        try? await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO own_devices (device_uuid, device_id, device_name, signal_identity_key, registration_id)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [device.deviceUUID, device.deviceId, device.deviceName,
                             device.signalIdentityKey, device.registrationId])
        }
    }

    public func getOwnDevices() async -> [OwnDevice] {
        (try? await db.read { db -> [OwnDevice] in
            try Row.fetchAll(db, sql: "SELECT * FROM own_devices").map { row in
                var d = OwnDevice(deviceUUID: row["device_uuid"], deviceId: row["device_id"], deviceName: row["device_name"])
                d.signalIdentityKey = row["signal_identity_key"]
                d.registrationId = (row["registration_id"] as Int64?).map { UInt32($0) }
                return d
            }
        }) ?? []
    }

    public func getOwnDevice(_ deviceUUID: String) async -> OwnDevice? {
        try? await db.read { db -> OwnDevice? in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM own_devices WHERE device_uuid = ?", arguments: [deviceUUID]) else { return nil }
            var d = OwnDevice(deviceUUID: row["device_uuid"], deviceId: row["device_id"], deviceName: row["device_name"])
            d.signalIdentityKey = row["signal_identity_key"]
            d.registrationId = (row["registration_id"] as Int64?).map { UInt32($0) }
            return d
        }
    }

    public func removeOwnDevice(_ deviceUUID: String) async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM own_devices WHERE device_uuid = ?", arguments: [deviceUUID])
        }
    }

    public func getSelfSyncTargets() async -> [OwnDevice] {
        await getOwnDevices()
    }

    public func clearAll() async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM device_identity")
            try db.execute(sql: "DELETE FROM own_devices")
        }
    }
}
