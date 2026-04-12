import XCTest
@testable import Chau7
@testable import Chau7Core

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

    // MARK: - Ahead/Behind Parsing

    func testParseAheadBehind() {
        let result = RepositoryPaneModel.parseAheadBehind("3\t5")
        XCTAssertEqual(result?.ahead, 5)
        XCTAssertEqual(result?.behind, 3)
    }

    func testParseAheadBehindZero() {
        let result = RepositoryPaneModel.parseAheadBehind("0\t0")
        XCTAssertEqual(result?.ahead, 0)
        XCTAssertEqual(result?.behind, 0)
    }

    func testParseAheadBehindInvalid() {
        XCTAssertNil(RepositoryPaneModel.parseAheadBehind(""))
        XCTAssertNil(RepositoryPaneModel.parseAheadBehind("not-a-number"))
    }

    // MARK: - Branch Verbose Parsing

    func testParseBranchesVerbose() {
        let output = """
        * main      abc1234 Fix login bug
          feature   def5678 Add new feature
        """
        let (names, details) = RepositoryPaneModel.parseBranchesVerbose(output)
        XCTAssertEqual(names, ["main", "feature"])
        XCTAssertEqual(details["main"]?.lastCommitHash, "abc1234")
        XCTAssertEqual(details["main"]?.lastCommitMessage, "Fix login bug")
        XCTAssertEqual(details["feature"]?.lastCommitHash, "def5678")
    }

    // MARK: - Stash Branch Parsing

    func testParseStashBranch() {
        let output = "stash@{0}: WIP on main: abc1234 some work"
        let stashes = RepositoryPaneModel.parseStashList(output)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].branch, "main")
    }

    func testParseStashBranchOnPrefix() {
        let output = "stash@{0}: On develop: saving progress"
        let stashes = RepositoryPaneModel.parseStashList(output)
        XCTAssertEqual(stashes[0].branch, "develop")
    }

    // MARK: - Conventional Commit Prefixes

    func testApplyPrefix() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.commitMessage = "add login"
        model.applyPrefix("feat")
        XCTAssertEqual(model.commitMessage, "feat: add login")
    }

    func testApplyPrefixDoesNotDouble() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.commitMessage = "feat: add login"
        model.applyPrefix("feat")
        XCTAssertEqual(model.commitMessage, "feat: add login")
    }

    func testHasConventionalPrefix() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.commitMessage = "fix: crash on launch"
        XCTAssertTrue(model.hasConventionalPrefix)
        model.commitMessage = "just a message"
        XCTAssertFalse(model.hasConventionalPrefix)
    }

    // MARK: - History Search

    func testFilteredCommits() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        let logOutput = """
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
        // Manually set commits (bypassing async)
        model.commits = RepositoryPaneModel.parseCommitLog(logOutput)
        XCTAssertEqual(model.filteredCommits.count, 2)

        model.historySearchText = "login"
        XCTAssertEqual(model.filteredCommits.count, 1)
        XCTAssertEqual(model.filteredCommits[0].message, "Fix login bug")

        model.historySearchText = "jane"
        XCTAssertEqual(model.filteredCommits.count, 1)
        XCTAssertEqual(model.filteredCommits[0].author, "Jane Smith")

        model.historySearchText = ""
        XCTAssertEqual(model.filteredCommits.count, 2)
    }

    // MARK: - Diff Stats Parsing

    func testParseDiffNumstat() {
        let unstaged = "12\t3\tsrc/main.swift\n5\t0\tREADME.md"
        let staged = "2\t1\tsrc/main.swift"
        let stats = RepositoryPaneModel.parseDiffNumstat(unstaged, staged)
        XCTAssertEqual(stats["src/main.swift"]?.additions, 14) // 12 + 2
        XCTAssertEqual(stats["src/main.swift"]?.deletions, 4) // 3 + 1
        XCTAssertEqual(stats["README.md"]?.additions, 5)
        XCTAssertEqual(stats["README.md"]?.deletions, 0)
    }

    func testParseDiffNumstatEmpty() {
        let stats = RepositoryPaneModel.parseDiffNumstat("", "")
        XCTAssertTrue(stats.isEmpty)
    }

    // MARK: - Session File Partitioning

    func testSessionFilePartitioning() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        // Simulate git status
        model.stagedFiles = [
            FileStatus(path: "src/main.swift", changeType: .modified, indexStatus: "M", workTreeStatus: " "),
            FileStatus(path: "package.json", changeType: .modified, indexStatus: "M", workTreeStatus: " ")
        ]
        model.unstagedFiles = [
            FileStatus(path: "tests/test.swift", changeType: .modified, indexStatus: " ", workTreeStatus: "M")
        ]
        // Simulate agent touched files
        model.sessionTouchedFiles = ["src/main.swift", "tests/test.swift"]

        XCTAssertEqual(model.sessionStagedFiles.count, 1)
        XCTAssertEqual(model.sessionStagedFiles[0].path, "src/main.swift")
        XCTAssertEqual(model.sessionUnstagedFiles.count, 1)
        XCTAssertEqual(model.sessionUnstagedFiles[0].path, "tests/test.swift")
        XCTAssertEqual(model.otherStagedFiles.count, 1)
        XCTAssertEqual(model.otherStagedFiles[0].path, "package.json")
        XCTAssertEqual(model.sessionChangeCount, 2)
        XCTAssertEqual(model.otherChangeCount, 1)
    }

    // MARK: - Turn Summary

    func testTurnSummaryFormatting() {
        let summary = TurnSummaryInfo(
            turnCount: 3,
            toolsUsed: ["Edit": 2, "Write": 1],
            totalTokens: 45200,
            inputTokens: 33000,
            outputTokens: 12200,
            reasoningOutputTokens: 900,
            costEstimateUSD: 1.234,
            averageTokensPerTurn: 15066.7,
            activeDuration: 120,
            exitReason: nil,
            backendName: "claude",
            sessionState: .ready,
            duration: 154
        )
        XCTAssertEqual(summary.formattedTokens, "45.2k")
        XCTAssertEqual(summary.formattedDuration, "2m 34s")
        XCTAssertEqual(summary.formattedActiveDuration, "2m 0s")
        XCTAssertEqual(summary.formattedAverageTokensPerTurn, "15.1k")
        XCTAssertEqual(summary.formattedCostEstimate, LocalizedFormatters.formatCostPrecise(1.234))
    }

    func testPushResetsSessionTracking() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.sessionTouchedFiles = ["a.swift", "b.swift"]
        model.turnSummary = TurnSummaryInfo(
            turnCount: 1, toolsUsed: [:], totalTokens: 0,
            inputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0,
            costEstimateUSD: nil, averageTokensPerTurn: nil, activeDuration: nil, exitReason: nil,
            backendName: "claude", sessionState: .ready, duration: nil
        )

        model.resetSessionTracking()

        XCTAssertTrue(model.sessionTouchedFiles.isEmpty)
        XCTAssertNil(model.turnSummary)
    }

    func testBuildTurnSummaryUsesCompletedTurnSnapshotWhenSessionIsIdle() throws {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(
                directory: "/tmp/repository-turn-summary",
                provider: "claude",
                model: "claude-sonnet-4"
            )
        )

        session.transition(.backendReady)
        _ = try XCTUnwrap(session.startTurn(prompt: "Hello"))
        session.recordToolUse(name: "Edit", file: "Sources/App.swift")
        session.addTokens(input: 100, output: 25, cacheCreation: 10, cacheRead: 5, reasoningOutput: 3)
        _ = try XCTUnwrap(session.completeTurn(summary: "done", terminalOutput: nil))

        let summary = RepositoryPaneModel.buildTurnSummary(from: session)

        XCTAssertEqual(summary.turnCount, 1)
        XCTAssertEqual(summary.inputTokens, 100)
        XCTAssertEqual(summary.outputTokens, 25)
        XCTAssertEqual(summary.reasoningOutputTokens, 3)
        XCTAssertEqual(summary.toolsUsed["Edit"], 1)
        XCTAssertEqual(summary.exitReason, .success)
        XCTAssertNotNil(summary.duration)
        XCTAssertEqual(try XCTUnwrap(summary.costEstimateUSD), 0.000759, accuracy: 0.000001)
    }

    func testRefreshStatusRequestsProtectedAccessBeforeRunningGit() {
        let blockedSnapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: "/Users/me/Downloads",
            isProtectedPath: true,
            isFeatureEnabled: true,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: true
        )
        let grantedSnapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: "/Users/me/Downloads",
            isProtectedPath: true,
            isFeatureEnabled: true,
            hasActiveScope: true,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: true
        )
        let gitCalled = expectation(description: "git status called")
        var requestedAction: String?

        let model = RepositoryPaneModel(
            gitRunner: { args, directory in
                XCTAssertEqual(args, ["status", "--porcelain"])
                XCTAssertEqual(directory, "/Users/me/Downloads/Repositories/Chau7")
                gitCalled.fulfill()
                return " M src/main.swift"
            },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) },
            accessSnapshotProvider: { _ in blockedSnapshot },
            accessRequester: { path, actionDescription in
                requestedAction = actionDescription
                XCTAssertEqual(path, "/Users/me/Downloads/Repositories/Chau7")
                return grantedSnapshot
            }
        )
        model.directory = "/Users/me/Downloads/Repositories/Chau7"

        model.refreshStatus()

        wait(for: [gitCalled], timeout: 1.0)
        waitUntil(timeout: 1.0) { !model.unstagedFiles.isEmpty }

        XCTAssertEqual(requestedAction, "refresh repository status")
        XCTAssertEqual(model.unstagedFiles.map(\.path), ["src/main.swift"])
        XCTAssertTrue(model.protectedAccessSnapshot.canProbeLive)
        XCTAssertNil(model.lastError)
    }

    func testRefreshStatusLeavesPaneInIdentityOnlyModeWhenAccessIsDenied() {
        let blockedSnapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: "/Users/me/Downloads",
            isProtectedPath: true,
            isFeatureEnabled: true,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: true
        )
        var gitCallCount = 0

        let model = RepositoryPaneModel(
            gitRunner: { _, _ in
                gitCallCount += 1
                return ""
            },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) },
            accessSnapshotProvider: { _ in blockedSnapshot },
            accessRequester: { _, _ in blockedSnapshot }
        )
        model.directory = "/Users/me/Downloads/Repositories/Chau7"

        model.refreshStatus()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(gitCallCount, 0)
        XCTAssertEqual(
            model.lastError,
            "Grant Chau7 access to Downloads to refresh repository status."
        )
        XCTAssertFalse(model.protectedAccessSnapshot.canProbeLive)
        XCTAssertTrue(model.protectedAccessSnapshot.canUseKnownIdentity)
    }

    // MARK: - SessionFilesTracker

    func testSessionFilesTrackerNormalization() {
        let tracker = SessionFilesTracker()
        tracker.gitRoot = "/Users/me/projects/MyApp"

        // Simulate by adding directly via journal
        let journal = EventJournal(capacity: 100)
        journal.append(
            sessionID: "test",
            turnID: "t1",
            type: RuntimeEventType.toolUse.rawValue,
            data: ["tool": "Edit", "file": "/Users/me/projects/MyApp/src/main.swift"]
        )
        journal.append(
            sessionID: "test",
            turnID: "t1",
            type: RuntimeEventType.toolUse.rawValue,
            data: ["tool": "Write", "file": "tests/test.swift"] // already relative
        )
        journal.append(
            sessionID: "test",
            turnID: "t1",
            type: RuntimeEventType.toolResult.rawValue, // not a tool_use, should be skipped
            data: ["tool": "Edit"]
        )

        tracker.update(from: journal)

        XCTAssertEqual(tracker.touchedFiles, ["src/main.swift", "tests/test.swift"])
    }

    func testSessionFilesTrackerReset() {
        let tracker = SessionFilesTracker()
        let journal = EventJournal(capacity: 100)
        journal.append(
            sessionID: "test",
            turnID: "t1",
            type: RuntimeEventType.toolUse.rawValue,
            data: ["tool": "Edit", "file": "a.swift"]
        )
        tracker.update(from: journal)
        XCTAssertEqual(tracker.touchedFiles.count, 1)

        tracker.reset()
        XCTAssertTrue(tracker.touchedFiles.isEmpty)
    }

    func testSessionFilesTrackerIncrementalReads() {
        let tracker = SessionFilesTracker()
        let journal = EventJournal(capacity: 100)

        journal.append(
            sessionID: "test",
            turnID: "t1",
            type: RuntimeEventType.toolUse.rawValue,
            data: ["tool": "Edit", "file": "a.swift"]
        )
        tracker.update(from: journal)
        XCTAssertEqual(tracker.touchedFiles.count, 1)

        // Second update — only new events
        journal.append(
            sessionID: "test",
            turnID: "t2",
            type: RuntimeEventType.toolUse.rawValue,
            data: ["tool": "Write", "file": "b.swift"]
        )
        tracker.update(from: journal)
        XCTAssertEqual(tracker.touchedFiles, ["a.swift", "b.swift"])
    }

    func testSessionFilesTrackerTracksCurrentTurnAndTimeline() {
        let tracker = SessionFilesTracker()
        tracker.gitRoot = "/repo"
        let journal = EventJournal(capacity: 100)
        let timestamp = Date()

        journal.append(sessionID: "test", turnID: "t1", type: RuntimeEventType.turnStarted.rawValue)
        journal.append(
            sessionID: "test",
            turnID: "t1",
            type: RuntimeEventType.toolUse.rawValue,
            data: [
                "tool": "Edit",
                "file": "/repo/Sources/App.swift"
            ]
        )
        journal.append(sessionID: "test", turnID: "t2", type: RuntimeEventType.turnStarted.rawValue)
        journal.append(
            sessionID: "test",
            turnID: "t2",
            type: RuntimeEventType.toolUse.rawValue,
            data: [
                "tool": "Read",
                "file": "/repo/Tests/AppTests.swift"
            ]
        )

        tracker.update(from: journal)

        XCTAssertEqual(tracker.currentTurnID, "t2")
        XCTAssertEqual(tracker.currentTurnFiles, ["Tests/AppTests.swift"])
        XCTAssertEqual(tracker.filesByTurn["t1"], ["Sources/App.swift"])
        XCTAssertEqual(tracker.filesByTurn["t2"], ["Tests/AppTests.swift"])
        XCTAssertEqual(tracker.fileActions["Sources/App.swift"], [.modified])
        XCTAssertEqual(tracker.fileActions["Tests/AppTests.swift"], [.read])
        XCTAssertEqual(tracker.fileTimeline["Sources/App.swift"]?.count, 1)
        XCTAssertEqual(tracker.fileTimeline["Tests/AppTests.swift"]?.count, 1)
        XCTAssertTrue((tracker.fileTimeline["Tests/AppTests.swift"]?.first?.timestamp ?? .distantPast) >= timestamp.addingTimeInterval(-1))
    }

    func testSessionFilesTrackerMergesCommandBlockFallbackFiles() {
        let tracker = SessionFilesTracker()
        tracker.gitRoot = "/repo"
        let journal = EventJournal(capacity: 100)
        journal.append(sessionID: "test", turnID: "t1", type: RuntimeEventType.turnStarted.rawValue)

        var block = CommandBlock(command: "touch Sources/Generated.swift", startLine: 1, directory: "/repo")
        block.endLine = 3
        block.endTime = Date()
        block.exitCode = 0
        block.changedFiles = ["/repo/Sources/Generated.swift"]

        tracker.update(from: journal, commandBlocks: [block])

        XCTAssertEqual(tracker.touchedFiles, ["Sources/Generated.swift"])
        XCTAssertEqual(tracker.currentTurnFiles, ["Sources/Generated.swift"])
        XCTAssertEqual(tracker.fileActions["Sources/Generated.swift"], [.created])
    }

    func testSessionFilesTrackerAttributesFallbackBlockToNearestTurnStart() {
        let tracker = SessionFilesTracker()
        tracker.gitRoot = "/repo"
        let journal = EventJournal(capacity: 100)
        journal.append(sessionID: "test", turnID: "t1", type: RuntimeEventType.turnStarted.rawValue)
        let firstTurnTime = Date()
        usleep(10000)
        journal.append(sessionID: "test", turnID: "t2", type: RuntimeEventType.turnStarted.rawValue)

        var block = CommandBlock(command: "touch Sources/OldTurn.swift", startLine: 1, directory: "/repo")
        block.endLine = 2
        block.endTime = firstTurnTime
        block.exitCode = 0
        block.changedFiles = ["/repo/Sources/OldTurn.swift"]

        tracker.update(from: journal, commandBlocks: [block])

        XCTAssertEqual(tracker.filesByTurn["t1"], ["Sources/OldTurn.swift"])
        XCTAssertNil(tracker.filesByTurn["t2"])
    }

    func testSessionFilesTrackerDrainsLargeJournalBursts() {
        let tracker = SessionFilesTracker()
        let journal = EventJournal(capacity: 1200)
        for index in 0 ..< 650 {
            journal.append(
                sessionID: "test",
                turnID: "t\(index / 10)",
                type: RuntimeEventType.toolUse.rawValue,
                data: [
                    "tool": "Read",
                    "file": "Sources/File\(index).swift"
                ]
            )
        }

        tracker.update(from: journal)

        XCTAssertEqual(tracker.touchedFiles.count, 650)
        XCTAssertTrue(tracker.touchedFiles.contains("Sources/File649.swift"))
    }
}

private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}
