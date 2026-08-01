import Foundation
import GRDB

/// The one place this kit's database schema is defined.
///
/// Every schema change must be an additive `DatabaseMigrator` step. Editing a `CREATE TABLE IF NOT
/// EXISTS` statement does not alter an existing table, and an applied migration never runs again.
///
/// ## The one rule
///
/// **`v1` is history. Never edit it. Add a migration.** Every applied migration is a statement
/// about a database that already exists on a device; editing one rewrites the past and the
/// databases do not follow.
public enum ObscuraSchema {

    /// The migrator that owns every table in `obscura.sqlite`.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Do not enable eraseDatabaseOnSchemaChange. The inbox may hold the only acknowledged copy
        // of a message, and this database also holds the Signal identity and sessions.
        // SchemaTests guard table and critical-column shape, but only a new migration reliably
        // updates existing devices.
        migrator.eraseDatabaseOnSchemaChange = false

        // APPLIED. Do not edit. A fresh database runs this migration and every later migration so
        // new and existing databases reach the same schema through the same steps.
        migrator.registerMigration("v1") { db in
            // `IF NOT EXISTS` is load-bearing exactly once: on a database created before this
            // file existed. Such a database has the tables but no `grdb_migrations` row, so
            // `v1` is unapplied and runs against tables that are already there. Without the
            // clause that is a crash on launch rather than a no-op. (The erase-on-schema-change
            // check does not save us — it only compares schemas when at least one migration has
            // already been applied, and here none has.) Keep it.

            // ── Friends ──────────────────────────────────────────────────────────────────
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

            // ── Messages ─────────────────────────────────────────────────────────────────
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
                CREATE INDEX IF NOT EXISTS idx_messages_conversation
                    ON messages(conversation_id, timestamp)
            """)

            // ── Devices ──────────────────────────────────────────────────────────────────
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

            // ── Signal protocol state ────────────────────────────────────────────────────
            // Owned by `PersistentSignalStore`. An erase destroys the device identity; see the
            // tripwire above.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS signal_local_identity (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    key_pair BLOB NOT NULL,
                    registration_id INTEGER NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS signal_identities (
                    address TEXT PRIMARY KEY,
                    key_data BLOB NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS signal_prekeys (
                    key_id INTEGER PRIMARY KEY,
                    record BLOB NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS signal_signed_prekeys (
                    key_id INTEGER PRIMARY KEY,
                    record BLOB NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS signal_sessions (
                    address TEXT PRIMARY KEY,
                    record BLOB NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS signal_sender_keys (
                    key_id TEXT PRIMARY KEY,
                    record BLOB NOT NULL
                )
            """)

            // ── Attachment cache ─────────────────────────────────────────────────────────
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS attachment_cache (
                    attachment_id TEXT NOT NULL PRIMARY KEY,
                    plaintext BLOB NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    cached_at INTEGER NOT NULL
                )
            """)

            // ── Inbox ────────────────────────────────────────────────────────────────────
            // The durable inbox (`obscura-proto/KIT_API.md` §3). Do not edit this applied v1
            // statement; change the table in a new migration.
            //
            // `AUTOINCREMENT` is not decoration: a plain `INTEGER PRIMARY KEY` aliases rowid, and
            // SQLite REUSES rowids after deletion — so a drained-then-refilled inbox would hand out
            // ids that go backwards, while `peek` orders by id.
            //
            // `envelope_id ... UNIQUE` plus `INSERT OR IGNORE` is the dedupe key (§3.3 rule 8).
            // Persist-then-ack GUARANTEES redelivery — the ack is best-effort and its failure is
            // swallowed — so without this the design would be strictly LESS idempotent than the ORM
            // it replaces, whose `INSERT OR REPLACE` absorbed duplicates by accident.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS inbox_rows (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    envelope_id TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    received_at INTEGER NOT NULL,
                    sender_user_id TEXT NOT NULL,
                    sender_device_id TEXT,
                    sender_display_name TEXT,
                    model_key TEXT,
                    entry_id TEXT,
                    op TEXT,
                    sent_at INTEGER,
                    payload BLOB NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_inbox_id ON inbox_rows(id)
            """)

            // v1 application tables. Migration v2 retains `model_entries`
            // storage and removes the unused policy tables and signature column.
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

        // v2 retains app entry storage and removes unused schema:
        //
        //   - `associations` — relationship policy does not belong in the kit.
        //   - `ttl` — expiry is application policy and is not implemented.
        //   - `model_entries.signature` — a keyless SHA-256 of
        //     `"\(name):\(id):\(timestamp):\(deviceId)"`. Unkeyed, so anyone can compute it; it
        //     does not cover `data`, so it cannot detect tampering with the entry; and nothing
        //     verifies it.
        //
        // The column goes by table rebuild rather than `ALTER TABLE ... DROP COLUMN`. DROP COLUMN
        // needs SQLite 3.35+, and the SQLite under this kit is whatever GRDB's SQLCipher fork
        // bundles — a version this file should not have an opinion about. The rebuild is the
        // portable form and is what SQLite's own documentation prescribes.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE model_entries_v2 (
                    model_name TEXT NOT NULL,
                    id TEXT NOT NULL,
                    data TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    author_device_id TEXT NOT NULL,
                    PRIMARY KEY (model_name, id)
                )
            """)
            // Column list spelled out, never `SELECT *` — the point of the statement is that one
            // column is absent, and `*` would carry it across the moment someone reorders `v1`.
            try db.execute(sql: """
                INSERT INTO model_entries_v2 (model_name, id, data, timestamp, author_device_id)
                SELECT model_name, id, data, timestamp, author_device_id FROM model_entries
            """)
            try db.execute(sql: "DROP TABLE model_entries")
            try db.execute(sql: "ALTER TABLE model_entries_v2 RENAME TO model_entries")

            try db.execute(sql: "DROP TABLE associations")
            try db.execute(sql: "DROP TABLE ttl")
        }

        return migrator
    }

    /// Bring `writer` up to the current schema.
    ///
    /// Idempotent: `DatabaseMigrator` records applied steps, so every store may call this from its
    /// own initializer without coordination.
    public static func migrate(_ writer: DatabaseQueue) throws {
        try migrator.migrate(writer)
    }

    /// Every table a fully-migrated database has — the schema at HEAD, not at any one migration.
    /// Asserted by `SchemaTests` so a store whose tables were never registered here fails loudly
    /// instead of at the first query against a missing table.
    ///
    /// This is the check that replaces the erase-on-schema-change tripwire: with the tripwire off,
    /// an edit to an already-applied migration is silently ignored at runtime, and this set is what
    /// turns that silence into a failing test.
    ///
    /// Keep this set synchronized with the fully migrated schema.
    ///
    /// Before this file existed, 19 tables were created by six private `createTables` functions:
    /// `v1`'s 15 minus `inbox_rows` (which did not exist yet), plus five belonging to
    /// `GRDBSignalStore` (`identity_key`, `trusted_identities`, `pre_keys`, `signed_pre_keys`,
    /// `sessions`) — a type nothing ever constructed, so those five were never created in
    /// production either. `PersistentSignalStore`'s `signal_*` tables are the live ones. (The
    /// count here read "14" for as long as `inbox_rows` has existed, which is what an un-asserted
    /// comment is worth.)
    public static let expectedTables: Set<String> = [
        "friends",
        "messages",
        "device_identity",
        "own_devices",
        "signal_local_identity",
        "signal_identities",
        "signal_prekeys",
        "signal_signed_prekeys",
        "signal_sessions",
        "signal_sender_keys",
        "attachment_cache",
        "inbox_rows",
        "model_entries",
    ]
}
