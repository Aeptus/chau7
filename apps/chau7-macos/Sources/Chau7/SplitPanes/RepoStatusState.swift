import Foundation

/// Independent `@Observable` for the Status section of the Repository pane —
/// the working-tree status (staged / unstaged / untracked / conflicted file
/// lists) plus per-file diff stats. Extracted from `RepositoryPaneModel`
/// so a `git status --porcelain` refresh that bumps the file lists doesn't
/// fan invalidations out to the history / commit / branches sections
/// through the same outer observable.
///
/// The model still owns the cross-section helpers (`refreshAll`,
/// `refreshStatus`, the session-partitioning accessors) since they need
/// access to multiple sub-states; this class just carries the observable
/// data the Status view binds against.
@Observable
final class RepoStatusState {
    var stagedFiles: [FileStatus] = []
    var unstagedFiles: [FileStatus] = []
    var untrackedFiles: [String] = []
    var conflictedFiles: [String] = []

    /// Per-file `+adds / -dels` derived from `git diff --numstat`. Keyed on
    /// the path used in the file-status lists; missing entries render as
    /// "0 / 0" or hide the chip depending on the view.
    var diffStats: [String: DiffStat] = [:]
}
