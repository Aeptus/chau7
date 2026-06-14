import Foundation
import Chau7Core

/// Bounds the size of append-only event-log files (e.g. `~/.chau7/claude-events.jsonl`,
/// `~/.ai-events.log`) that are written by external hooks and consumed by tailing.
///
/// These files are transient event queues — the durable record lives in
/// `TelemetryStore` — but nothing rotates them, so they grow without bound
/// (observed at 150+ MB). Because consumers tail from an offset and `FileTailer`
/// re-reads from the start if the file shrinks below its offset, compaction is
/// only safe **before a tailer begins and while the writer is quiescent**
/// (i.e. at monitor start, during launch, before any Chau7-spawned AI session
/// has produced events). Callers must honor that contract.
enum LogFileCompactor {
    /// If the file exceeds `maxBytes`, rewrite it to keep only its most recent
    /// `keepBytes`, trimmed forward to the next line boundary so no partial line
    /// survives. The atomic replace gives the tailer a clean, smaller file to
    /// seek to EOF on. Returns true if a compaction happened.
    @discardableResult
    static func compactIfNeeded(path: String, maxBytes: Int, keepBytes: Int) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size > UInt64(max(0, maxBytes))
        else {
            return false
        }

        let keep = UInt64(max(0, keepBytes))
        let start = size > keep ? size - keep : 0
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: start)
            guard var data = try handle.readToEnd() else { return false }
            // When we cut mid-stream, drop the leading partial line so the first
            // retained line parses cleanly.
            if start > 0, let newline = data.firstIndex(of: 0x0A) {
                data = Data(data.suffix(from: data.index(after: newline)))
            }
            try data.write(to: url, options: .atomic)
            Log.info("LogFileCompactor: compacted \(path) from \(size) to \(data.count) bytes")
            return true
        } catch {
            Log.warn("LogFileCompactor: failed to compact \(path): \(error.localizedDescription)")
            return false
        }
    }

    /// Default bounds for the AI event-log queues: compact once past 16 MB,
    /// keeping the most recent ~8 MB of events.
    static let defaultMaxBytes = 16 * 1024 * 1024
    static let defaultKeepBytes = 8 * 1024 * 1024
}
