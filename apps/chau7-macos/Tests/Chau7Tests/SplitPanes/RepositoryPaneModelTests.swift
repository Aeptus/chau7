import XCTest
@testable import Chau7
@testable import Chau7Core

final class RepositoryPaneModelTests: XCTestCase {

    // MARK: - Parser Shims

    //
    // The pure parser bodies moved to `Chau7Core.GitPorcelainParser` and are
    // tested exhaustively in `Core/GitPorcelainParserTests`. The tests below
    // cover only what the model's forwarding shims add: mapping the Core
    // result types onto the pane-facing UI types (FileStatus/FileChangeType,
    // CommitEntry with a localized relative date, StashEntry, BranchDetail,
    // DiffStat).

    func testParseStatusShimMapsCoreEntriesOntoFileStatus() {
        let output = """
        M  staged.swift
         M unstaged.swift
        ?? untracked.txt
        A  added.swift
        R  old.swift -> new.swift
        UU conflicted.swift
        """
        let result = RepositoryPaneModel.parseStatus(output)
        XCTAssertEqual(result.staged.map(\.path), ["staged.swift", "added.swift", "new.swift"])
        XCTAssertEqual(result.staged.map(\.changeType), [.modified, .added, .renamed])
        XCTAssertEqual(result.staged[0].indexStatus, "M")
        XCTAssertEqual(result.staged[0].workTreeStatus, " ")
        XCTAssertEqual(result.unstaged.map(\.path), ["unstaged.swift"])
        XCTAssertEqual(result.untracked, ["untracked.txt"])
        XCTAssertEqual(result.conflicted, ["conflicted.swift"])
    }

    func testParseCommitLogShimRendersLocalizedRelativeDate() {
        let output = """
        abc123def456
        abc123d
        Fix login bug
        John Doe
        2026-04-01T12:00:00Z
        """
        let commits = RepositoryPaneModel.parseCommitLog(output)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].shortHash, "abc123d")
        XCTAssertEqual(commits[0].message, "Fix login bug")
        XCTAssertEqual(commits[0].author, "John Doe")
        // The Core parser leaves dateString to the injected renderer; the
        // shim must inject the app's localized relative-date formatting.
        XCTAssertFalse(commits[0].dateString.isEmpty)
    }

    func testParseStashListShimMapsBranchAndDescription() {
        let stashes = RepositoryPaneModel.parseStashList("stash@{0}: WIP on main: abc1234 some work")
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].index, 0)
        XCTAssertEqual(stashes[0].branch, "main")
        XCTAssertTrue(stashes[0].description.contains("WIP"))
    }

    func testParseBranchesVerboseShimMapsBranchDetail() {
        let (names, details) = RepositoryPaneModel.parseBranchesVerbose("* main      abc1234 Fix login bug")
        XCTAssertEqual(names, ["main"])
        XCTAssertEqual(details["main"]?.lastCommitHash, "abc1234")
        XCTAssertEqual(details["main"]?.lastCommitMessage, "Fix login bug")
    }

    func testParseDiffNumstatShimMapsDiffStat() {
        let stats = RepositoryPaneModel.parseDiffNumstat("12\t3\tsrc/main.swift", "2\t1\tsrc/main.swift")
        XCTAssertEqual(stats["src/main.swift"]?.additions, 14)
        XCTAssertEqual(stats["src/main.swift"]?.deletions, 4)
    }

    // MARK: - Write Operations (with mock runner)

    func testCommitEmptyMessageFails() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.directory = "/tmp/test"
        model.commit.message = "   "
        model.performCommit()
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

    // MARK: - Conventional Commit Prefixes

    func testApplyPrefix() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.commit.message = "add login"
        model.applyPrefix("feat")
        XCTAssertEqual(model.commit.message, "feat: add login")
    }

    func testApplyPrefixDoesNotDouble() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.commit.message = "feat: add login"
        model.applyPrefix("feat")
        XCTAssertEqual(model.commit.message, "feat: add login")
    }

    func testHasConventionalPrefix() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        model.commit.message = "fix: crash on launch"
        XCTAssertTrue(model.hasConventionalPrefix)
        model.commit.message = "just a message"
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
        model.history.commits = RepositoryPaneModel.parseCommitLog(logOutput)
        XCTAssertEqual(model.history.filteredCommits.count, 2)

        model.history.historySearchText = "login"
        XCTAssertEqual(model.history.filteredCommits.count, 1)
        XCTAssertEqual(model.history.filteredCommits[0].message, "Fix login bug")

        model.history.historySearchText = "jane"
        XCTAssertEqual(model.history.filteredCommits.count, 1)
        XCTAssertEqual(model.history.filteredCommits[0].author, "Jane Smith")

        model.history.historySearchText = ""
        XCTAssertEqual(model.history.filteredCommits.count, 2)
    }

    // MARK: - Session File Partitioning

    func testSessionFilePartitioning() {
        let model = RepositoryPaneModel(
            gitRunner: { _, _ in "" },
            gitRunnerWithStatus: { _, _ in GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0) }
        )
        // Simulate git status
        model.status.stagedFiles = [
            FileStatus(path: "src/main.swift", changeType: .modified, indexStatus: "M", workTreeStatus: " "),
            FileStatus(path: "package.json", changeType: .modified, indexStatus: "M", workTreeStatus: " ")
        ]
        model.status.unstagedFiles = [
            FileStatus(path: "tests/test.swift", changeType: .modified, indexStatus: " ", workTreeStatus: "M")
        ]
        // Simulate agent touched files
        model.session.sessionTouchedFiles = ["src/main.swift", "tests/test.swift"]

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
        model.session.sessionTouchedFiles = ["a.swift", "b.swift"]
        model.session.turnSummary = TurnSummaryInfo(
            turnCount: 1, toolsUsed: [:], totalTokens: 0,
            inputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0,
            costEstimateUSD: nil, averageTokensPerTurn: nil, activeDuration: nil, exitReason: nil,
            backendName: "claude", sessionState: .ready, duration: nil
        )

        model.resetSessionTracking()

        XCTAssertTrue(model.session.sessionTouchedFiles.isEmpty)
        XCTAssertNil(model.session.turnSummary)
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
        waitUntil(timeout: 1.0) { !model.status.unstagedFiles.isEmpty }

        XCTAssertEqual(requestedAction, "refresh repository status")
        XCTAssertEqual(model.status.unstagedFiles.map(\.path), ["src/main.swift"])
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
        // The tracker attributes a block to the latest turn whose timestamp <= block.endTime.
        // We need t2's timestamp strictly greater than firstTurnTime so the block
        // (endTime = firstTurnTime) is routed to t1, not t2. Date() has microsecond
        // resolution on macOS, so wait only as long as needed for the clock to advance
        // rather than a fixed sleep.
        while Date() <= firstTurnTime {}
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
