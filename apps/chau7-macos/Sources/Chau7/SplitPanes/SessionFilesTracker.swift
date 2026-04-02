import Chau7Core
import Foundation

/// Accumulates files touched by an AI agent session by reading the EventJournal.
///
/// Survives journal ring-buffer eviction: once a file path is seen, it stays
/// in `touchedFiles` even if the journal event is overwritten. Call `update(from:)`
/// on each refresh cycle to incrementally read new events.
final class SessionFilesTracker {
    /// All files touched by the agent across all turns in this session.
    private(set) var touchedFiles: Set<String> = []

    /// Journal cursor for incremental reads — only processes new events.
    private var cursor: UInt64 = 0

    /// The git root directory, used to normalize absolute paths to relative.
    var gitRoot: String?

    /// Read new events from the journal and extract file paths from tool_use events.
    func update(from journal: EventJournal) {
        let (events, newCursor, _) = journal.events(after: cursor, limit: 500)
        cursor = newCursor

        for event in events {
            guard event.type == RuntimeEventType.toolUse.rawValue,
                  let file = event.data["file"],
                  !file.isEmpty
            else { continue }

            let normalized = normalize(file)
            touchedFiles.insert(normalized)
        }
    }

    /// Reset tracking — call after push or when session changes.
    func reset() {
        touchedFiles.removeAll()
        cursor = 0
    }

    /// Normalize a file path: strip git root prefix to make it relative.
    private func normalize(_ path: String) -> String {
        guard let root = gitRoot, !root.isEmpty else { return path }
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(rootWithSlash) {
            return String(path.dropFirst(rootWithSlash.count))
        }
        // Already relative
        return path
    }
}
