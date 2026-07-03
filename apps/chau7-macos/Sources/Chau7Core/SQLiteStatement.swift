import Foundation
import SQLite3

/// Thin, dependency-free wrapper over a prepared `sqlite3_stmt`.
///
/// Extracted for Stage 3 of the SOLID/DRY plan (`docs/SOLID-DRY-REVIEW.md`):
/// `SpineJournalStore`, `ProxyAnalyticsStore`, and `PersistentHistoryStore`
/// each hand-rolled the same prepare/finalize dance, the SQLITE_TRANSIENT
/// `unsafeBitCast` idiom, and text/blob column readers. This centralizes
/// that boilerplate once, in Chau7Core, with zero dependencies beyond the
/// system SQLite3 module.
///
/// Deliberately non-throwing to match the existing call-site style: stores
/// check optionals/booleans and log through their own loggers. Ownership of
/// the raw handle stays with `withStatement`, which always finalizes.
public struct SQLiteStatement {

    /// Result of one `sqlite3_step` call, folded into the three cases the
    /// stores actually branch on.
    public enum StepResult: Equatable {
        case row
        case done
        case error(Int32)
    }

    /// SQLITE_TRANSIENT: tells SQLite to copy bound text/blob bytes before
    /// returning, so Swift-managed storage can be released immediately.
    /// This is the single home of the `unsafeBitCast(-1, ...)` idiom.
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let handle: OpaquePointer

    /// Prepares `sql` against `db`, hands the statement to `body`, and
    /// always finalizes afterwards. Returns nil when the prepare fails
    /// (bad SQL, closed handle) without running `body`.
    @discardableResult
    public static func withStatement<T>(_ db: OpaquePointer?, _ sql: String, _ body: (SQLiteStatement) -> T) -> T? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        return body(SQLiteStatement(handle: stmt))
    }

    // MARK: - Binds (1-based indices, mirroring the C API)

    public func bindText(_ index: Int32, _ value: String) {
        sqlite3_bind_text(handle, index, value, -1, Self.transientDestructor)
    }

    public func bindNullableText(_ index: Int32, _ value: String?) {
        if let value {
            bindText(index, value)
        } else {
            bindNull(index)
        }
    }

    public func bindInt64(_ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(handle, index, value)
    }

    public func bindNullableInt64(_ index: Int32, _ value: Int64?) {
        if let value {
            bindInt64(index, value)
        } else {
            bindNull(index)
        }
    }

    public func bindDouble(_ index: Int32, _ value: Double) {
        sqlite3_bind_double(handle, index, value)
    }

    public func bindNullableDouble(_ index: Int32, _ value: Double?) {
        if let value {
            bindDouble(index, value)
        } else {
            bindNull(index)
        }
    }

    public func bindBlob(_ index: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), Self.transientDestructor)
        }
    }

    public func bindNull(_ index: Int32) {
        sqlite3_bind_null(handle, index)
    }

    // MARK: - Stepping

    public func step() -> StepResult {
        switch sqlite3_step(handle) {
        case SQLITE_ROW:
            return .row
        case SQLITE_DONE:
            return .done
        case let code:
            return .error(code)
        }
    }

    // MARK: - Column readers (0-based indices, mirroring the C API)

    /// nil when the column is NULL.
    public func columnText(_ index: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: text)
    }

    public func columnInt64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    public func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    /// nil when the column is NULL (or a zero-length blob, which SQLite
    /// reports with a NULL pointer).
    public func columnBlob(_ index: Int32) -> Data? {
        guard let base = sqlite3_column_blob(handle, index) else { return nil }
        return Data(bytes: base, count: Int(sqlite3_column_bytes(handle, index)))
    }

    /// True when the stored value is SQL NULL — for numeric columns, whose
    /// readers return 0 rather than nil on NULL.
    public func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }
}
