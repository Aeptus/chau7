import Chau7Core
import Foundation

/// Atomic on-disk writer for `~/.chau7/cto_state.json`.
///
/// The wrapper scripts continue to consult per-session
/// `~/.chau7/cto_active/<session-id>` flag files for their hot-path
/// "is CTO active for this session" check — that path is a single
/// `stat()` and is critical when shells like NVM invoke coreutils
/// thousands of times during init.
///
/// `cto_state.json` is a *diagnostic mirror* of the same state plus
/// richer context (mode, deferred sessions, gain stats). It's written
/// only when the runtime monitor records a state-changing event, so the
/// disk write isn't on the hot path. Humans, bug reports, and external
/// tooling can read it for the "what does Chau7 think CTO is currently
/// doing" view that's otherwise spread across the in-memory monitor +
/// per-session flag files.
enum CTOStateFile {

    private static let defaultStateURL: URL = RuntimeIsolation.chau7Directory()
        .appendingPathComponent("cto_state.json")

    /// Test seam: when set, all reads/writes/removes target this URL instead
    /// of the real `~/.chau7/cto_state.json`. The live app instance heartbeats
    /// the real file, so tests must not share it (or delete it on teardown).
    static var stateURLOverrideForTesting: URL?

    private static var stateURL: URL {
        stateURLOverrideForTesting ?? defaultStateURL
    }

    /// Encode `snapshot` to pretty-printed JSON and write it atomically
    /// to `~/.chau7/cto_state.json`. Errors are logged at `.warn` — this
    /// is a diagnostic write, so failure here must not break the live
    /// CTO control plane.
    static func write(_ snapshot: CTOStateSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(snapshot) else {
            Log.warn("CTOStateFile: failed to encode snapshot")
            return
        }

        // Ensure the parent directory exists. `Persist.save(throws:)` would
        // do this but it's overkill for a 1-2 KB JSON write; raw API keeps
        // the implementation grep-able from the wrapper-script side.
        let parent = stateURL.deletingLastPathComponent()
        FileOperations.createDirectory(at: parent)

        do {
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            Log.warn("CTOStateFile: failed to write \(stateURL.lastPathComponent): \(error)")
        }
    }

    /// Remove the diagnostic file (called on `teardown()` so a mode flip
    /// to `.off` doesn't leave a stale-but-positive view on disk).
    static func remove() {
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// Resolved path for the diagnostic file — exposed for tests and
    /// the settings-panel "reveal in Finder" affordance.
    static var path: String {
        stateURL.path
    }
}
