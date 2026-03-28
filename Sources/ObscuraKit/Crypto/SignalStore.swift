import Foundation
import GRDB

// MARK: - Signal Store Protocol (matches JS IndexedDBStore's 15-method interface)

/// Protocol matching the Signal Protocol store interface.
/// Mirrors src/v2/lib/store.js (InMemoryStore) and src/v2/lib/IndexedDBStore.js
public protocol SignalStoreProtocol {
    // Identity
    func getIdentityKeyPair() async -> SignalKeyPair?
    func storeIdentityKeyPair(_ keyPair: SignalKeyPair) async
    func getLocalRegistrationId() async -> UInt32?
    func storeLocalRegistrationId(_ id: UInt32) async

    // Trusted identities
    func isTrustedIdentity(_ address: String, _ identityKey: Data) async -> Bool
    func saveIdentity(_ address: String, _ publicKey: Data) async

    // Pre-keys
    func loadPreKey(_ keyId: UInt32) async -> SignalKeyPair?
    func storePreKey(_ keyId: UInt32, _ keyPair: SignalKeyPair) async
    func removePreKey(_ keyId: UInt32) async

    // Signed pre-keys
    func loadSignedPreKey(_ keyId: UInt32) async -> SignalSignedPreKey?
    func storeSignedPreKey(_ keyId: UInt32, _ signedPreKey: SignalSignedPreKey) async
    func removeSignedPreKey(_ keyId: UInt32) async

    // Sessions
    func loadSession(_ address: String) async -> Data?
    func storeSession(_ address: String, _ record: Data) async
    func removeSession(_ address: String) async
    func removeSessionsForUser(_ userId: String) async
}

// MARK: - Value Types

public struct SignalKeyPair: Codable, Equatable, Sendable {
    public let publicKey: Data   // 33 bytes (0x05 + 32)
    public let privateKey: Data  // 32 bytes

    public init(publicKey: Data, privateKey: Data) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

public struct SignalSignedPreKey: Codable, Equatable, Sendable {
    public let keyId: UInt32
    public let keyPair: SignalKeyPair
    public let signature: Data  // 64 bytes (XEdDSA)

    public init(keyId: UInt32, keyPair: SignalKeyPair, signature: Data) {
        self.keyId = keyId
        self.keyPair = keyPair
        self.signature = signature
    }
}

// MARK: - GRDB-backed Signal Store

/// Persistent Signal Protocol store backed by GRDB (SQLite).
/// Mirrors the IndexedDBStore from the web client.
public actor GRDBSignalStore: SignalStoreProtocol {
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
            // Identity key pair (singleton)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS identity_key (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    public_key BLOB NOT NULL,
                    private_key BLOB NOT NULL,
                    registration_id INTEGER NOT NULL DEFAULT 0
                )
            """)

            // Trusted identities (keyed by address)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS trusted_identities (
                    address TEXT PRIMARY KEY,
                    public_key BLOB NOT NULL
                )
            """)

            // Pre-keys
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pre_keys (
                    key_id INTEGER PRIMARY KEY,
                    public_key BLOB NOT NULL,
                    private_key BLOB NOT NULL
                )
            """)

            // Signed pre-keys
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS signed_pre_keys (
                    key_id INTEGER PRIMARY KEY,
                    public_key BLOB NOT NULL,
                    private_key BLOB NOT NULL,
                    signature BLOB NOT NULL
                )
            """)

            // Sessions (keyed by address = "userId.registrationId")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sessions (
                    address TEXT PRIMARY KEY,
                    record BLOB NOT NULL
                )
            """)
        }
    }

    // MARK: - Identity

    public func getIdentityKeyPair() async -> SignalKeyPair? {
        try? await db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT public_key, private_key FROM identity_key WHERE id = 1")
            guard let row = row else { return nil }
            return SignalKeyPair(
                publicKey: row["public_key"],
                privateKey: row["private_key"]
            )
        }
    }

    public func storeIdentityKeyPair(_ keyPair: SignalKeyPair) async {
        try? await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO identity_key (id, public_key, private_key, registration_id)
                VALUES (1, ?, ?, COALESCE((SELECT registration_id FROM identity_key WHERE id = 1), 0))
            """, arguments: [keyPair.publicKey, keyPair.privateKey])
        }
    }

    public func getLocalRegistrationId() async -> UInt32? {
        try? await db.read { db in
            try UInt32.fetchOne(db, sql: "SELECT registration_id FROM identity_key WHERE id = 1")
        }
    }

    public func storeLocalRegistrationId(_ id: UInt32) async {
        try? await db.write { db in
            // Upsert: if identity row exists, update regId; otherwise insert placeholder
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM identity_key WHERE id = 1") ?? 0
            if exists > 0 {
                try db.execute(sql: "UPDATE identity_key SET registration_id = ? WHERE id = 1", arguments: [id])
            } else {
                try db.execute(sql: "INSERT INTO identity_key (id, public_key, private_key, registration_id) VALUES (1, X'', X'', ?)", arguments: [id])
            }
        }
    }

    // MARK: - Trusted Identities

    public func isTrustedIdentity(_ address: String, _ identityKey: Data) async -> Bool {
        let stored = try? await db.read { db -> Data? in
            try Data.fetchOne(db, sql: "SELECT public_key FROM trusted_identities WHERE address = ?", arguments: [address])
        }
        guard let stored = stored else { return true } // Trust on first use
        return constantTimeEqual(stored, identityKey)
    }

    public func saveIdentity(_ address: String, _ publicKey: Data) async {
        try? await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO trusted_identities (address, public_key) VALUES (?, ?)",
                           arguments: [address, publicKey])
        }
    }

    // MARK: - Pre-keys

    public func loadPreKey(_ keyId: UInt32) async -> SignalKeyPair? {
        try? await db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT public_key, private_key FROM pre_keys WHERE key_id = ?", arguments: [keyId])
            guard let row = row else { return nil }
            return SignalKeyPair(publicKey: row["public_key"], privateKey: row["private_key"])
        }
    }

    public func storePreKey(_ keyId: UInt32, _ keyPair: SignalKeyPair) async {
        try? await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO pre_keys (key_id, public_key, private_key) VALUES (?, ?, ?)",
                           arguments: [keyId, keyPair.publicKey, keyPair.privateKey])
        }
    }

    public func removePreKey(_ keyId: UInt32) async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM pre_keys WHERE key_id = ?", arguments: [keyId])
        }
    }

    // MARK: - Signed Pre-keys

    public func loadSignedPreKey(_ keyId: UInt32) async -> SignalSignedPreKey? {
        try? await db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT public_key, private_key, signature FROM signed_pre_keys WHERE key_id = ?", arguments: [keyId])
            guard let row = row else { return nil }
            return SignalSignedPreKey(
                keyId: keyId,
                keyPair: SignalKeyPair(publicKey: row["public_key"], privateKey: row["private_key"]),
                signature: row["signature"]
            )
        }
    }

    public func storeSignedPreKey(_ keyId: UInt32, _ signedPreKey: SignalSignedPreKey) async {
        try? await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO signed_pre_keys (key_id, public_key, private_key, signature) VALUES (?, ?, ?, ?)",
                           arguments: [keyId, signedPreKey.keyPair.publicKey, signedPreKey.keyPair.privateKey, signedPreKey.signature])
        }
    }

    public func removeSignedPreKey(_ keyId: UInt32) async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM signed_pre_keys WHERE key_id = ?", arguments: [keyId])
        }
    }

    // MARK: - Sessions

    public func loadSession(_ address: String) async -> Data? {
        try? await db.read { db in
            try Data.fetchOne(db, sql: "SELECT record FROM sessions WHERE address = ?", arguments: [address])
        }
    }

    public func storeSession(_ address: String, _ record: Data) async {
        try? await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sessions (address, record) VALUES (?, ?)",
                           arguments: [address, record])
        }
    }

    public func removeSession(_ address: String) async {
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE address = ?", arguments: [address])
        }
    }

    public func removeSessionsForUser(_ userId: String) async {
        try? await db.write { db in
            // Sessions keyed as "userId.registrationId" — remove all starting with "userId."
            try db.execute(sql: "DELETE FROM sessions WHERE address LIKE ?", arguments: ["\(userId).%"])
        }
    }
}
