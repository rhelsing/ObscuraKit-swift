import XCTest
import GRDB
@testable import ObscuraKit

final class GRDBSmokeTests: XCTestCase {

    func testInMemoryDatabaseWorks() throws {
        let db = try DatabaseQueue()

        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE test (
                    id INTEGER PRIMARY KEY,
                    value TEXT NOT NULL
                )
            """)
            try db.execute(sql: "INSERT INTO test (value) VALUES (?)", arguments: ["hello"])
        }

        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM test")
        }

        XCTAssertEqual(count, 1)
    }
}
