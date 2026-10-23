import Foundation
import SQLite3
import XCTest
@testable import Chau7Core

final class SQLiteHandleBoxTests: XCTestCase {
    func testCarriesNilHandle() {
        XCTAssertNil(SQLiteHandleBox(nil).handle)
    }

    /// The box exists so a store's connection can be handed back to the queue
    /// that owns it during `deinit`. This asserts the hand-off preserves the
    /// pointer identity that `sqlite3_close` depends on.
    func testCarriesLiveHandleIntact() throws {
        var db: OpaquePointer?
        try XCTSkipIf(sqlite3_open(":memory:", &db) != SQLITE_OK, "sqlite3 unavailable")
        let box = SQLiteHandleBox(db)

        XCTAssertEqual(box.handle, db)
        // Still usable through the box, which is what `TelemetryStore.deinit`
        // relies on: reading the pointer must not invalidate it.
        XCTAssertEqual(sqlite3_exec(box.handle, "CREATE TABLE t (id INTEGER)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(box.handle), SQLITE_OK)
    }

    func testValueSemanticsAcrossCopies() throws {
        var db: OpaquePointer?
        try XCTSkipIf(sqlite3_open(":memory:", &db) != SQLITE_OK, "sqlite3 unavailable")
        let original = SQLiteHandleBox(db)
        let copy = original

        XCTAssertEqual(copy.handle, db)
        XCTAssertEqual(sqlite3_close(copy.handle), SQLITE_OK)
        // `original` is a separate immutable value, not a second owner.
        XCTAssertEqual(original.handle, db)
    }
}
