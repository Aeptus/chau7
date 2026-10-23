import SQLite3
import XCTest
@testable import Chau7Core

/// The shared SQLite statement helper (Stage 3 of the SOLID/DRY plan):
/// every bind flavor round-trips through an in-memory database and comes
/// back through the matching column reader, and a bad prepare fails
/// cleanly (returns nil, never runs the body).
final class SQLiteStatementTests: XCTestCase {

    private var db: OpaquePointer?

    override func setUp() {
        super.setUp()
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let create = """
        CREATE TABLE samples (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            note TEXT,
            score REAL,
            attempts INTEGER,
            payload BLOB
        )
        """
        XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)
    }

    override func tearDown() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
        super.tearDown()
    }

    // MARK: - Round-trips

    func testBindAndReadAllTypes() {
        let payload = Data([0x00, 0x01, 0xFF, 0x7F])
        let insert = "INSERT INTO samples (id, name, note, score, attempts, payload) VALUES (?, ?, ?, ?, ?, ?)"
        let inserted = SQLiteStatement.withStatement(db, insert) { stmt -> SQLiteStatement.StepResult in
            stmt.bindInt64(1, 42)
            stmt.bindText(2, "hello world")
            stmt.bindNullableText(3, "a note")
            stmt.bindDouble(4, 3.25)
            stmt.bindNullableInt64(5, 7)
            stmt.bindBlob(6, payload)
            return stmt.step()
        }
        XCTAssertEqual(inserted, .done)

        let read: Void? = SQLiteStatement.withStatement(db, "SELECT id, name, note, score, attempts, payload FROM samples WHERE id = 42") { stmt in
            XCTAssertEqual(stmt.step(), .row)
            XCTAssertEqual(stmt.columnInt64(0), 42)
            XCTAssertEqual(stmt.columnText(1), "hello world")
            XCTAssertEqual(stmt.columnText(2), "a note")
            XCTAssertEqual(stmt.columnDouble(3), 3.25)
            XCTAssertFalse(stmt.columnIsNull(4))
            XCTAssertEqual(stmt.columnInt64(4), 7)
            XCTAssertEqual(stmt.columnBlob(5), payload)
            XCTAssertEqual(stmt.step(), .done)
        }
        XCTAssertNotNil(read)
    }

    func testNullableBindsStoreNullAndReadersReportIt() {
        let insert = "INSERT INTO samples (id, name, note, score, attempts, payload) VALUES (?, ?, ?, ?, ?, ?)"
        let inserted = SQLiteStatement.withStatement(db, insert) { stmt -> SQLiteStatement.StepResult in
            stmt.bindInt64(1, 1)
            stmt.bindText(2, "nulls")
            stmt.bindNullableText(3, nil)
            stmt.bindNullableDouble(4, nil)
            stmt.bindNullableInt64(5, nil)
            stmt.bindNull(6)
            return stmt.step()
        }
        XCTAssertEqual(inserted, .done)

        let read: Void? = SQLiteStatement.withStatement(db, "SELECT note, score, attempts, payload FROM samples WHERE id = 1") { stmt in
            XCTAssertEqual(stmt.step(), .row)
            XCTAssertNil(stmt.columnText(0))
            XCTAssertTrue(stmt.columnIsNull(1))
            XCTAssertTrue(stmt.columnIsNull(2))
            XCTAssertNil(stmt.columnBlob(3))
        }
        XCTAssertNotNil(read)
    }

    func testTransientTextBindCopiesShortLivedStorage() {
        // SQLITE_TRANSIENT must copy the bytes before the Swift string's
        // temporary UTF-8 buffer goes away; a scoped, interpolated string
        // exercises exactly that.
        let inserted = SQLiteStatement.withStatement(db, "INSERT INTO samples (id, name) VALUES (?, ?)") { stmt -> SQLiteStatement.StepResult in
            do {
                let ephemeral = "prefix-" + UUID().uuidString
                stmt.bindText(2, ephemeral)
            }
            stmt.bindInt64(1, 9)
            return stmt.step()
        }
        XCTAssertEqual(inserted, .done)

        let name = SQLiteStatement.withStatement(db, "SELECT name FROM samples WHERE id = 9") { stmt -> String? in
            stmt.step() == .row ? stmt.columnText(0) : nil
        }.flatMap { $0 }
        XCTAssertEqual(name?.hasPrefix("prefix-"), true)
    }

    // MARK: - Stepping

    func testStepReportsErrorForConstraintViolation() {
        let first = SQLiteStatement.withStatement(db, "INSERT INTO samples (id, name) VALUES (5, 'a')") { $0.step() }
        XCTAssertEqual(first, .done)

        // Duplicate primary key: step must surface the error code rather
        // than row/done.
        let second = SQLiteStatement.withStatement(db, "INSERT INTO samples (id, name) VALUES (5, 'b')") { $0.step() }
        XCTAssertEqual(second, .error(SQLITE_CONSTRAINT))
    }

    // MARK: - Prepare failures

    func testBadSQLReturnsNilWithoutRunningBody() {
        var bodyRan = false
        let result = SQLiteStatement.withStatement(db, "SELECT FROM WHERE nonsense") { _ -> Int in
            bodyRan = true
            return 1
        }
        XCTAssertNil(result)
        XCTAssertFalse(bodyRan)
    }

    func testNilDatabaseHandleReturnsNil() {
        let result = SQLiteStatement.withStatement(nil, "SELECT 1") { _ -> Int in 1 }
        XCTAssertNil(result)
    }
}
