import Foundation

/// Reads an agent transcript file (Codex/Claude JSONL session logs) into a
/// string, capping memory for pathologically large files.
///
/// Active, long-running agent sessions can produce multi-GB logs. Reading the
/// whole file as `Data` + `String` allocates ~2× its size and can OOM the host
/// process — especially the telemetry repair sweep, which walks many runs back
/// to back. These JSONL logs record cumulative token-usage events at the *end*
/// of the file, so for oversized files we read only the trailing `maxBytes` and
/// drop the partial leading record, leaving callers with whole JSONL lines.
public enum BoundedTranscriptReader {
    /// Default cap. The data callers actually need (cumulative token counts and
    /// the most recent turns) lives at the tail; 48 MB keeps ample context while
    /// bounding peak memory regardless of true file size.
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
        let size = fileSize(at: file.path)
        if size <= maxBytes {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return Reading(text: text, truncatedFromBytes: nil)
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(size - maxBytes))
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd() else { return nil }

        var text = String(decoding: data, as: UTF8.self)
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return Reading(text: text, truncatedFromBytes: size)
    }
}
