import Foundation
import Chau7Core

/// Independent `@Observable` for the session-awareness layer of the
/// Repository pane — the agent-touched-files set, per-turn breakdown,
/// per-file action / timeline data, and the active-session vs. manual-git
/// view-mode flags. Extracted from `RepositoryPaneModel` so an
/// EventJournal-driven session refresh doesn't fan invalidations out to
/// status / history / commit / branches through the outer model.
///
/// The cross-section accessors (`sessionStagedFiles`, `otherStagedFiles`,
/// `changeCount(touchedBy:)`) stay on the model because they correlate
/// session state with status state.
@Observable
final class RepoSessionState {
    /// Whether the pane is currently in session-aware mode — `true` when a
    /// RuntimeSession is active for this tab and the user hasn't forced
    /// git mode.
    var isSessionMode = false

    /// User override that forces full git mode even when a session is
    /// active. Toggled by the Session / Git pill in the header.
    var forceGitMode = false

    /// Files the agent has touched across all turns in the current session.
    var sessionTouchedFiles: Set<String> = []

    /// Files the agent touched in the current turn.
    var turnTouchedFiles: Set<String> = []

    /// Per-file action set derived from tool journaling and command-block
    /// fallbacks (read / written / deleted / etc.).
    var sessionFileActions: [String: Set<FileTrackingAction>] = [:]

    /// Per-file timeline of touches across turns.
    var sessionFileTimeline: [String: [FileTouchRecord]] = [:]

    /// Files touched partitioned by turn ID.
    var sessionFilesByTurn: [String: Set<String>] = [:]

    /// Aggregated current-turn summary (tool counts, tokens, cost) for the
    /// session-mode header chip.
    var turnSummary: TurnSummaryInfo?
}
