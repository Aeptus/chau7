import Foundation

/// Independent `@Observable` for the commit composer of the Repository pane —
/// the in-flight message text and the amend flag. Extracted from
/// `RepositoryPaneModel` so that typing in the composer no longer fans
/// invalidations out to status / history / branches through the same outer
/// observable. SwiftUI tracks observation per accessed object; the
/// commit-composer view binds against `repo.commit.*` and gets re-rendered
/// only when one of these properties actually changes.
///
/// The persistence + conventional-prefix rules live on `RepoCommitDraftStore`
/// (a value type); this class just carries the observable mutable state.
@Observable
final class RepoCommitDraft {
    /// The in-flight commit message text bound to the composer's TextEditor.
    var message = ""

    /// Whether the next commit should be an `--amend` against the previous one.
    var isAmend = false
}
