import Foundation

/// Independent `@Observable` for the Branches section of the Repository pane —
/// the current branch name, local + remote branch lists, per-branch detail
/// (last commit subject + hash), and ahead/behind counters. Extracted from
/// `RepositoryPaneModel` so `git branch -v` / `git rev-list` refreshes
/// don't fan invalidations out to status / history / commit through the
/// outer model.
@Observable
final class RepoBranchState {
    /// Currently checked-out branch name, or nil for detached HEAD.
    var currentBranch: String?

    /// Local branch names from `git branch -v --list`.
    var branches: [String] = []

    /// Remote branch names from `git branch -r` (HEAD entries filtered out).
    var remoteBranches: [String] = []

    /// Per-branch last-commit metadata for hover tooltips.
    var branchDetails: [String: BranchDetail] = [:]

    /// Commits ahead of and behind the upstream branch, when an upstream
    /// is configured. Nil when there is no upstream.
    var aheadBehind: (ahead: Int, behind: Int)?
}
