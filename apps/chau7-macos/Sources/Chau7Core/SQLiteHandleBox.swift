import Foundation

/// Carries an `OpaquePointer` SQLite connection across a dispatch boundary.
///
/// `OpaquePointer` is not `Sendable`, which is correct — nothing about the
/// pointer itself makes it safe to touch from two threads. This box is the
/// narrow, honest exception for the one shape that *is* safe: a store whose
/// connection is owned by one serial queue, handing that connection to the
/// same queue for the final `sqlite3_close` during `deinit`.
///
/// Both `TelemetryStore` and `SpineJournalStore` close this way, and both do
/// so specifically to avoid a `queue.sync` in `deinit` (which deadlocks if the
/// last strong reference is released from a block already running on that
/// queue). The hand-off is a transfer of ownership to the owning queue, never
/// a second concurrent user of the handle.
///
/// The box is single-value and deliberately does not expose the pointer for
/// general use — call sites should hand it straight to `sqlite3_close`. A
/// second accessor would let the connection escape the queue it is confined to.
public struct SQLiteHandleBox: @unchecked Sendable {
    /// The raw connection. Only valid to call `sqlite3_close` on, and only from
    /// the queue that owns it.
    public let handle: OpaquePointer?

    public init(_ handle: OpaquePointer?) {
        self.handle = handle
    }
}
