import Foundation

// MARK: - Diff Value Types

//
// These types moved here from `Sources/Chau7/SplitPanes/SplitPaneController.swift`
// (Stage 3 of the SOLID/DRY plan, `docs/SOLID-DRY-REVIEW.md`) together with the
// unified-diff parser that produces them. The app keeps same-named typealiases
// next to `DiffViewerModel` so existing call sites compile unchanged.

/// A single line in a diff hunk
public enum DiffLineType: Sendable, Equatable {
    case context(String)
    case addition(String)
    case deletion(String)
    case hunkHeader(String)
}

/// What the parser learned about the diff beyond the hunk content. Lets the
/// empty-state UI explain *why* there are no hunks instead of always
/// claiming "no changes" for files that are actually binary or renamed.
public enum DiffSummary: Sendable, Equatable {
    /// Normal textual diff (hunks may or may not be present).
    case content
    /// Git reported `Binary files a/foo and b/foo differ` — no textual hunks.
    case binary
    /// Git reported `rename from`/`rename to` lines; if textual hunks also
    /// appear in the diff (rename + edit) they're still parsed normally and
    /// the summary just adds the rename context.
    case renamed(from: String, to: String)
}

/// A parsed hunk from unified diff output
public struct DiffHunk: Identifiable, Sendable {
    public let id = UUID()
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLineType]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLineType]) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

// MARK: - Unified Diff Parser

/// Pure parser for `git diff` unified output.
///
/// Extracted from `DiffViewerModel` so the string → hunk parsing can be
/// tested without spinning up the pane model; the model keeps a forwarding
/// `parseUnifiedDiff` shim for its call sites.
public enum UnifiedDiffParser {
    public struct ParseResult: Sendable {
        public let hunks: [DiffHunk]
        public let additions: Int
        public let deletions: Int
        public let summary: DiffSummary

        public init(hunks: [DiffHunk], additions: Int, deletions: Int, summary: DiffSummary) {
            self.hunks = hunks
            self.additions = additions
            self.deletions = deletions
            self.summary = summary
        }
    }

    public static func parseUnifiedDiff(_ raw: String) -> ParseResult {
        guard !raw.isEmpty else {
            return ParseResult(hunks: [], additions: 0, deletions: 0, summary: .content)
        }

        var hunks: [DiffHunk] = []
        var currentLines: [DiffLineType] = []
        var currentHeader = ""
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var totalAdditions = 0, totalDeletions = 0
        var inHunk = false
        var isBinary = false
        var renameFrom: String?
        var renameTo: String?

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                // Flush previous hunk
                if inHunk {
                    hunks.append(DiffHunk(
                        header: currentHeader,
                        oldStart: oldStart, oldCount: oldCount,
                        newStart: newStart, newCount: newCount,
                        lines: currentLines
                    ))
                    currentLines = []
                }

                // Parse hunk header: @@ -oldStart,oldCount +newStart,newCount @@
                currentHeader = line
                let numbers = parseHunkHeader(line)
                oldStart = numbers.oldStart
                oldCount = numbers.oldCount
                newStart = numbers.newStart
                newCount = numbers.newCount
                currentLines.append(.hunkHeader(line))
                inHunk = true

            } else if inHunk {
                if line.hasPrefix("+") {
                    currentLines.append(.addition(String(line.dropFirst())))
                    totalAdditions += 1
                } else if line.hasPrefix("-") {
                    currentLines.append(.deletion(String(line.dropFirst())))
                    totalDeletions += 1
                } else if line.hasPrefix(" ") {
                    currentLines.append(.context(String(line.dropFirst())))
                } else if line.hasPrefix("\\") {
                    // "\ No newline at end of file" — skip
                }
            } else {
                // Pre-hunk header lines from `git diff`: detect binary and
                // rename markers so the empty-state UI can explain *why*
                // there are no hunks instead of just showing "no changes".
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    isBinary = true
                } else if line.hasPrefix("rename from ") {
                    renameFrom = String(line.dropFirst("rename from ".count))
                } else if line.hasPrefix("rename to ") {
                    renameTo = String(line.dropFirst("rename to ".count))
                }
            }
        }

        // Flush last hunk
        if inHunk {
            hunks.append(DiffHunk(
                header: currentHeader,
                oldStart: oldStart, oldCount: oldCount,
                newStart: newStart, newCount: newCount,
                lines: currentLines
            ))
        }

        let summary: DiffSummary
        if isBinary {
            summary = .binary
        } else if let from = renameFrom, let to = renameTo {
            summary = .renamed(from: from, to: to)
        } else {
            summary = .content
        }

        return ParseResult(
            hunks: hunks,
            additions: totalAdditions,
            deletions: totalDeletions,
            summary: summary
        )
    }

    /// Format: @@ -oldStart[,oldCount] +newStart[,newCount] @@
    /// Internal (not private) so tests can exercise the header edge cases
    /// directly via `@testable import Chau7Core`.
    static func parseHunkHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        let scanner = Scanner(string: header)
        _ = scanner.scanString("@@")
        _ = scanner.scanString("-")
        let oStart = scanner.scanInt() ?? 0
        var oCount = 1
        if scanner.scanString(",") != nil {
            oCount = scanner.scanInt() ?? 1
        }
        _ = scanner.scanString("+")
        let nStart = scanner.scanInt() ?? 0
        var nCount = 1
        if scanner.scanString(",") != nil {
            nCount = scanner.scanInt() ?? 1
        }
        return (oStart, oCount, nStart, nCount)
    }
}
