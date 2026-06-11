import Foundation

/// Independent `@Observable` for the History section of the Repository pane —
/// commit log, stash list, and the history search text. Extracted from
/// `RepositoryPaneModel` so a search-text bump in the history section no
/// longer invalidates status / commit-composer / branch UI through the same
/// outer observable. SwiftUI tracks observation per accessed object; the
/// history view binds against `repo.history.*` and gets re-rendered only
/// when one of these properties actually changes.
///
/// `commitLogLimit` is `@ObservationIgnored` because nothing observes the
/// limit itself — it's a parameter the model captures before async git
/// calls and grows when the user pages further back.
@Observable
final class RepoHistoryState {
    var commits: [CommitEntry] = []
    var stashes: [StashEntry] = []
    var historySearchText = ""

    @ObservationIgnored
    var commitLogLimit = 50

    /// Filters `commits` by `historySearchText` (lowercased substring match
    /// across the subject, author, and short hash). Returns the full list
    /// when the search text is empty.
    var filteredCommits: [CommitEntry] {
        guard !historySearchText.isEmpty else { return commits }
        let query = historySearchText.lowercased()
        return commits.filter {
            $0.message.lowercased().contains(query)
                || $0.author.lowercased().contains(query)
                || $0.shortHash.lowercased().contains(query)
        }
    }
}
