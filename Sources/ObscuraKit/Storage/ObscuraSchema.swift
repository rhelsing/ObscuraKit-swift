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
/// **`obscura-proto/PLAN.md` Phase 3 needed the part that never worked.** Adding the inbox table
/// worked by accident, because `IF NOT EXISTS` runs on every launch. Removing `associations` and
/// `ttl` — and dropping `model_entries.signature`, a `NOT NULL` column holding a keyless hash
/// nothing verifies — is what `v2` does, and is impossible without this file.
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

        // ─────────────────────────────────────────────────────────────────────────────────
        // ⚠️ The tripwire (`eraseDatabaseOnSchemaChange`) used to be ON here, and `v2` is why
        // it is now off.
        //
        // What it did: on every launch, migrate a temporary database up to the last-applied
        // identifier and compare schemas; if they differ, `db.erase()`. That makes "edit the
        // CREATE TABLE in `v1`" a working way to change the schema — GRDB notices and rebuilds
        // — which is genuinely convenient while a schema is still being designed, and which is
        // exactly the habit that must not survive contact with a database holding real state.
        //
        // Two things changed under it:
        //
        //   1. `inbox_rows` arrived. An ack is a DELETE (`obscura-proto/SPEC.md` §0.9): once the
        //      kit acks, the inbox row is the ONLY copy of that message anywhere. An erase is no
        //      longer "lose a dev database and re-provision" — it destroys messages that exist
        //      nowhere else, silently, at launch, with no failed operation to notice.
        //   2. This file acquired a real migration to write. The tripwire's whole justification
        //      was that migrations were not yet worth authoring; `v2` is the counter-example,
        //      and it preserves data precisely because it is a migration rather than a rebuild.
        //
        // The erase also destroyed the Signal identity (`signal_local_identity`,
        // `signal_identities`, `signal_sessions`, `signal_sender_keys`), forcing a re-provision
        // that mints a NEW server-side device row — and backups are keyed on device id, so the
        // previous backup became reachable only by re-claiming the old id (`KIT_API.md` §8.4).
        // That was always the cost; it was accepted while the only casualty was the dev's own
        // convenience.
        //
        // The failure mode this trades INTO: edit `v1` now and nothing happens at all — the
        // migration is already applied, so the edit is silently ignored and the code runs
        // against a schema it does not describe. That is the quieter failure, but it is also the
        // one a test can catch, and `SchemaTests` does: `expectedTables` is asserted against the
        // actual migrated schema.
        // ─────────────────────────────────────────────────────────────────────────────────
        migrator.eraseDatabaseOnSchemaChange = false

        // ⚠️ APPLIED. Do not edit — see the rule in the type doc. The ORM tables below are
        // deliberately still created here and then dropped by `v2`; that is what "v1 is history"
        // means. A fresh database creates three tables it immediately discards, which costs
        // microseconds once and buys the guarantee that every database, new or old, reaches the
        // same place by the same route.
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
            // The durable inbox (`obscura-proto/KIT_API.md` §3). Ported from the Kotlin shape
            // (ObscuraKit-Kotlin PR #49) rather than co-designed — §10 has Kotlin design first
            // precisely so the two kits stop diverging on behaviour.
            //
            // Note this lands in `v1` rather than a `v2`, which is the tripwire earning its keep:
            // with `eraseDatabaseOnSchemaChange` on, GRDB sees `sqlite_master` changed and rebuilds,
            // so adding a table is an edit here rather than a migration to author. When the tripwire
            // comes off, this becomes a real `registerMigration("v2")`.
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

            // ── ORM ──────────────────────────────────────────────────────────────────────
            // `associations` and `ttl` are dropped by `v2`, and `model_entries.signature` with
            // them. `model_entries` itself SURVIVES — it is the app's entry store
            // (`Stores/EntryStore.swift`), and `RESET.md` is explicit that the engine dies and
            // the table does not.
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

        // ── v2: the ORM comes out ────────────────────────────────────────────────────────
        //
        // `obscura-proto/RESET.md` §10 step 4, Swift half. The engine (`ORM/`) is deleted in the
        // same change; this is the storage it leaves behind.
        //
        // **`model_entries` is NOT dropped, and that distinction is the whole migration.** It is
        // the table `Stores/EntryStore.swift` reads and writes — the app's entries, the thing pix
        // is now the owner of. What goes is the machinery layered over it:
        //
        //   - `associations` — relationships, never bridged, zero rows in practice.
        //   - `ttl` — expiry, which `TTLManager` drove and which had to be called by hand anyway.
        //   - `model_entries.signature` — a keyless SHA-256 of
        //     `"\(name):\(id):\(timestamp):\(deviceId)"`. Unkeyed, so anyone can compute it; it
        //     does not cover `data`, so it cannot detect tampering with the entry; and nothing
        //     ever verified it. `SPEC §3.3` removed the same construct from the wire.
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
    /// Idempotent — `DatabaseMigrator` records what it has applied, so every store may call this
    /// from its own `init` without coordination. That is deliberate: it is what let this file
    /// replace six private `createTables` functions without touching the 73 in-memory store
    /// constructions in the test suite.
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
    /// **13 tables.** `v1` creates 15; `v2` drops `associations` and `ttl` with the ORM.
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
