import Foundation
import GRDB

/// The one place this kit's database schema is defined.
///
/// Before this existed there was no migration mechanism at all — no `ALTER TABLE`, no
/// `PRAGMA user_version`, no `grdb_migrations`, no table or column probing. Nineteen
/// `CREATE TABLE IF NOT EXISTS` statements lived in six private `createTables` functions,
/// each fired from its own store's `init`, in whatever order `ObscuraClient` happened to
/// construct them.
///
/// That arrangement can only ever *add whole tables*, and it fails silently at everything else:
///
/// ```
/// -- ship a new column by editing the CREATE TABLE IF NOT EXISTS:
/// sqlite> CREATE TABLE IF NOT EXISTS friends (user_id TEXT PRIMARY KEY, username TEXT NOT NULL,
///                                             blocked INTEGER NOT NULL DEFAULT 0);
/// exit=0                              -- no error, no warning, no change
/// sqlite> SELECT user_id, blocked FROM friends;
/// Error: in prepare, no such column: blocked
/// ```
///
/// Silent when the schema changes, throwing later at query time, with no way to repair. This is
/// the Swift half of `obscura-proto/KIT_API.md` P1; the Kotlin half is SQLDelight `.sqm` files.
///
/// **`obscura-proto/PLAN.md` Phase 3 needs the part that does not work today.** Adding the inbox
/// table would have worked by accident, because `IF NOT EXISTS` runs on every launch. *Removing*
/// `model_entries`, `associations` and `ttl` — and dropping `model_entries.signature`, a
/// `NOT NULL` column holding a keyless hash nothing verifies — is impossible without this file.
public enum ObscuraSchema {

    /// The migrator that owns every table in `obscura.sqlite`.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // ─────────────────────────────────────────────────────────────────────────────────
        // ⚠️ TRIPWIRE — this flag destroys the database whenever the schema changes.
        //
        // It is on deliberately. The app has exactly one user (its author), who has said
        // breakage is an acceptable price for changing the schema freely right now. GRDB
        // documents this flag for precisely that: "useful during application development: you
        // are still designing migrations, and the schema changes often."
        //
        // What it costs when it fires: `obscura.sqlite` holds the Signal identity
        // (`signal_local_identity`, `signal_identities`, `signal_sessions`,
        // `signal_sender_keys`), so an erase is not merely a lost dev database — the device
        // loses its identity and must re-provision, which mints a NEW server-side device row.
        // Backups are keyed on device id, so the previous backup is then reachable only by
        // re-claiming the old id (`obscura-proto/KIT_API.md` §8.4).
        //
        // TURN THIS OFF THE MOMENT A SECOND PERSON INSTALLS THE APP. The replacement is
        // `#if DEBUG` around this line, which is what GRDB recommends for shipped apps — it is
        // NOT used here on purpose, because it would give erase-on-change in dev builds and
        // silent stale-schema breakage in release builds, two different failure modes on the
        // one device that currently matters.
        //
        // Once it is off, a schema change must be expressed as a NEW `registerMigration`
        // below. Editing `v1` in place will stop working, and will stop working quietly.
        // ─────────────────────────────────────────────────────────────────────────────────
        migrator.eraseDatabaseOnSchemaChange = true

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

            // ── ORM ──────────────────────────────────────────────────────────────────────
            // DELETED BY PHASE 3 (`obscura-proto/RESET.md`). When that lands, remove these
            // three statements from `v1` — with the tripwire on, GRDB notices `sqlite_master`
            // changed and rebuilds, so no `DROP TABLE` migration needs writing. `signature` is
            // the dead keyless hash from `Model.swift`'s `sign(id:data:timestamp:)`; it goes
            // with them.
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

        return migrator
    }

    /// Bring `writer` up to the current schema.
    ///
    /// Idempotent — `DatabaseMigrator` records what it has applied, so every store may call this
    /// from its own `init` without coordination. That is deliberate: it is what let this file
    /// replace six private `createTables` functions without touching the 73 in-memory store
    /// constructions in the test suite.
    public static func migrate(_ writer: DatabaseQueue) throws {
        try migrator.migrate(writer)
    }

    /// Every table `v1` defines. Asserted by `SchemaTests` so a store whose tables were never
    /// registered here fails loudly instead of at the first query against a missing table.
    ///
    /// Note this is **14 tables, not the 19** that used to be created. The other five
    /// (`identity_key`, `trusted_identities`, `pre_keys`, `signed_pre_keys`, `sessions`) belonged
    /// to `GRDBSignalStore`, which had zero references outside its own file and was deleted with
    /// this change — nothing ever constructed it, so those tables were never created in
    /// production either. `PersistentSignalStore`'s `signal_*` tables are the live ones.
    public static let v1Tables: Set<String> = [
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
        "model_entries",
        "associations",
        "ttl",
    ]
}
