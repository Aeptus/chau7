import Foundation

/// Pure parsers for git plumbing/porcelain command output.
///
/// Extracted from `RepositoryPaneModel` (Stage 3 of the SOLID/DRY plan,
/// `docs/SOLID-DRY-REVIEW.md`): the pane model still owns fetching and
/// state publication, but the string → value-type parsing is pure logic
/// with zero AppKit/SwiftUI dependencies, so it lives in Chau7Core where
/// it can be tested directly.
///
/// The result types mirror the pane-facing types in
/// `Sources/Chau7/SplitPanes/RepositoryPaneTypes.swift` minus their UI
/// affordances (SF Symbol names, hover text, `Identifiable` UUIDs). The
/// app-side shims on `RepositoryPaneModel` map these into the UI types.
public enum GitPorcelainParser {

    // MARK: - Result Types

    /// How a file changed, per one column of `git status --porcelain`.
    public enum FileChange: String, Sendable, Equatable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case unmerged = "U"
    }

    /// One file row from `git status --porcelain`, attributed to either the
    /// index (staged) or work-tree (unstaged) column.
    public struct FileEntry: Sendable, Equatable {
        public let path: String
        public let changeType: FileChange
        public let indexStatus: Character
        public let workTreeStatus: Character

        public init(path: String, changeType: FileChange, indexStatus: Character, workTreeStatus: Character) {
            self.path = path
            self.changeType = changeType
            self.indexStatus = indexStatus
            self.workTreeStatus = workTreeStatus
        }
    }

    /// Full classification of a `git status --porcelain` listing.
    public struct StatusParseResult: Sendable, Equatable {
        public var staged: [FileEntry]
        public var unstaged: [FileEntry]
        public var untracked: [String]
        public var conflicted: [String]

        public init(staged: [FileEntry], unstaged: [FileEntry], untracked: [String], conflicted: [String]) {
            self.staged = staged
            self.unstaged = unstaged
            self.untracked = untracked
            self.conflicted = conflicted
        }
    }

    /// Per-branch last-commit info from `git branch -v --list`.
    public struct BranchDetail: Sendable, Equatable {
        public let name: String
        public let lastCommitHash: String
        public let lastCommitMessage: String

        public init(name: String, lastCommitHash: String, lastCommitMessage: String) {
            self.name = name
            self.lastCommitHash = lastCommitHash
            self.lastCommitMessage = lastCommitMessage
        }
    }

    /// One commit from the 5-line-per-commit `git log` format the
    /// repository pane requests (hash / short hash / subject / author /
    /// ISO-8601 date).
    public struct CommitEntry: Sendable, Equatable {
        public let hash: String
        public let shortHash: String
        public let message: String
        public let author: String
        public let date: Date
        public let dateString: String

        public init(hash: String, shortHash: String, message: String, author: String, date: Date, dateString: String) {
            self.hash = hash
            self.shortHash = shortHash
            self.message = message
            self.author = author
            self.date = date
            self.dateString = dateString
        }
    }

    /// One entry from `git stash list`.
    public struct StashEntry: Sendable, Equatable {
        public let index: Int
        public let description: String
        public let branch: String?

        public init(index: Int, description: String, branch: String?) {
            self.index = index
            self.description = description
            self.branch = branch
        }
    }

    /// Addition/deletion counts for one file from `git diff --numstat`.
    public struct DiffStat: Sendable, Equatable {
        public let additions: Int
        public let deletions: Int

        public init(additions: Int, deletions: Int) {
            self.additions = additions
            self.deletions = deletions
        }
    }

    // MARK: - Status

    public static func parseStatus(_ output: String) -> StatusParseResult {
        var staged: [FileEntry] = []
        var unstaged: [FileEntry] = []
        var untracked: [String] = []
        var conflicted: [String] = []

        for line in output.components(separatedBy: "\n") where line.count >= 3 {
            let x = line[line.startIndex] // index status
            let y = line[line.index(after: line.startIndex)] // work-tree status
            let path = String(line.dropFirst(3))
            let displayPath: String
            if let arrowRange = path.range(of: " -> ") {
                displayPath = String(path[arrowRange.upperBound...])
            } else {
                displayPath = path
            }

            // Untracked
            if x == "?" && y == "?" {
                untracked.append(displayPath)
                continue
            }

            // Unmerged (conflict)
            if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                conflicted.append(displayPath)
                continue
            }

            // Staged (index column)
            if x != " ", x != "?" {
                staged.append(FileEntry(
                    path: displayPath,
                    changeType: Self.changeType(from: x),
                    indexStatus: x,
                    workTreeStatus: y
                ))
            }

            // Unstaged (work-tree column)
            if y != " ", y != "?" {
                unstaged.append(FileEntry(
                    path: displayPath,
                    changeType: Self.changeType(from: y),
                    indexStatus: x,
                    workTreeStatus: y
                ))
            }
        }

        return StatusParseResult(staged: staged, unstaged: unstaged, untracked: untracked, conflicted: conflicted)
    }

    private static func changeType(from char: Character) -> FileChange {
        switch char {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "U": return .unmerged
        default: return .modified
        }
    }

    // MARK: - Branches

    /// Parse `git branch -v --list` which includes last commit per branch.
    /// Format: "* main      abc1234 Last commit message" or "  feature   def5678 Some work"
    public static func parseBranchesVerbose(_ output: String) -> (names: [String], details: [String: BranchDetail]) {
        var names: [String] = []
        var details: [String: BranchDetail] = [:]
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let isCurrent = line.hasPrefix("*")
            let cleaned = isCurrent ? String(trimmed.dropFirst(2)) : trimmed

            // Skip detached HEAD entries like "(HEAD detached at abc1234)"
            if cleaned.hasPrefix("(") { continue }

            // Split on whitespace: name, hash, message...
            let parts = cleaned.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                names.append(cleaned)
                continue
            }
            let name = String(parts[0])
            let hash = String(parts[1])
            let message = parts.count > 2 ? String(parts[2]) : ""
            names.append(name)
            details[name] = BranchDetail(name: name, lastCommitHash: hash, lastCommitMessage: message)
        }
        return (names, details)
    }

    /// Parse `git rev-list --count --left-right @{upstream}...HEAD`
    /// Output: "3\t5" where 3=behind, 5=ahead
    public static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int)? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard parts.count == 2,
              let behind = Int(parts[0]),
              let ahead = Int(parts[1]) else { return nil }
        return (ahead: ahead, behind: behind)
    }

    public static func parseRemoteBranches(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("HEAD") }
    }

    // MARK: - Commit Log

    /// Parse the pane's 5-lines-per-commit `git log` format.
    ///
    /// `relativeDate` renders `CommitEntry.dateString` from the parsed
    /// commit date. It is injected because the app's rendering is
    /// localized (LocalizationManager), which must not leak into Chau7Core;
    /// the default keeps raw parsing usable without any formatting.
    public static func parseCommitLog(
        _ output: String,
        relativeDate: (Date) -> String = { _ in "" }
    ) -> [CommitEntry] {
        let lines = output.components(separatedBy: "\n")
        var commits: [CommitEntry] = []
        // Each commit is 5 lines: hash, shortHash, subject, author, date
        var i = 0
        while i + 4 < lines.count {
            let hash = lines[i]
            let shortHash = lines[i + 1]
            let subject = lines[i + 2]
            let author = lines[i + 3]
            let dateStr = lines[i + 4]
            i += 5

            guard !hash.isEmpty else { continue }

            let date = DateFormatters.parseISO8601(dateStr) ?? Date.distantPast
            commits.append(CommitEntry(
                hash: hash,
                shortHash: shortHash,
                message: subject,
                author: author,
                date: date,
                dateString: relativeDate(date)
            ))
        }
        return commits
    }

    // MARK: - Stash List

    public static func parseStashList(_ output: String) -> [StashEntry] {
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: "\n")
            .enumerated()
            .compactMap { index, line in
                guard !line.isEmpty else { return nil }
                // Format: stash@{0}: WIP on main: abc1234 message
                // Or:     stash@{0}: On develop: saving progress
                let parts = line.components(separatedBy: ": ")
                let description = parts.dropFirst().joined(separator: ": ")

                // Extract branch from "WIP on main" or "On develop"
                var branch: String?
                if parts.count >= 2 {
                    let stashType = parts[1]
                    if stashType.hasPrefix("WIP on ") {
                        branch = String(stashType.dropFirst("WIP on ".count))
                    } else if stashType.hasPrefix("On ") {
                        branch = String(stashType.dropFirst("On ".count))
                    }
                }

                return StashEntry(index: index, description: description.isEmpty ? line : description, branch: branch)
            }
    }

    // MARK: - Diff Numstat

    /// Parse `git diff --numstat` output. Combines unstaged and staged stats.
    public static func parseDiffNumstat(_ unstaged: String, _ staged: String) -> [String: DiffStat] {
        var stats: [String: DiffStat] = [:]
        for line in (unstaged + "\n" + staged).components(separatedBy: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            guard let additions = Int(parts[0]), let deletions = Int(parts[1]) else { continue }
            let path = String(parts[2])
            if let existing = stats[path] {
                stats[path] = DiffStat(
                    additions: existing.additions + additions,
                    deletions: existing.deletions + deletions
                )
            } else {
                stats[path] = DiffStat(additions: additions, deletions: deletions)
            }
        }
        return stats
    }
}
