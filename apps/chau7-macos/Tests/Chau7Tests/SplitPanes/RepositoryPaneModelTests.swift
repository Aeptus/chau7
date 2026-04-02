import XCTest
@testable import Chau7

final class RepositoryPaneModelTests: XCTestCase {

    // MARK: - Status Parsing

    func testParseStatusEmpty() {
        let result = RepositoryPaneModel.parseStatus("")
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.unstaged.isEmpty)
        XCTAssertTrue(result.untracked.isEmpty)
        XCTAssertTrue(result.conflicted.isEmpty)
    }

    func testParseStatusStagedModified() {
        let output = "M  src/main.swift"
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.staged[0].path, "src/main.swift")
        XCTAssertEqual(result.staged[0].changeType, .modified)
        XCTAssertTrue(result.unstaged.isEmpty)
    }

    func testParseStatusUnstagedModified() {
        let output = " M src/main.swift"
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertEqual(result.unstaged.count, 1)
        XCTAssertEqual(result.unstaged[0].path, "src/main.swift")
    }

    func testParseStatusBothStagedAndUnstaged() {
        let output = "MM src/main.swift"
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.unstaged.count, 1)
        XCTAssertEqual(result.staged[0].path, "src/main.swift")
        XCTAssertEqual(result.unstaged[0].path, "src/main.swift")
    }

    func testParseStatusUntracked() {
        let output = "?? newfile.txt"
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.unstaged.isEmpty)
        XCTAssertEqual(result.untracked, ["newfile.txt"])
    }

    func testParseStatusAdded() {
        let output = "A  src/new.swift"
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.staged[0].changeType, .added)
    }

    func testParseStatusDeleted() {
        let output = "D  src/old.swift"
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.staged[0].changeType, .deleted)
    }

    func testParseStatusRenamed() {
        let output = "R  old.swift -> new.swift"
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertEqual(result.staged.count, 1)
        XCTAssertEqual(result.staged[0].path, "new.swift")
        XCTAssertEqual(result.staged[0].changeType, .renamed)
    }

    func testParseStatusConflict() {
        let output = "UU src/conflict.swift"
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.unstaged.isEmpty)
        XCTAssertEqual(result.conflicted, ["src/conflict.swift"])
    }

    func testParseStatusConflictBothAdded() {
        let output = "AA src/both-added.swift"
        let result = RepositoryPaneModel.parseStatus(output)
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
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertEqual(result.staged.count, 3) // M, A, D
        XCTAssertEqual(result.unstaged.count, 1)
        XCTAssertEqual(result.untracked.count, 1)
        XCTAssertEqual(result.conflicted.count, 1)
    }

    // MARK: - Branch Parsing

    func testParseBranches() {
        let output = """
          develop
        * main
          feature/login
        """
        let branches = RepositoryPaneModel.parseBranches(output)
        XCTAssertEqual(branches, ["develop", "main", "feature/login"])
    }

    func testParseBranchesEmpty() {
        XCTAssertTrue(RepositoryPaneModel.parseBranches("").isEmpty)
    }

    func testParseRemoteBranches() {
        let output = """
          origin/HEAD -> origin/main
          origin/main
          origin/develop
        """
        let branches = RepositoryPaneModel.parseRemoteBranches(output)
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
        let commits = RepositoryPaneModel.parseCommitLog(output)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].shortHash, "abc123d")
        XCTAssertEqual(commits[0].message, "Fix login bug")
        XCTAssertEqual(commits[0].author, "John Doe")
        XCTAssertEqual(commits[1].shortHash, "def789a")
        XCTAssertEqual(commits[1].message, "Add new feature")
    }

    func testParseCommitLogEmpty() {
        XCTAssertTrue(RepositoryPaneModel.parseCommitLog("").isEmpty)
    }

    // MARK: - Stash Parsing

    func testParseStashList() {
        let output = """
        stash@{0}: WIP on main: abc1234 some work
        stash@{1}: On develop: saving progress
        """
        let stashes = RepositoryPaneModel.parseStashList(output)
        XCTAssertEqual(stashes.count, 2)
        XCTAssertEqual(stashes[0].index, 0)
        XCTAssertTrue(stashes[0].description.contains("WIP"))
        XCTAssertEqual(stashes[1].index, 1)
    }

    func testParseStashListEmpty() {
        XCTAssertTrue(RepositoryPaneModel.parseStashList("").isEmpty)
    }

    // MARK: - Write Operations (with mock runner)

    func testCommitEmptyMessageFails() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.directory = "/tmp/test"
        model.commitMessage = "   "
        model.commit()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.lastError, "Commit message cannot be empty.")
    }

    func testCreateBranchEmptyNameFails() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.directory = "/tmp/test"
        model.createBranch("  ")
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.lastError, "Branch name cannot be empty.")
    }

    func testRepoNameFromDirectory() {
        let model = RepositoryPaneModel()
        model.load(directory: "/Users/me/projects/MyApp")
        XCTAssertEqual(model.repoName, "MyApp")
    }
}
