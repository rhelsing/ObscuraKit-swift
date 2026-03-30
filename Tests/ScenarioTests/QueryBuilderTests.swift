import XCTest
@testable import ObscuraKit

/// Unit tests for QueryBuilder — where, orderBy, limit, operators.
/// Matches Android's QueryBuilder test coverage.
final class QueryBuilderTests: XCTestCase {

    private func makeModelWithEntries() async throws -> Model {
        let def = ModelDefinition(name: "post", sync: .gset)
        let store = try ModelStore()
        let model = Model(name: "post", definition: def, store: store)
        model.deviceId = "device1"

        _ = try await model.create(["author": "alice", "title": "Swift tips", "likes": 10])
        _ = try await model.create(["author": "bob", "title": "Kotlin guide", "likes": 25])
        _ = try await model.create(["author": "alice", "title": "Hello world", "likes": 5])
        _ = try await model.create(["author": "carol", "title": "React hooks", "likes": 15])

        return model
    }

    // MARK: - Simple equality

    func testWhere_simpleEquality() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.author": "alice"]).exec()
        XCTAssertEqual(results.count, 2)
    }

    func testWhere_byAuthorDeviceId() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["authorDeviceId": "device1"]).exec()
        XCTAssertEqual(results.count, 4)
    }

    // MARK: - Operators: equals / not

    func testWhere_equals() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.author": ["equals": "bob"]]).exec()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].data["title"] as? String, "Kotlin guide")
    }

    func testWhere_not() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.author": ["not": "alice"]]).exec()
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Operators: comparison

    func testWhere_greaterThan() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.likes": ["greaterThan": 10]]).exec()
        XCTAssertEqual(results.count, 2) // 25 and 15
    }

    func testWhere_atLeast() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.likes": ["atLeast": 10]]).exec()
        XCTAssertEqual(results.count, 3) // 10, 25, 15
    }

    func testWhere_lessThan() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.likes": ["lessThan": 15]]).exec()
        XCTAssertEqual(results.count, 2) // 10 and 5
    }

    func testWhere_atMost() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.likes": ["atMost": 15]]).exec()
        XCTAssertEqual(results.count, 3) // 10, 5, 15
    }

    func testWhere_range() async throws {
        let model = try await makeModelWithEntries()
        // Range: 5 <= likes <= 15
        let results = await model.where(["data.likes": ["atLeast": 5, "atMost": 15]]).exec()
        XCTAssertEqual(results.count, 3) // 10, 5, 15
    }

    // MARK: - Operators: set membership

    func testWhere_oneOf() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.author": ["oneOf": ["alice", "carol"]]]).exec()
        XCTAssertEqual(results.count, 3) // 2 alice + 1 carol
    }

    func testWhere_noneOf() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.author": ["noneOf": ["alice", "carol"]]]).exec()
        XCTAssertEqual(results.count, 1) // bob only
    }

    // MARK: - Operators: string matching

    func testWhere_contains() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.title": ["contains": "guide"]]).exec()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].data["author"] as? String, "bob")
    }

    func testWhere_startsWith() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.title": ["startsWith": "Hello"]]).exec()
        XCTAssertEqual(results.count, 1)
    }

    func testWhere_endsWith() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where(["data.title": ["endsWith": "tips"]]).exec()
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - orderBy

    func testOrderBy_numeric() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where([:]).orderBy("data.likes", .desc).exec()
        let likes = results.compactMap { $0.data["likes"] as? Int }
        XCTAssertEqual(likes, [25, 15, 10, 5])
    }

    func testOrderBy_ascending() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where([:]).orderBy("data.likes", .asc).exec()
        let likes = results.compactMap { $0.data["likes"] as? Int }
        XCTAssertEqual(likes, [5, 10, 15, 25])
    }

    func testOrderBy_string() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where([:]).orderBy("data.author", .asc).exec()
        let authors = results.compactMap { $0.data["author"] as? String }
        // alice, alice, bob, carol
        XCTAssertEqual(authors.first, "alice")
        XCTAssertEqual(authors.last, "carol")
    }

    // MARK: - limit

    func testLimit() async throws {
        let model = try await makeModelWithEntries()
        let results = await model.where([:]).orderBy("data.likes", .desc).limit(2).exec()
        XCTAssertEqual(results.count, 2)
        let likes = results.compactMap { $0.data["likes"] as? Int }
        XCTAssertEqual(likes, [25, 15])
    }

    // MARK: - first / count

    func testFirst() async throws {
        let model = try await makeModelWithEntries()
        let result = await model.where(["data.author": "bob"]).first()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.data["title"] as? String, "Kotlin guide")
    }

    func testCount() async throws {
        let model = try await makeModelWithEntries()
        let count = await model.where(["data.author": "alice"]).count()
        XCTAssertEqual(count, 2)
    }

    // MARK: - Combined: where + orderBy + limit

    func testCombined_topPopularByAuthor() async throws {
        let model = try await makeModelWithEntries()
        // Top 2 posts by likes, only from alice
        let results = await model
            .where(["data.author": "alice"])
            .orderBy("data.likes", .desc)
            .limit(1)
            .exec()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].data["likes"] as? Int, 10)
    }
}
