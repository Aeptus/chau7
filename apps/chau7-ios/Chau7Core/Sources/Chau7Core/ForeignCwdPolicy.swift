import Foundation

/// Pure decision: should a session-directory writeback be refused as foreign?
///
/// Answers true when the proposed cwd has no prefix relationship to either of
/// the tab's existing anchors (cwd, git root). Used by
/// `TerminalControlService.updateSessionDirectoryAcrossWindows` to refuse
/// writebacks whose directory is geometrically unrelated to the tab's known
/// state — the signature of a session id bound to the wrong tab.
public enum ForeignCwdPolicy {
    public static func shouldRefuse(
        newDirectory: String,
        tabCurrentDirectory: String,
        tabGitRoot: String?
    ) -> Bool {
        let normalizedTarget = URL(fileURLWithPath: newDirectory).standardized.path
        let candidates: [String] = [tabCurrentDirectory, tabGitRoot ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for candidate in candidates {
            let normalizedCandidate = URL(fileURLWithPath: candidate).standardized.path
            if DirectoryPathMatcher.bidirectionalPrefixRank(
                targetPath: normalizedTarget,
                candidatePath: normalizedCandidate
            ) != nil {
                return false
            }
        }

        // No anchor → no basis to reject. Allow the write to seed the first
        // cwd. With at least one anchor and no match, it's foreign.
        return !candidates.isEmpty
    }
}
