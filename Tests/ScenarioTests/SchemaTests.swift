import XCTest
import GRDB
@testable import ObscuraKit

/// The schema of record.
///
/// Before `ObscuraSchema` there was no migration mechanism in this kit at all, and nineteen
/// `CREATE TABLE IF NOT EXISTS` statements lived in six private `createTables` functions. The
/// failure that produced — editing a `CREATE TABLE IF NOT EXISTS` and having SQLite silently
/// ignore it on an existing database — is not something a test can catch after the fact, because
/// by then the column is simply absent. So these tests guard the thing that *is* checkable: that
/// every store's tables are registered in the one place, and that migrating gets you there.
///
/// **Data survival IS tested now, and that is new.** While `eraseDatabaseOnSchemaChange` was on, a
/// schema change wiped the database by design, so a test asserting data survival would have asserted
/// the opposite of the policy. `v2` turned the tripwire off and became the first migration that has
/// to carry data across, so `testV2PreservesEntryDataWhileDroppingTheDeadColumn` is exactly the
/// fixture that used to be forbidden.
///
/// With the tripwire off, editing an already-applied migration is **silently ignored at runtime** —
/// the migration has already run, so the edit reaches no existing database. Nothing can detect that
/// at runtime; the only defence is a test that notices the *source* changed. Two do, and it is worth
/// being precise about which failure each one catches, because an overstated safety net is worse
/// than an acknowledged gap:
///
/// - `expectedTables` catches a table **added to or removed from** a migration.
/// - `frozenColumns` catches a column **added to, removed from, or retyped in** one. That is the
///   case `expectedTables` cannot see, and it is exactly what `signature` was.
///
/// Neither catches a changed index, trigger, or default. If you edit an applied migration and both
/// still pass, you have changed something no test here describes — which is the moment to add a
/// migration instead.
final class SchemaTests: XCTestCase {

    private func tableNames(in db: DatabaseQueue) throws -> Set<String> {
        try db.read { db in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                 WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """)
            // GRDB's own bookkeeping table is not part of our schema.
            return Set(names).subtracting(["grdb_migrations"])
        }
    }

    /// `name:type` for every column of `table`, in declared order.
    private func columns(of table: String, in db: DatabaseQueue) throws -> [String] {
        try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                .map { "\($0["name"] as String):\($0["type"] as String)" }
        }
    }

    /// The column shape of the two tables whose loss or corruption is unrecoverable.
    ///
    /// Not all thirteen: a frozen copy of every table would be a second schema to maintain, and the
    /// double-entry that creates is the thing `expectedTables`' own doc warns about. These two earn
    /// it — `inbox_rows` because after an ack its row is the only copy of a message anywhere
    /// (`obscura-proto/SPEC.md` §0.9), and `model_entries` because it is the app's entire entry
    /// store and is the table `v2` rebuilds.
    private static let frozenColumns: [String: [String]] = [
        "model_entries": [
            "model_name:TEXT", "id:TEXT", "data:TEXT", "timestamp:INTEGER", "author_device_id:TEXT",
        ],
        "inbox_rows": [
            "id:INTEGER", "envelope_id:TEXT", "kind:TEXT", "received_at:INTEGER",
            "sender_user_id:TEXT", "sender_device_id:TEXT", "sender_display_name:TEXT",
            "model_key:TEXT", "entry_id:TEXT", "op:TEXT", "sent_at:INTEGER", "payload:BLOB",
        ],
    ]

    /// The gap `expectedTables` leaves: a column edited inside an already-applied migration.
    ///
    /// `signature` is the worked example. It was a `NOT NULL` column in `v1`; removing it by editing
    /// `v1` would have changed nothing on any existing database and been invisible to a
    /// table-name check. It took a `v2`, and this test is what would have said so.
    func testTheColumnsOfTheIrreplaceableTablesAreFrozen() throws {
        let db = try DatabaseQueue()
        try ObscuraSchema.migrate(db)

        for (table, expected) in Self.frozenColumns {
            XCTAssertEqual(try columns(of: table, in: db), expected,
                           "\(table)'s columns changed. If deliberate, add a migration and update "
                           + "this expectation — never edit an applied one.")
        }
    }

    /// A migrated database has exactly the tables `expectedTables` claims — no more, no fewer.
    ///
    /// The "no fewer" half catches a store whose tables were never registered here; the "no more"
    /// half catches `expectedTables` drifting out of date with the migration, which is the double-entry
    /// mistake that makes a schema-of-record worse than none.
    func testMigratedDatabaseHasExactlyTheDeclaredTables() throws {
        let db = try DatabaseQueue()
        try ObscuraSchema.migrate(db)

        XCTAssertEqual(try tableNames(in: db), ObscuraSchema.expectedTables)
    }

    /// Migrating is idempotent, because every store calls it from its own `init` with no
    /// coordination between them. That property is what let one file replace six `createTables`
    /// functions without touching the in-memory store constructions across the test suite.
    func testMigrateIsIdempotentAcrossRepeatedCalls() throws {
        let db = try DatabaseQueue()
        try ObscuraSchema.migrate(db)
        let afterFirst = try tableNames(in: db)

        for _ in 0..<5 { try ObscuraSchema.migrate(db) }

        XCTAssertEqual(try tableNames(in: db), afterFirst)
        XCTAssertEqual(try db.read { try ObscuraSchema.migrator.appliedMigrations($0) }, ["v1", "v2"])
    }

    /// Constructing any single store brings the whole schema up, so no store can be left querying
    /// a table another store was supposed to have created.
    func testConstructingOneStoreMigratesTheWholeSchema() throws {
        let db = try DatabaseQueue()
        _ = try FriendActor(db: db)

        XCTAssertEqual(try tableNames(in: db), ObscuraSchema.expectedTables)
    }

    /// A database created before `ObscuraSchema` existed has the tables but no `grdb_migrations`
    /// row, so `v1` is unapplied and runs against tables that are already present. Without
    /// `IF NOT EXISTS` in the migration that is a crash on launch rather than a no-op. (The
    /// erase-on-schema-change tripwire never saved this case either, back when it was on: it only
    /// compared schemas once at least one migration had been applied, and here none has.)
    ///
    /// The fixture includes `model_entries` **with `signature NOT NULL` and a row in it**, copied
    /// from the pre-migrator `ModelStore.createTables`. Without that, `v1` creates the table itself
    /// and `v2` rebuilds something `v1` just made — which exercises none of the risk. The real case
    /// is `v2`'s `INSERT … SELECT` running against a table this file never created, and that is
    /// what could have named a column the old world did not have.
    func testAdoptsALegacyDatabaseThatPredatesTheMigrator() throws {
        let db = try DatabaseQueue()

        // Stand in for the old world: tables created directly, no migration bookkeeping.
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
                INSERT INTO model_entries VALUES ('story', 'legacy', '{"content":"pre-migrator"}', 3, X'AB', 'device-old')
            """)
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
        XCTAssertTrue(try db.read { try ObscuraSchema.migrator.appliedMigrations($0) }.isEmpty)

        XCTAssertNoThrow(try ObscuraSchema.migrate(db), "v1 must be a no-op over pre-existing tables")
        XCTAssertEqual(try tableNames(in: db), ObscuraSchema.expectedTables)

        // v2 rebuilt a table it did not create. The row has to come through, and the column the old
        // world required has to be gone.
        let row = try XCTUnwrap(try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM model_entries WHERE id = 'legacy'")
        }, "a row from before the migrator existed must survive v2")
        XCTAssertEqual(row["data"] as String, "{\"content\":\"pre-migrator\"}")
        XCTAssertEqual(row["author_device_id"] as String, "device-old")
        XCTAssertFalse(row.hasColumn("signature"))
    }

    /// `GRDBSignalStore` was deleted with this change — zero references outside its own file, and
    /// nothing ever constructed it, so its five tables were never created in production either.
    /// `PersistentSignalStore`'s `signal_*` tables are the live Signal protocol state.
    func testTheDeadSignalStoreTablesAreNotResurrected() throws {
        let db = try DatabaseQueue()
        try ObscuraSchema.migrate(db)
        let tables = try tableNames(in: db)

        for dead in ["identity_key", "trusted_identities", "pre_keys", "signed_pre_keys", "sessions"] {
            XCTAssertFalse(tables.contains(dead), "\(dead) belonged to the deleted GRDBSignalStore")
        }
        for live in ["signal_local_identity", "signal_sessions", "signal_identities"] {
            XCTAssertTrue(tables.contains(live), "\(live) is live Signal protocol state")
        }
    }

    // MARK: - v2 — the ORM comes out

    /// `v2` drops the tables the deleted engine owned, and keeps the one the app owns.
    ///
    /// The second half is the assertion that matters. `model_entries` is `EntryStore`'s table —
    /// `RESET.md` is explicit that the engine dies and the table does not — and it sits in the same
    /// `v1` as `associations` and `ttl`, which is exactly why "drop the ORM tables" could not be
    /// done by editing `v1` and letting the tripwire rebuild.
    func testV2DropsTheEngineTablesAndKeepsTheAppsOne() throws {
        let db = try DatabaseQueue()
        try ObscuraSchema.migrate(db)
        let tables = try tableNames(in: db)

        XCTAssertFalse(tables.contains("associations"), "relationships died with the engine")
        XCTAssertFalse(tables.contains("ttl"), "expiry died with TTLManager")
        XCTAssertTrue(tables.contains("model_entries"), "the app's entry store must survive")
        XCTAssertTrue(tables.contains("inbox_rows"), "the inbox shares this database and must survive")
    }

    /// Rows written under `v1` survive `v2`, and the dead `signature` column does not.
    ///
    /// This is the test the old policy could not have: it runs `v1` alone, writes a row the way the
    /// pre-deletion kit did — including a `signature` value, since the column was `NOT NULL` — then
    /// runs `v2` and reads the row back. Had `v2` been expressed as an edit to `v1` under the
    /// tripwire, the fixture row would be gone and so would every undrained `inbox_rows` entry
    /// beside it.
    func testV2PreservesEntryDataWhileDroppingTheDeadColumn() throws {
        let db = try DatabaseQueue()

        try ObscuraSchema.migrator.migrate(db, upTo: "v1")
        XCTAssertEqual(try db.read { try ObscuraSchema.migrator.appliedMigrations($0) }, ["v1"])

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO model_entries (model_name, id, data, timestamp, signature, author_device_id)
                VALUES ('story', 'e1', '{"content":"survives"}', 1234, X'DEADBEEF', 'device-a')
            """)
        }

        try ObscuraSchema.migrate(db)
        XCTAssertEqual(try db.read { try ObscuraSchema.migrator.appliedMigrations($0) }, ["v1", "v2"])

        let row = try XCTUnwrap(try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM model_entries WHERE model_name = 'story' AND id = 'e1'")
        }, "the entry written under v1 must still be there")

        XCTAssertEqual(row["data"], "{\"content\":\"survives\"}")
        XCTAssertEqual(row["timestamp"] as Int64, 1234)
        XCTAssertEqual(row["author_device_id"], "device-a")
        XCTAssertFalse(row.hasColumn("signature"),
                       "the keyless hash column nothing verified must be gone")
    }

    /// `v2` preserves data in a database **on disk**, opened by a second connection.
    ///
    /// Every other test in this file — and in `EntryStoreTests` and `InboxStoreTests` — uses an
    /// in-memory `DatabaseQueue()`, which vanishes with its connection. That is fine for logic and
    /// useless for the one property this migration exists to have: rows written by an older build
    /// of the app must still be there after the upgrade. An in-memory test cannot fail the way a
    /// real upgrade fails.
    ///
    /// So: write under `v1` to a file, close it, reopen it as a new connection the way a relaunched
    /// app would, migrate, and read back.
    func testV2PreservesDataInAFileBackedDatabaseAcrossAReopen() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("obscura-schema-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let old = try DatabaseQueue(path: path)
            try ObscuraSchema.migrator.migrate(old, upTo: "v1")
            try old.write { db in
                try db.execute(sql: """
                    INSERT INTO model_entries (model_name, id, data, timestamp, signature, author_device_id)
                    VALUES ('story', 'on-disk', '{"content":"survives a relaunch"}', 7, X'00', 'device-a')
                """)
                // An undrained inbox row. This is the one whose loss is unrecoverable — after an ack
                // it is the only copy of that message anywhere — and it shares the database with the
                // tables `v2` drops, which is the entire reason `v2` is a migration and not an erase.
                try db.execute(sql: """
                    INSERT INTO inbox_rows (envelope_id, kind, received_at, sender_user_id, payload)
                    VALUES ('env-on-disk', 'MODEL_SYNC', 7, 'user-b', X'0102')
                """)
            }
        }

        // A new connection over the same file — a relaunched app, not a retained handle.
        let reopened = try DatabaseQueue(path: path)
        try ObscuraSchema.migrate(reopened)

        let entry = try XCTUnwrap(try reopened.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM model_entries WHERE id = 'on-disk'")
        }, "an entry written under v1 must survive v2 on disk")
        XCTAssertEqual(entry["data"] as String, "{\"content\":\"survives a relaunch\"}")
        XCTAssertFalse(entry.hasColumn("signature"))

        let inbox = try XCTUnwrap(try reopened.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM inbox_rows WHERE envelope_id = 'env-on-disk'")
        }, "an undrained inbox row must survive v2 — it is the only copy of that message")
        XCTAssertEqual(inbox["payload"] as Data, Data([0x01, 0x02]))
    }

    /// The primary key survives the table rebuild.
    ///
    /// A rebuild that copies rows but loses `PRIMARY KEY (model_name, id)` would leave
    /// `EntryStore.put`'s `INSERT OR REPLACE` with nothing to conflict on — every write would append
    /// a duplicate row instead of replacing, and `all()` would return a growing history. That failure
    /// is invisible to a schema-name check and to a single-row read, so it gets its own assertion.
    func testV2KeepsThePrimaryKeySoUpsertStillReplaces() throws {
        let db = try DatabaseQueue()
        try ObscuraSchema.migrate(db)

        try db.write { db in
            for value in ["first", "second"] {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO model_entries (model_name, id, data, timestamp, author_device_id)
                    VALUES ('story', 'e1', ?, 1, 'device-a')
                """, arguments: [value])
            }
        }

        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT data FROM model_entries WHERE model_name = 'story' AND id = 'e1'")
        }
        XCTAssertEqual(rows.count, 1, "(model_name, id) must still be the primary key")
        XCTAssertEqual(rows.first?["data"], "second")
    }
}
