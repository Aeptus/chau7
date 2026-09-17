import Foundation

/// Reads an agent transcript file (Codex/Claude JSONL session logs) into a
/// string, capping memory for pathologically large files.
///
/// Active, long-running agent sessions can produce multi-GB logs. Reading the
/// whole file as `Data` + `String` allocates ~2× its size and can OOM the host
/// process — especially the telemetry repair sweep. Oversized reads are partial
/// history; callers must not label per-event usage summed from a tail complete.
public enum BoundedTranscriptReader {
    /// Default cap for recent context. Full-run metrics may require earlier
    /// records; `truncatedFromBytes` explicitly reports that loss of coverage.
    public static let defaultMaxBytes = 48 * 1024 * 1024

    public struct Reading {
        public let text: String
        /// Original file size in bytes when the read was truncated to the tail;
        /// `nil` when the whole file was read. Lets callers log/flag truncation.
        public let truncatedFromBytes: Int?
    }

    /// File size in bytes, or 0 if unavailable.
    public static func fileSize(at path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
    }

    /// Returns the file contents (whole, or a bounded tail for oversized files),
    /// or `nil` if the file can't be read. For the tail path the leading partial
    /// record is dropped and bytes are decoded leniently (a seek can land mid
    /// UTF-8 sequence), so the result always starts on a record boundary.
    public static func read(at file: URL, maxBytes: Int = defaultMaxBytes) -> Reading? {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            guard length <= UInt64(Int.max) else { return nil }
            let size = Int(length)
            let offset = max(0, size - maxBytes)
            var startsOnRecordBoundary = true
            if offset > 0 {
                try handle.seek(toOffset: UInt64(offset - 1))
                startsOnRecordBoundary = try handle.read(upToCount: 1)?.first == 0x0A
            } else {
                try handle.seek(toOffset: 0)
            }
            // Do not readToEnd: the file can grow between the size check and
            // the read, defeating the very memory bound this helper promises.
            let data = try handle.read(upToCount: min(size, maxBytes)) ?? Data()
            if offset == 0 {
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                return Reading(text: text, truncatedFromBytes: nil)
            }
            var text = String(decoding: data, as: UTF8.self)
            if !startsOnRecordBoundary {
                text = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? ""
            }
            return Reading(text: text, truncatedFromBytes: size)
        } catch {
            return nil
        }
    }
}
