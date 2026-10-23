import XCTest
@testable import Chau7Core

/// Direct tests for the pure git-output parsers.
///
/// Moved from `RepositoryPaneModelTests` when the parser bodies were lifted
/// into `Chau7Core.GitPorcelainParser` (Stage 3 of the SOLID/DRY plan). The
/// model keeps forwarding shims; model-level behavior stays covered in
/// `RepositoryPaneModelTests`.
final class GitPorcelainParserTests: XCTestCase {

    // MARK: - Status Parsing

    func testParseStatusEmpty() {
        let result = GitPorcelainParser.parseStatus("")
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.unstaged.isEmpty)
        XCTAssertTrue(result.untracked.isEmpty)
        XCTAssertTrue(result.conflicted.isEmpty)
    }

    func testParseStatusStagedModified() {
        let output = "M  src/main.swift"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.staged[0].path, "src/main.swift")
        XCTAssertEqual(result.staged[0].changeType, .modified)
        XCTAssertTrue(result.unstaged.isEmpty)
    }

    func testParseStatusUnstagedModified() {
        let output = " M src/main.swift"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertEqual(result.unstaged.count, 1)
        XCTAssertEqual(result.unstaged[0].path, "src/main.swift")
    }

    func testParseStatusBothStagedAndUnstaged() {
        let output = "MM src/main.swift"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.unstaged.count, 1)
        XCTAssertEqual(result.staged[0].path, "src/main.swift")
        XCTAssertEqual(result.unstaged[0].path, "src/main.swift")
    }

    func testParseStatusUntracked() {
        let output = "?? newfile.txt"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.unstaged.isEmpty)
        XCTAssertEqual(result.untracked, ["newfile.txt"])
    }

    func testParseStatusAdded() {
        let output = "A  src/new.swift"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.staged[0].changeType, .added)
    }

    func testParseStatusDeleted() {
        let output = "D  src/old.swift"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.staged[0].changeType, .deleted)
    }

    func testParseStatusRenamed() {
        let output = "R  old.swift -> new.swift"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.staged[0].path, "new.swift")
        XCTAssertEqual(result.staged[0].changeType, .renamed)
    }

    func testParseStatusConflict() {
        let output = "UU src/conflict.swift"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.unstaged.isEmpty)
        XCTAssertEqual(result.conflicted, ["src/conflict.swift"])
    }

    func testParseStatusConflictBothAdded() {
        let output = "AA src/both-added.swift"
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertEqual(result.conflicted, ["src/both-added.swift"])
    }

    func testParseStatusMixed() {
        let output = """
        M  staged.swift
         M unstaged.swift
        ?? untracked.txt
        A  added.swift
        D  deleted.swift
        UU conflicted.swift
        """
        let result = GitPorcelainParser.parseStatus(output)
        XCTAssertEqual(result.staged.count, 3) // M, A, D
        XCTAssertEqual(result.unstaged.count, 1)
        XCTAssertEqual(result.untracked.count, 1)
        XCTAssertEqual(result.conflicted.count, 1)
    }

    // MARK: - Remote Branch Parsing

    func testParseRemoteBranches() {
        let output = """
          origin/HEAD -> origin/main
          origin/main
          origin/develop
        """
        let branches = GitPorcelainParser.parseRemoteBranches(output)
        XCTAssertEqual(branches, ["origin/main", "origin/develop"])
    }

    // MARK: - Commit Log Parsing

    func testParseCommitLog() {
        let output = """
        abc123def456
        abc123d
        Fix login bug
        John Doe
        2026-04-01T12:00:00Z
        def789abc012
        def789a
        Add new feature
        Jane Smith
        2026-03-31T10:00:00Z
        """
        let commits = GitPorcelainParser.parseCommitLog(output)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].shortHash, "abc123d")
        XCTAssertEqual(commits[0].message, "Fix login bug")
        XCTAssertEqual(commits[0].author, "John Doe")
        XCTAssertEqual(commits[1].shortHash, "def789a")
        XCTAssertEqual(commits[1].message, "Add new feature")
    }

    func testParseCommitLogAppliesInjectedRelativeDateRenderer() {
        let output = """
        abc123def456
        abc123d
        Fix login bug
        John Doe
        2026-04-01T12:00:00Z
        """
        let commits = GitPorcelainParser.parseCommitLog(output) { date in
            "rendered:\(Int(date.timeIntervalSince1970))"
        }
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].dateString, "rendered:\(Int(commits[0].date.timeIntervalSince1970))")
    }

    func testParseCommitLogEmpty() {
        XCTAssertTrue(GitPorcelainParser.parseCommitLog("").isEmpty)
    }

    // MARK: - Stash Parsing

    func testParseStashList() {
        let output = """
        stash@{0}: WIP on main: abc1234 some work
        stash@{1}: On develop: saving progress
        """
        let stashes = GitPorcelainParser.parseStashList(output)
        XCTAssertEqual(stashes.count, 2)
        XCTAssertEqual(stashes[0].index, 0)
        XCTAssertTrue(stashes[0].description.contains("WIP"))
        XCTAssertEqual(stashes[1].index, 1)
    }

    func testParseStashListEmpty() {
        XCTAssertTrue(GitPorcelainParser.parseStashList("").isEmpty)
    }

    func testParseStashBranch() {
        let output = "stash@{0}: WIP on main: abc1234 some work"
        let stashes = GitPorcelainParser.parseStashList(output)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].branch, "main")
    }

    func testParseStashBranchOnPrefix() {
        let output = "stash@{0}: On develop: saving progress"
        let stashes = GitPorcelainParser.parseStashList(output)
        XCTAssertEqual(stashes[0].branch, "develop")
    }

    // MARK: - Ahead/Behind Parsing

    func testParseAheadBehind() {
        let result = GitPorcelainParser.parseAheadBehind("3\t5")
        XCTAssertEqual(result?.ahead, 5)
        XCTAssertEqual(result?.behind, 3)
    }

    func testParseAheadBehindZero() {
        let result = GitPorcelainParser.parseAheadBehind("0\t0")
        XCTAssertEqual(result?.ahead, 0)
        XCTAssertEqual(result?.behind, 0)
    }

    func testParseAheadBehindInvalid() {
        XCTAssertNil(GitPorcelainParser.parseAheadBehind(""))
        XCTAssertNil(GitPorcelainParser.parseAheadBehind("not-a-number"))
    }

    // MARK: - Branch Verbose Parsing

    func testParseBranchesVerbose() {
        let output = """
        * main      abc1234 Fix login bug
          feature   def5678 Add new feature
        """
        let (names, details) = GitPorcelainParser.parseBranchesVerbose(output)
        XCTAssertEqual(names, ["main", "feature"])
        XCTAssertEqual(details["main"]?.lastCommitHash, "abc1234")
        XCTAssertEqual(details["main"]?.lastCommitMessage, "Fix login bug")
        XCTAssertEqual(details["feature"]?.lastCommitHash, "def5678")
    }

    func testParseBranchesVerboseSkipsDetachedHead() {
        let output = """
        * (HEAD detached at abc1234)
          main      abc1234 Fix login bug
        """
        let (names, details) = GitPorcelainParser.parseBranchesVerbose(output)
        XCTAssertEqual(names, ["main"])
        XCTAssertNil(details["(HEAD"])
    }

    // MARK: - Diff Stats Parsing

    func testParseDiffNumstat() {
        let unstaged = "12\t3\tsrc/main.swift\n5\t0\tREADME.md"
        let staged = "2\t1\tsrc/main.swift"
        let stats = GitPorcelainParser.parseDiffNumstat(unstaged, staged)
        XCTAssertEqual(stats["src/main.swift"]?.additions, 14) // 12 + 2
        XCTAssertEqual(stats["src/main.swift"]?.deletions, 4) // 3 + 1
        XCTAssertEqual(stats["README.md"]?.additions, 5)
        XCTAssertEqual(stats["README.md"]?.deletions, 0)
    }

    func testParseDiffNumstatEmpty() {
        let stats = GitPorcelainParser.parseDiffNumstat("", "")
        XCTAssertTrue(stats.isEmpty)
    }

    func testParseDiffNumstatSkipsBinaryDashes() {
        // Binary files report "-\t-\tpath"; Int conversion fails and the row is skipped.
        let stats = GitPorcelainParser.parseDiffNumstat("-\t-\tlogo.png", "")
        XCTAssertTrue(stats.isEmpty)
    }
}
