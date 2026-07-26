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
/// Deliberately **not** tested: that data survives a migration. `eraseDatabaseOnSchemaChange` is
/// on, so it does not, by design and by decision — see the tripwire in `ObscuraSchema`. A frozen
/// fixture asserting data survival would be asserting the opposite of the current policy.
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

    /// A migrated database has exactly the tables `v1Tables` claims — no more, no fewer.
    ///
    /// The "no fewer" half catches a store whose tables were never registered here; the "no more"
    /// half catches `v1Tables` drifting out of date with the migration, which is the double-entry
    /// mistake that makes a schema-of-record worse than none.
    func testMigratedDatabaseHasExactlyTheDeclaredTables() throws {
        let db = try DatabaseQueue()
        try ObscuraSchema.migrate(db)

        XCTAssertEqual(try tableNames(in: db), ObscuraSchema.v1Tables)
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
        XCTAssertEqual(try db.read { try ObscuraSchema.migrator.appliedMigrations($0) }, ["v1"])
    }

    /// Constructing any single store brings the whole schema up, so no store can be left querying
    /// a table another store was supposed to have created.
    func testConstructingOneStoreMigratesTheWholeSchema() throws {
        let db = try DatabaseQueue()
        _ = try FriendActor(db: db)

        XCTAssertEqual(try tableNames(in: db), ObscuraSchema.v1Tables)
    }

    /// A database created before `ObscuraSchema` existed has the tables but no `grdb_migrations`
    /// row, so `v1` is unapplied and runs against tables that are already present. Without
    /// `IF NOT EXISTS` in the migration that is a crash on launch rather than a no-op — and the
    /// erase-on-schema-change check does not save it, because that only compares schemas once at
    /// least one migration has been applied.
    func testAdoptsALegacyDatabaseThatPredatesTheMigrator() throws {
        let db = try DatabaseQueue()

        // Stand in for the old world: a table created directly, no migration bookkeeping.
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
        XCTAssertTrue(try db.read { try ObscuraSchema.migrator.appliedMigrations($0) }.isEmpty)

        XCTAssertNoThrow(try ObscuraSchema.migrate(db), "v1 must be a no-op over pre-existing tables")
        XCTAssertEqual(try tableNames(in: db), ObscuraSchema.v1Tables)
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
}
