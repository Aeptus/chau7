import Foundation

/// Bounds the append-only provider-quota snapshot log.
///
/// `~/.chau7/usage/provider-quotas.jsonl` is appended to on every quota refresh
/// and had no size cap, no rotation, and no retention. Meanwhile `loadSnapshots`
/// read the *whole* file, split it, and ran `JSONSerialization` over every line
/// on a 30-second timer — while the caller used only the last 600 seconds of
/// data. So the file grew without bound and each refresh paid a parse cost
/// proportional to total history rather than to the window actually consumed:
/// at ~400 bytes per line the read cost reached gigabytes of transient
/// `[String: Any]` allocation.
///
/// The two knobs are separated because they fix different halves:
/// - `maxBytes` / `keepBytes` bound what is *kept* on disk.
/// - `readBudgetBytes` bounds what is *read* per refresh.
public enum ProviderQuotaSnapshotLog {
    /// Rotate once the file passes this size.
    public static let maxBytes = 2 * 1024 * 1024

    /// Retained after a rotation.
    ///
    /// Deliberately equal to `readBudgetBytes` so a read that follows a
    /// rotation still gets its full budget. Below it, every post-rotation read
    /// would silently be clamped to whatever the rotation left behind, which
    /// couples the two knobs in a way that is easy to break by tuning either
    /// one alone.
    public static let keepBytes = readBudgetBytes

    /// Bytes read from the tail of the file per refresh.
    ///
    /// At roughly 400 bytes per snapshot line this is ~1300 lines, against the
    /// ~20 lines a 600 s window at 30 s polling can contain. Generous enough
    /// that the window is never truncated, small enough that a file which has
    /// outgrown its cap still costs a bounded parse.
    public static let readBudgetBytes = 512 * 1024

    /// How much of the file's trailing bytes to read, given its total size.
    ///
    /// Pure so the budget is testable without touching the filesystem. Returns
    /// the full size when it already fits.
    public static func readWindowBytes(fileSize: Int, budgetBytes: Int = readBudgetBytes) -> Int {
        guard budgetBytes > 0, fileSize > budgetBytes else { return max(0, fileSize) }
        return budgetBytes
    }

    /// Byte offset to start reading from.
    public static func readStartOffset(fileSize: Int, budgetBytes: Int = readBudgetBytes) -> Int {
        max(0, fileSize - readWindowBytes(fileSize: fileSize, budgetBytes: budgetBytes))
    }

    /// Drops a leading partial line.
    ///
    /// Reading from the middle of a file almost always lands inside a record, so
    /// the first fragment must be discarded — otherwise `JSONSerialization`
    /// fails on it and, worse, a future parser might accept half a record.
    ///
    /// If the read started mid-file and contains no newline at all, then the
    /// entire read is one fragment and nothing is returned. `JSONSerialization`
    /// would reject it anyway, but handing a truncated object to the parser is
    /// exactly the failure this alignment exists to prevent, and returning the
    /// bytes makes that failure depend on the parser's leniency.
    public static func alignedTail(_ data: Data, startedMidFile: Bool) -> Data {
        guard startedMidFile else { return data }
        guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
        return Data(data[data.index(after: newline)...])
    }
}
