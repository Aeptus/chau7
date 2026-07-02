import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class TerminalSessionModelTests: XCTestCase {
    private func flushMainQueue() async {
        let expectation = expectation(description: "main queue flush")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 5.0)
    }

    /// Polls the main run loop until `condition` holds (or the timeout
    /// elapses) so tests don't depend on fixed asyncAfter delays.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Async sibling of `waitUntil` for `async` tests. `RunLoop.main.run` does
    /// not service `DispatchQueue.main.async` blocks when called from an
    /// `async` context (the main actor stays pinned), so polling work that
    /// hops through a background queue back to main must `await` instead —
    /// each `Task.sleep` suspends the actor so the queued main-thread blocks
    /// actually drain.
    private func waitUntilAsync(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - CommandStatus Enum

    func testCommandStatusRawValues() {
        XCTAssertEqual(CommandStatus.idle.rawValue, "idle")
        XCTAssertEqual(CommandStatus.done.rawValue, "done")
        XCTAssertEqual(CommandStatus.running.rawValue, "running")
        XCTAssertEqual(CommandStatus.waitingForInput.rawValue, "waitingForInput")
        XCTAssertEqual(CommandStatus.approvalRequired.rawValue, "approvalRequired")
        XCTAssertEqual(CommandStatus.stuck.rawValue, "stuck")
        XCTAssertEqual(CommandStatus.exited.rawValue, "exited")
    }

    func testCommandStatusCasesAreDistinct() {
        let all: [CommandStatus] = [.idle, .done, .running, .waitingForInput, .approvalRequired, .stuck, .exited]
        let rawValues = Set(all.map(\.rawValue))
        XCTAssertEqual(
            rawValues.count,
            all.count,
            "All CommandStatus cases should have unique raw values"
        )
    }

    func testShouldAutoRevealInteractivePromptWhenEnteringWaitingForInput() {
        XCTAssertTrue(
            TerminalSessionModel.shouldAutoRevealInteractivePrompt(
                from: .running,
                to: .waitingForInput
            )
        )
    }

    func testShouldAutoRevealInteractivePromptWhenEnteringApprovalRequired() {
        XCTAssertTrue(
            TerminalSessionModel.shouldAutoRevealInteractivePrompt(
                from: .running,
                to: .approvalRequired
            )
        )
    }

    func testShouldAutoRevealInteractivePromptIgnoresNonInteractiveTransitions() {
        XCTAssertFalse(
            TerminalSessionModel.shouldAutoRevealInteractivePrompt(
                from: .running,
                to: .running
            )
        )
        XCTAssertFalse(
            TerminalSessionModel.shouldAutoRevealInteractivePrompt(
                from: .waitingForInput,
                to: .done
            )
        )
    }

    func testRestoreAIMetadataCoercesPersistedInteractiveStatusesToIdle() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        for persistedStatus in [CommandStatus.waitingForInput, .approvalRequired, .stuck] {
            session.status = .running
            session.restoreAIMetadata(
                provider: "codex",
                sessionId: "session-\(persistedStatus.rawValue)",
                lastStatus: persistedStatus
            )

            XCTAssertEqual(
                session.status,
                .idle,
                "Persisted \(persistedStatus.rawValue) must not revive as a live interactive state on restore"
            )
        }
    }

    func testRestoreAIMetadataKeepsPersistedNonInteractiveStatuses() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        for persistedStatus in [CommandStatus.idle, .done, .running, .exited] {
            session.status = .idle
            session.restoreAIMetadata(
                provider: "codex",
                sessionId: "session-\(persistedStatus.rawValue)",
                lastStatus: persistedStatus
            )

            XCTAssertEqual(session.status, persistedStatus)
        }
    }

    // MARK: - Background Live Rendering

    func testShouldKeepLiveRenderingInBackgroundRequiresActiveAIApp() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.status = .running
        session.lastOutputAt = Date()

        XCTAssertFalse(session.shouldKeepLiveRenderingInBackground)
    }

    func testShouldKeepLiveRenderingInBackgroundPinsRestoreBootstrap() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.activeAppName = "Codex"
        session.status = .idle
        session.lastOutputAt = Date.distantPast
        session.lastInputAt = Date.distantPast
        session.restoreBootstrapPhase = .replaying

        XCTAssertTrue(session.shouldKeepLiveRenderingInBackground)
    }

    func testShouldKeepLiveRenderingInBackgroundPinsWaitingForInput() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.activeAppName = "Codex"
        session.status = .waitingForInput
        session.lastOutputAt = Date.distantPast
        session.lastInputAt = Date.distantPast

        XCTAssertTrue(session.shouldKeepLiveRenderingInBackground)
    }

    func testBackgroundLiveRenderReasonsIncludeRestoreBootstrapAndApproval() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.activeAppName = "Codex"
        session.status = .approvalRequired
        session.restoreBootstrapPhase = .replaying

        XCTAssertEqual(session.backgroundLiveRenderReasons(), ["restoreBootstrap", "approvalRequired"])
    }

    func testShouldKeepLiveRenderingInBackgroundPinsRunningAITabUntilCompletion() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.activeAppName = "Codex"
        session.status = .running
        session.lastOutputAt = Date(timeIntervalSinceNow: -120)
        session.lastInputAt = Date(timeIntervalSinceNow: -120)

        XCTAssertTrue(session.shouldKeepLiveRenderingInBackground)
    }

    func testShouldKeepLiveRenderingInBackgroundReportsRunningReasonAndLastActivityAge() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.activeAppName = "Codex"
        session.status = .running
        session.lastOutputAt = Date(timeIntervalSinceNow: -3)
        session.lastInputAt = Date(timeIntervalSinceNow: -3)

        let reasons = session.backgroundLiveRenderReasons(now: Date())

        XCTAssertEqual(reasons.count, 2)
        XCTAssertEqual(reasons.first, "running")
        XCTAssertTrue(reasons[1].hasPrefix("lastActivity="))
    }

    func testShouldKeepLiveRenderingInBackgroundCoolsIdleAITabEvenWithRecentActivity() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.activeAppName = "Codex"
        session.status = .idle
        session.lastOutputAt = Date()
        session.lastInputAt = Date()

        XCTAssertFalse(session.shouldKeepLiveRenderingInBackground)
    }

    func testAttachTerminalContainerTracksCurrentMountedContainer() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let rustView = RustTerminalView(frame: .zero)
        let container = UnifiedTerminalContainerView(rustView: rustView)

        session.attachTerminalContainer(container)
        session.attachRustTerminal(rustView)

        XCTAssertTrue(session.existingTerminalContainerView === container)
        XCTAssertTrue(session.existingRustTerminalView === rustView)
    }

    // MARK: - resolveStartDirectory (static, pure)

    func testResolveStartDirectoryWithAbsolutePath() {
        let result = TerminalSessionModel.resolveStartDirectory("/tmp")
        XCTAssertEqual(
            result,
            "/tmp",
            "Absolute paths should be returned as-is (after standardization)"
        )
    }

    func testResolveStartDirectoryWithTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = TerminalSessionModel.resolveStartDirectory("~")
        XCTAssertEqual(
            result,
            home,
            "Tilde should expand to the user's home directory"
        )
    }

    func testResolveStartDirectoryWithTildeSubpath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = TerminalSessionModel.resolveStartDirectory("~/Documents")
        let expected = (home as NSString).appendingPathComponent("Documents")
        XCTAssertEqual(
            result,
            expected,
            "~/Documents should expand to home/Documents"
        )
    }

    func testResolveStartDirectoryWithEmptyString() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = TerminalSessionModel.resolveStartDirectory("")
        XCTAssertEqual(
            result,
            home,
            "Empty string should resolve to home directory"
        )
    }

    func testResolveStartDirectoryWithWhitespace() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = TerminalSessionModel.resolveStartDirectory("   ")
        XCTAssertEqual(
            result,
            home,
            "Whitespace-only string should resolve to home directory"
        )
    }

    func testResolveStartDirectoryWithRelativePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = TerminalSessionModel.resolveStartDirectory("Desktop")
        let expected = URL(fileURLWithPath: (home as NSString).appendingPathComponent("Desktop")).standardized.path
        XCTAssertEqual(
            result,
            expected,
            "Relative path should be resolved against home directory"
        )
    }

    func testResolveStartDirectoryStandardizesPath() {
        // Paths with .. components should be standardized
        let result = TerminalSessionModel.resolveStartDirectory("/tmp/../tmp")
        XCTAssertEqual(
            result,
            "/tmp",
            "Paths with .. should be standardized"
        )
    }

    func testResolveStartDirectoryWithDotDot() {
        let result = TerminalSessionModel.resolveStartDirectory("/usr/local/..")
        XCTAssertEqual(
            result,
            "/usr",
            "Path with trailing .. should resolve to parent"
        )
    }

    // MARK: - defaultStartDirectory

    func testDefaultStartDirectoryReturnsNonEmpty() {
        let result = TerminalSessionModel.defaultStartDirectory()
        XCTAssertFalse(
            result.isEmpty,
            "Default start directory should never be empty"
        )
    }

    func testDefaultStartDirectoryIsAbsolute() {
        let result = TerminalSessionModel.defaultStartDirectory()
        XCTAssertTrue(
            result.hasPrefix("/"),
            "Default start directory should be an absolute path"
        )
    }

    // MARK: - LagKind Enum

    func testLagKindAllCases() {
        let all = TerminalSessionModel.LagKind.allCases
        XCTAssertEqual(all.count, 3, "LagKind should have 3 cases")
        XCTAssertTrue(all.contains(.input))
        XCTAssertTrue(all.contains(.output))
        XCTAssertTrue(all.contains(.scan))
    }

    func testLagKindRawValues() {
        XCTAssertEqual(TerminalSessionModel.LagKind.input.rawValue, "input")
        XCTAssertEqual(TerminalSessionModel.LagKind.output.rawValue, "output")
        XCTAssertEqual(TerminalSessionModel.LagKind.scan.rawValue, "scan")
    }

    // MARK: - LagEvent

    func testLagEventEquatable() {
        let event1 = TerminalSessionModel.LagEvent(
            kind: .input, elapsedMs: 10, averageMs: 8,
            p50: 7, p95: 15, sampleCount: 100,
            timestamp: Date(), tabTitle: "Shell", appName: "", cwd: "/tmp"
        )
        // Each LagEvent has a unique UUID, so two separately created events should not be equal
        let event2 = TerminalSessionModel.LagEvent(
            kind: .input, elapsedMs: 10, averageMs: 8,
            p50: 7, p95: 15, sampleCount: 100,
            timestamp: event1.timestamp, tabTitle: "Shell", appName: "", cwd: "/tmp"
        )
        XCTAssertNotEqual(
            event1,
            event2,
            "LagEvents should not be equal because they have distinct UUIDs"
        )
        XCTAssertEqual(
            event1,
            event1,
            "A LagEvent should be equal to itself"
        )
    }

    func testLagEventIdentifiable() {
        let event = TerminalSessionModel.LagEvent(
            kind: .output, elapsedMs: 50, averageMs: 40,
            p50: nil, p95: nil, sampleCount: 5,
            timestamp: Date(), tabTitle: "Test", appName: "Claude", cwd: "~"
        )
        // Identifiable requires a non-nil id
        XCTAssertNotNil(event.id, "LagEvent should have a non-nil id")
    }

    // MARK: - Restore Prefill Readiness

    func testIsPrefillReadyAllowsPromptEvenIfStatusIsRunning() {
        XCTAssertTrue(
            TerminalSessionModel.isPrefillReady(
                isShellLoading: false,
                isAtPrompt: true,
                hasView: true,
                status: .running
            )
        )
    }

    func testIsPrefillReadyRejectsExitedSession() {
        XCTAssertFalse(
            TerminalSessionModel.isPrefillReady(
                isShellLoading: false,
                isAtPrompt: true,
                hasView: true,
                status: .exited
            )
        )
    }

    // MARK: - Session Property Defaults (requires AppModel)

    /// Verify defaults on a freshly created session.
    /// This test needs AppModel, which is part of Chau7 (not Chau7Core).
    func testSessionPropertyDefaults() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        XCTAssertEqual(
            session.title,
            "Shell",
            "Default title should be 'Shell'"
        )
        XCTAssertEqual(
            session.status,
            .idle,
            "Default status should be .idle"
        )
        XCTAssertFalse(
            session.isGitRepo,
            "Default isGitRepo should be false"
        )
        XCTAssertNil(
            session.gitBranch,
            "Default gitBranch should be nil"
        )
        XCTAssertNil(
            session.gitRootPath,
            "Default gitRootPath should be nil"
        )
        XCTAssertNil(
            session.activeAppName,
            "Default activeAppName should be nil"
        )
        XCTAssertNil(
            session.devServer,
            "Default devServer should be nil"
        )
        XCTAssertNil(
            session.tabTitleOverride,
            "Default tabTitleOverride should be nil"
        )
        XCTAssertTrue(
            session.searchMatches.isEmpty,
            "Default searchMatches should be empty"
        )
        XCTAssertEqual(
            session.activeSearchIndex,
            0,
            "Default activeSearchIndex should be 0"
        )
        XCTAssertTrue(
            session.isAtPrompt,
            "Default isAtPrompt should be true"
        )
        XCTAssertTrue(
            session.lagTimeline.isEmpty,
            "Default lagTimeline should be empty"
        )
        XCTAssertFalse(
            session.repositoryAccessSnapshot.canUseKnownIdentity,
            "Default repository access snapshot should be unprotected"
        )
    }

    // MARK: - Repository AccessLevel lifecycle

    func testRepositoryStateFromCachedModel() {
        let snapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: "/Users/me/Downloads",
            isProtectedPath: true,
            isFeatureEnabled: false,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: true
        )
        let model = RepositoryModel(
            rootPath: "/Users/me/Downloads/Repositories/Chau7",
            branch: "feature/cached",
            accessLevel: .cached
        )

        let state = TerminalSessionModel.repositoryState(
            from: .repository(model, access: snapshot)
        )

        XCTAssertTrue(state.isGitRepo)
        XCTAssertEqual(state.gitRootPath, model.rootPath)
        XCTAssertEqual(state.gitBranch, "feature/cached")
        XCTAssertFalse(state.accessSnapshot.canProbeLive)
    }

    func testRepositoryStateFromLiveModel() {
        let snapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: nil,
            isProtectedPath: false,
            isFeatureEnabled: false,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: false
        )
        let model = RepositoryModel(
            rootPath: "/Users/me/Code/MyProject",
            branch: "main",
            accessLevel: .live
        )

        let state = TerminalSessionModel.repositoryState(
            from: .repository(model, access: snapshot)
        )

        XCTAssertTrue(state.isGitRepo)
        XCTAssertEqual(state.gitBranch, "main")
        XCTAssertTrue(state.accessSnapshot.canProbeLive)
    }

    func testNotRepositoryStateSnapshotDoesNotClaimGitRepo() {
        // Validates that a .notRepository result produces the correct snapshot.
        // The actual generation-counter race guard (stale init completion arriving
        // after a restore completion) is exercised by the integration test
        // testRestoreProtectedRepoUsesPersistedKnownRepoIdentity in OverlayTabsModelTests.
        let notRepoSnapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: nil,
            isProtectedPath: false,
            isFeatureEnabled: false,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: false
        )
        let state = TerminalSessionModel.repositoryState(
            from: .notRepository(access: notRepoSnapshot)
        )

        XCTAssertFalse(state.isGitRepo)
        XCTAssertNil(state.gitRootPath)
        XCTAssertNil(state.gitBranch)
    }

    func testRepositoryStateKeepsKnownIdentityWhenLiveAccessIsBlocked() {
        let snapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: "/Users/me/Downloads",
            isProtectedPath: true,
            isFeatureEnabled: false,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: true
        )
        let model = RepositoryModel(
            rootPath: "/Users/me/Downloads/Repositories/Chau7",
            branch: "main",
            accessLevel: .cached
        )

        let state = TerminalSessionModel.repositoryState(
            from: .repository(model, access: snapshot)
        )

        XCTAssertTrue(state.isGitRepo)
        XCTAssertEqual(state.gitRootPath, model.rootPath)
        XCTAssertEqual(state.gitBranch, "main")
        XCTAssertFalse(state.accessSnapshot.canProbeLive)
        XCTAssertTrue(state.accessSnapshot.canUseKnownIdentity)
    }

    func testRepositoryStateDropsIdentityWhenRepositoryIsActuallyUnavailable() {
        let snapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: nil,
            isProtectedPath: false,
            isFeatureEnabled: false,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: false
        )

        let state = TerminalSessionModel.repositoryState(from: .notRepository(access: snapshot))

        XCTAssertFalse(state.isGitRepo)
        XCTAssertNil(state.gitRootPath)
        XCTAssertNil(state.gitBranch)
        XCTAssertTrue(state.accessSnapshot.canProbeLive)
    }

    func testDisplayPropertiesReflectCachedModel() {
        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/Chau7"

        // Simulate a cached model (protected path, no live git access)
        let repoModel = RepositoryModel(
            rootPath: repoRoot,
            branch: "feature/protected",
            accessLevel: .cached
        )
        session.repositoryModel = repoModel
        session.isGitRepo = true
        session.gitRootPath = repoRoot
        session.gitBranch = "feature/protected"

        XCTAssertTrue(session.hasRepositoryIdentity)
        XCTAssertEqual(session.displayGitRootPath, repoRoot)
        XCTAssertEqual(session.displayGitBranch, "feature/protected")
        XCTAssertEqual(session.tabPathDisplayName(), "Chau7")
    }

    func testDisplayPropertiesReflectLiveModel() {
        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/Chau7"

        // Simulate a live model (full git access)
        let repoModel = RepositoryModel(
            rootPath: repoRoot,
            branch: "feature/live",
            accessLevel: .live
        )
        session.repositoryModel = repoModel
        session.isGitRepo = true
        session.gitRootPath = repoRoot
        session.gitBranch = "feature/live"

        XCTAssertTrue(session.hasRepositoryIdentity)
        XCTAssertEqual(session.displayGitRootPath, repoRoot)
        XCTAssertEqual(session.displayGitBranch, "feature/live")
    }

    func testDisplayBranchFallsBackToIdentityStoreWhenModelBranchIsNil() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/Chau7"

        // Identity store has a branch, but the model does not
        KnownRepoIdentityStore.shared.reset()
        KnownRepoIdentityStore.shared.record(rootPath: repoRoot, branch: "feature/from-store")

        session.currentDirectory = repoRoot + "/apps/chau7-macos"
        session.isGitRepo = true
        session.gitRootPath = repoRoot
        session.gitBranch = nil // model had no branch

        XCTAssertTrue(session.hasRepositoryIdentity)
        XCTAssertEqual(session.displayGitRootPath, repoRoot)
        XCTAssertEqual(
            session.displayGitBranch,
            "feature/from-store",
            "Should fall back to identity store when model branch is nil"
        )
    }

    // MARK: - Shell integration OSC reports

    func testHandleShellRepoRootReportPopulatesUnknownRepo() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }
        KnownRepoIdentityStore.shared.reset()

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/brand-new-repo"

        // Simulate the protected-path .blocked resolve: session thinks it's not a repo.
        session.currentDirectory = repoRoot + "/src"
        session.isGitRepo = false
        session.gitRootPath = nil
        session.gitBranch = nil
        session.repositoryModel = nil

        // Shell reports the repo root via OSC 9.
        session.handleShellRepoRootReport(repoRoot)

        XCTAssertTrue(session.isGitRepo)
        XCTAssertEqual(session.gitRootPath, repoRoot)
        XCTAssertEqual(session.displayGitRootPath, repoRoot)
        XCTAssertTrue(session.hasRepositoryIdentity)

        // Identity store should have the new root.
        let identity = KnownRepoIdentityStore.shared.identity(forRootPath: repoRoot)
        XCTAssertNotNil(identity, "Shell-reported root should be recorded in the identity store")
        XCTAssertEqual(identity?.rootPath, repoRoot)

        // A cached RepositoryModel should have been created.
        XCTAssertNotNil(session.repositoryModel, "Should create a cached model when none existed")
        XCTAssertEqual(session.repositoryModel?.rootPath, repoRoot)
        XCTAssertEqual(session.repositoryModel?.accessLevel, .cached)
    }

    func testHandleShellRepoRootReportRecordsBranchIfKnown() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }
        KnownRepoIdentityStore.shared.reset()

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/aegowlg"

        // The branch was reported BEFORE the root (e.g. the parser processed events
        // in order but the handler fired branch first because of dispatch scheduling).
        session.gitBranch = "main"
        session.currentDirectory = repoRoot

        session.handleShellRepoRootReport(repoRoot)

        let identity = KnownRepoIdentityStore.shared.identity(forRootPath: repoRoot)
        XCTAssertEqual(
            identity?.lastKnownBranch,
            "main",
            "Repo-root handler should persist the already-known branch to the identity store"
        )
        XCTAssertEqual(session.repositoryModel?.branch, "main")
    }

    func testHandleShellRepoRootReportIgnoresEmptyPath() {
        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        session.isGitRepo = false
        session.gitRootPath = nil

        session.handleShellRepoRootReport("")
        session.handleShellRepoRootReport("   ")

        XCTAssertFalse(session.isGitRepo, "Empty paths must be ignored")
        XCTAssertNil(session.gitRootPath)
    }

    func testHandleShellRepoRootReportNormalizesPath() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }
        KnownRepoIdentityStore.shared.reset()

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)

        // A path with ./ and // segments should be normalized.
        session.handleShellRepoRootReport("/tmp/Downloads//Repositories/./aegowlg")

        XCTAssertEqual(session.gitRootPath, "/tmp/Downloads/Repositories/aegowlg")
    }

    func testHandleShellRepoRootReportIsIdempotent() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }
        KnownRepoIdentityStore.shared.reset()

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/stable"

        session.handleShellRepoRootReport(repoRoot)
        let firstModel = session.repositoryModel

        session.handleShellRepoRootReport(repoRoot)
        let secondModel = session.repositoryModel

        XCTAssertTrue(
            firstModel === secondModel,
            "Repeated reports for the same root must reuse the same model instance"
        )
        XCTAssertEqual(session.gitRootPath, repoRoot)
    }

    func testHandleShellBranchReportUpdatesRepositoryModel() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }
        KnownRepoIdentityStore.shared.reset()

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/existing"

        // Pre-existing cached model without a branch
        let model = RepositoryModel(rootPath: repoRoot, branch: nil, accessLevel: .cached)
        session.repositoryModel = model
        session.gitRootPath = repoRoot
        session.isGitRepo = true
        session.currentDirectory = repoRoot

        session.handleShellBranchReport("feature/x")

        XCTAssertEqual(session.gitBranch, "feature/x")
        XCTAssertEqual(model.branch, "feature/x", "Branch report should update the model")

        let identity = KnownRepoIdentityStore.shared.identity(forRootPath: repoRoot)
        XCTAssertEqual(identity?.lastKnownBranch, "feature/x")
    }

    func testHandleShellBranchReportClearsDetachedHeadSentinel() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }
        KnownRepoIdentityStore.shared.reset()

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/detached"
        let model = RepositoryModel(rootPath: repoRoot, branch: "main", accessLevel: .cached)

        KnownRepoIdentityStore.shared.record(rootPath: repoRoot, branch: "main")
        session.repositoryModel = model
        session.gitRootPath = repoRoot
        session.gitBranch = "main"
        session.isGitRepo = true
        session.currentDirectory = repoRoot

        session.handleShellBranchReport("HEAD")

        XCTAssertNil(session.gitBranch)
        XCTAssertNil(model.branch)
        XCTAssertNil(session.displayGitBranch)
        XCTAssertNil(KnownRepoIdentityStore.shared.identity(forRootPath: repoRoot)?.lastKnownBranch)
    }

    func testShellRepoRootThenBranchFullyPopulatesState() {
        // Integration test: simulate the real OSC sequence ordering from the shell.
        // The app receives `repo-root=/path` first, then `branch=main` (order from
        // the precmd hook in the zsh/bash/fish implementations).
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }
        KnownRepoIdentityStore.shared.reset()

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let repoRoot = "/tmp/Downloads/Repositories/aegowlg"

        session.currentDirectory = repoRoot
        session.isGitRepo = false
        session.gitRootPath = nil
        session.gitBranch = nil
        session.repositoryModel = nil

        session.handleShellRepoRootReport(repoRoot)
        session.handleShellBranchReport("main")

        XCTAssertTrue(session.isGitRepo)
        XCTAssertEqual(session.gitRootPath, repoRoot)
        XCTAssertEqual(session.gitBranch, "main")
        XCTAssertTrue(session.hasRepositoryIdentity)
        XCTAssertEqual(session.displayGitBranch, "main")

        let identity = KnownRepoIdentityStore.shared.identity(forRootPath: repoRoot)
        XCTAssertEqual(identity?.lastKnownBranch, "main")
    }

    func testShellRepoRootReportReplacesPreviousRepositoryModelBeforeBranchReport() throws {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }
        KnownRepoIdentityStore.shared.reset()

        let appModel = AppModel()
        let session = TerminalSessionModel(appModel: appModel)
        let oldRoot = "/tmp/Downloads/Repositories/old"
        let newRoot = "/tmp/Downloads/Repositories/new"
        let oldModel = RepositoryModel(rootPath: oldRoot, branch: "main", accessLevel: .cached)

        session.currentDirectory = newRoot
        session.isGitRepo = true
        session.gitRootPath = oldRoot
        session.gitBranch = "main"
        session.repositoryModel = oldModel

        session.handleShellRepoRootReport(newRoot)

        XCTAssertEqual(session.gitRootPath, newRoot)
        XCTAssertNil(session.gitBranch, "Changing repo roots must not carry the old repo's branch forward")
        let newModel = try XCTUnwrap(session.repositoryModel)
        XCTAssertFalse(newModel === oldModel)
        XCTAssertEqual(newModel.rootPath, newRoot)
        XCTAssertNil(newModel.branch)

        session.handleShellBranchReport("feature/new")

        XCTAssertEqual(oldModel.branch, "main", "New repo branch reports must not mutate the previous shared model")
        XCTAssertEqual(newModel.branch, "feature/new")
        XCTAssertEqual(session.gitBranch, "feature/new")
    }

    // MARK: - Foreign OSC 9 Notification Classification

    func testForeignNotification_execApprovalRequested_mapsToPermission() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Approval requested: rm -rf /tmp/foo"
        )
        XCTAssertEqual(result?.source, .codex)
        XCTAssertEqual(result?.type, "permission")
        XCTAssertEqual(result?.tool, "Codex")
    }

    func testForeignNotification_elicitationRequested_mapsToPermission() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Approval requested by github_mcp_server"
        )
        XCTAssertEqual(result?.type, "permission")
    }

    func testForeignNotification_editApproval_mapsToPermission() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Codex wants to edit src/foo.rs"
        )
        XCTAssertEqual(result?.type, "permission")
    }

    func testForeignNotification_editApprovalMultipleFiles_mapsToPermission() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Codex wants to edit 3 files"
        )
        XCTAssertEqual(result?.type, "permission")
    }

    func testForeignNotification_questionRequested_mapsToWaitingInput() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Question requested: Which branch?"
        )
        XCTAssertEqual(result?.type, "waiting_input")
    }

    func testForeignNotification_questionsRequestedPlural_mapsToWaitingInput() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Questions requested: 3"
        )
        XCTAssertEqual(result?.type, "waiting_input")
    }

    func testForeignNotification_questionRequestedNoColon_mapsToWaitingInput() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Question requested"
        )
        XCTAssertEqual(result?.type, "waiting_input")
    }

    func testForeignNotification_planModePrompt_mapsToAttentionRequired() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Plan mode prompt: Choose an approach"
        )
        XCTAssertEqual(result?.type, "attention_required")
    }

    func testForeignNotification_unrecognizedMessageIsDropped() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Committed the refactor as abc123 and pushed to main"
        )
        XCTAssertNil(result)
    }

    func testForeignNotification_agentTurnComplete_mapsToFinished() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "Agent turn complete"
        )
        XCTAssertEqual(result?.type, "finished")
    }

    func testForeignNotification_trimsWhitespaceBeforeClassifying() {
        let result = TerminalSessionModel.classifyForeignDesktopNotification(
            "   Approval requested: git reset --hard   "
        )
        XCTAssertEqual(result?.type, "permission")
    }

    func testRestoreAIMetadata() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.restoreAIMetadata(provider: "Claude", sessionId: "  abc123 ")
        XCTAssertEqual(session.lastAIProvider, "claude")
        XCTAssertEqual(session.lastAISessionId, "abc123")

        session.restoreAIMetadata(provider: "codex", sessionId: "bad id")
        XCTAssertEqual(session.lastAIProvider, "codex")
        XCTAssertNil(session.lastAISessionId)

        session.restoreAIMetadata(provider: nil, sessionId: nil)
        XCTAssertNil(session.lastAIProvider)
        XCTAssertNil(session.lastAISessionId)
    }

    func testRestoreAIMetadataCanAvoidActivatingBackgroundAIState() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.restoreAIMetadata(
            provider: "codex",
            sessionId: "session-123",
            lastStatus: .running,
            activateRestoredAppName: false
        )

        XCTAssertEqual(session.lastAIProvider, "codex")
        XCTAssertEqual(session.lastAISessionId, "session-123")
        XCTAssertEqual(session.aiDisplayAppName, "Codex")
        XCTAssertNil(session.activeAppName)
        XCTAssertTrue(session.backgroundLiveRenderReasons().isEmpty)
    }

    func testCaptureRemoteSnapshotFallsBackToCachedRemoteOutputText() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.cachedRemoteOutputText = "cached transcript line\nnext line"

        let snapshot = session.captureRemoteSnapshot()

        XCTAssertEqual(snapshot.flatMap { String(data: $0, encoding: .utf8) }, "cached transcript line\nnext line")
        XCTAssertEqual(session.bufferLineCount, 2)
    }

    func testCaptureRemoteSnapshotFallsBackToCachedBufferDataWhenTranscriptMissing() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.cachedBufferData = Data("cached buffer".utf8)

        let snapshot = session.captureRemoteSnapshot()

        XCTAssertEqual(snapshot.flatMap { String(data: $0, encoding: .utf8) }, "cached buffer")
    }

    func testRestoreAIMetadataPreservesLifecycleFields() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let startedAt = Date(timeIntervalSince1970: 100)
        let lastInputAt = Date(timeIntervalSince1970: 110)
        let lastOutputAt = Date(timeIntervalSince1970: 120)
        let lastExitAt = Date(timeIntervalSince1970: 130)

        session.restoreAIMetadata(
            provider: "codex",
            sessionId: "session-123",
            sessionIdSource: .explicit,
            launchCommand: "codex --model gpt-5.3-codex",
            startedAt: startedAt,
            lastInputAt: lastInputAt,
            lastOutputAt: lastOutputAt,
            lastStatus: .done,
            lastExitCode: 0,
            lastExitAt: lastExitAt
        )

        XCTAssertEqual(session.lastAIProvider, "codex")
        XCTAssertEqual(session.lastAISessionId, "session-123")
        XCTAssertEqual(session.lastAISessionIdentitySource, .explicit)
        XCTAssertEqual(session.lastAgentLaunchCommand, "codex --model gpt-5.3-codex")
        XCTAssertEqual(session.agentStartedAt, startedAt)
        XCTAssertEqual(session.lastInputDate, lastInputAt)
        XCTAssertEqual(session.lastOutputDate, lastOutputAt)
        XCTAssertEqual(session.status, .done)
        XCTAssertEqual(session.lastExitCode, 0)
        XCTAssertEqual(session.lastExitAt, lastExitAt)
    }

    func testCurrentPTYLogPathReflectsActiveAILogSession() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.startAILoggingIfNeeded(toolName: "Codex", commandLine: "codex --model gpt-5.3-codex")

        XCTAssertNotNil(session.currentPTYLogPath())
        XCTAssertTrue(session.currentPTYLogPath()?.contains("codex") == true)

        session.finishAILogging(exitCode: 0)
        XCTAssertNotNil(session.currentPTYLogPath())
    }

    func testSyncCurrentPTYLogDrainsQueuedOutputProcessingQueue() throws {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-sync-pty-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }

        session.lastPTYLogPath = logURL.path
        session.startAILoggingIfNeeded(toolName: "Codex", commandLine: "codex --model gpt-5.3-codex")
        session.handleOutput(Data("Working...\n__CHAU7_REVIEW_JSON_BEGIN__\n{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[],\"confidence\":\"high\"}\n__CHAU7_REVIEW_JSON_END__\n".utf8))

        session.syncCurrentPTYLog()

        let tail = try XCTUnwrap(TelemetryRecorder.readPTYLogTail(path: session.currentPTYLogPath() ?? logURL.path))
        XCTAssertTrue(tail.contains("__CHAU7_REVIEW_JSON_BEGIN__"))
        XCTAssertTrue(tail.contains("\"summary\":\"ok\""))
    }

    func testSessionTabIdentifierIsUnique() {
        let model = AppModel()
        let session1 = TerminalSessionModel(appModel: model)
        let session2 = TerminalSessionModel(appModel: model)
        XCTAssertNotEqual(
            session1.tabIdentifier,
            session2.tabIdentifier,
            "Each session should have a unique tab identifier"
        )
    }

    func testSessionTabIdentifierIsNonEmpty() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertFalse(
            session.tabIdentifier.isEmpty,
            "Tab identifier should not be empty"
        )
    }

    func testDangerousCommandCheckForDirectUserInputUsesPendingBufferOnSubmit() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let guard_ = DangerousCommandGuard.shared
        let originalEnabled = guard_.isEnabled
        let originalBlockList = guard_.blockList

        defer {
            guard_.blockList = originalBlockList
            guard_.isEnabled = originalEnabled
        }

        guard_.isEnabled = true
        guard_.blockList = ["danger-cmd"]
        session.inputBuffer = "danger-cmd"

        XCTAssertEqual(
            session.dangerousCommandCheckForDirectUserInput("\n"),
            .blocked(reason: "blocked by dangerous command guard block list")
        )
    }

    func testDangerousCommandCheckForDirectUserInputIgnoresNonSubmittingInput() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.inputBuffer = "kill 1234"

        XCTAssertNil(session.dangerousCommandCheckForDirectUserInput("x"))
    }

    func testHandlePromptDetectedEmitsWaitingInputFallbackForSupportedAITool() async {
        RuntimeSessionManager.shared.resetForTesting()
        // The fallback is suppressed when the developer machine's real
        // ~/.codex/config.toml has the notify hook installed — force the
        // "no authoritative notifications" case so the test is hermetic.
        TerminalSessionModel.hasAuthoritativeNotificationsOverrideForTesting = false
        defer { TerminalSessionModel.hasAuthoritativeNotificationsOverrideForTesting = nil }
        // recentEvents is only populated when the notification ingress accepts
        // the event, which requires a NotificationServices instance. Isolated
        // test mode keeps NotificationManager off UNUserNotificationCenter,
        // which crashes in bundle-less test processes (mirrors
        // AppModelEventRoutingTests).
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
        _ = NSApplication.shared
        let model = AppModel(notifications: NotificationServices())
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()

        session.ownerTabID = tabID
        session.currentDirectory = "/tmp/mockup"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.handleInputLine("continue")
        session.status = .running
        session.handleOutput(Data("assistant output".utf8))

        session.handlePromptDetected()
        // Delivery now flows through the event-spine pump (an async main-actor
        // task), so a single main-queue hop is not enough — poll.
        // handlePromptDetected also finishes the pending heuristic command,
        // which records a shell `process_ended` event after the fallback —
        // look the waiting_input event up instead of relying on order.
        var polledEvent: AIEvent?
        for _ in 0 ..< 200 {
            polledEvent = model.recentEvents.last(where: { $0.type == "waiting_input" })
            if polledEvent != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let event = polledEvent
        XCTAssertEqual(event?.source, .codex)
        XCTAssertEqual(event?.type, "waiting_input")
        XCTAssertEqual(event?.tabID, tabID)
        XCTAssertEqual(event?.producer, "terminal_prompt_waiting_input")
        XCTAssertEqual(event?.reliability, .fallback)
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testTerminalWaitPatternSkipsHeuristicEventWhenProviderHasAuthoritativeNotifications() async {
        RuntimeSessionManager.shared.resetForTesting()
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()

        session.ownerTabID = tabID
        session.currentDirectory = "/tmp/aethyme"
        session.activeAppName = "Claude"
        session.lastDetectedAppName = "Claude"
        session.lastAIProvider = "claude"
        session.lastAISessionId = "claude-session-1"
        session.status = .running

        session.handleOutput(Data("Proceed?".utf8))
        // handleOutput hops to the background output-processing queue and back
        // to main (twice: once for the UI block, once for the status update),
        // so the original fixed pair of main-queue flushes raced the
        // detection. Poll asynchronously until the status settles instead.
        await waitUntilAsync { session.status == .waitingForInput }

        let event = model.recentEvents.last
        XCTAssertEqual(session.status, .waitingForInput)
        XCTAssertNil(event)
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testHandlePromptDetectedSkipsFallbackWhenRuntimeSessionOwnsTab() async {
        RuntimeSessionManager.shared.resetForTesting()
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()

        session.ownerTabID = tabID
        session.currentDirectory = "/tmp/mockup"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.handleInputLine("continue")
        session.status = .running
        session.handleOutput(Data("assistant output".utf8))

        _ = RuntimeSessionManager.shared.createSession(
            tabID: tabID,
            backend: CodexBackend(),
            config: SessionConfig(directory: "/tmp/mockup", provider: "codex")
        )

        session.handlePromptDetected()
        let expectation = expectation(description: "prompt handling settled")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertFalse(model.recentEvents.contains { $0.type == "waiting_input" })
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testHandlePromptDetectedSkipsFallbackWithoutLiveOutput() async {
        RuntimeSessionManager.shared.resetForTesting()
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.ownerTabID = UUID()
        session.currentDirectory = "/tmp/mockup"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.handleInputLine("continue")
        session.status = .running

        session.handlePromptDetected()
        let expectation = expectation(description: "prompt handling settled")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertFalse(model.recentEvents.contains { $0.type == "waiting_input" })
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testHandlePromptDetectedSkipsFallbackDuringPendingResumePrefill() async {
        RuntimeSessionManager.shared.resetForTesting()
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.ownerTabID = UUID()
        session.currentDirectory = "/tmp/mockup"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.pendingWaitingInputFallbackArmed = true
        session.pendingWaitingInputFallbackSawLiveOutput = true
        session.prefillInput("codex resume 019d33cd-6084-78c1-a0c4-8de2a6142049")
        session.status = .running

        session.handlePromptDetected()
        let expectation = expectation(description: "prefill prompt handling settled")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertFalse(model.recentEvents.contains { $0.type == "waiting_input" })
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testHandlePromptDetectedSkipsFallbackAfterDeliveredResumePrefillUntilUserCommand() async {
        RuntimeSessionManager.shared.resetForTesting()
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.ownerTabID = UUID()
        session.currentDirectory = "/tmp/mockup"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.handleInputLine("continue")
        session.status = .running
        session.handleOutput(Data("assistant output".utf8))
        session.prefillInput("codex resume 019d0000-0000-7000-8000-000000000000")

        session.handlePromptDetected()
        let expectation = expectation(description: "prompt handling settled")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertFalse(model.recentEvents.contains { $0.type == "waiting_input" })
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testRestoredAISessionSkipsFallbackBeforeAnyExplicitUserCommand() async {
        RuntimeSessionManager.shared.resetForTesting()
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.ownerTabID = UUID()
        session.currentDirectory = "/tmp/chau7"
        session.restoreAIMetadata(
            provider: "codex",
            sessionId: "019d4a14-a656-72f0-a136-4c03ce6d907c"
        )
        session.pendingWaitingInputFallbackArmed = true
        session.pendingWaitingInputFallbackSawLiveOutput = true
        session.status = .running

        XCTAssertTrue(session.suppressWaitingInputFallbackUntilNextUserCommand)

        session.handlePromptDetected()
        let expectation = expectation(description: "restored prompt handling settled")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertFalse(model.recentEvents.contains { $0.type == "waiting_input" })
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testSystemRestoreInputDoesNotClearWaitingInputSuppression() async {
        RuntimeSessionManager.shared.resetForTesting()
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.ownerTabID = UUID()
        session.currentDirectory = "/tmp/chau7"
        session.restoreAIMetadata(
            provider: "codex",
            sessionId: "019d4a14-a656-72f0-a136-4c03ce6d907c"
        )
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"

        XCTAssertTrue(session.suppressWaitingInputFallbackUntilNextUserCommand)

        session.sendOrQueueSystemRestoreInput(" cat '/tmp/chau7_restore.txt' && clear\n")
        session.handleInputLine(" cat '/tmp/chau7_restore.txt' && clear")

        XCTAssertTrue(session.suppressWaitingInputFallbackUntilNextUserCommand)
        XCTAssertNil(session.pendingSystemRestoreInputLine)

        session.pendingWaitingInputFallbackArmed = true
        session.pendingWaitingInputFallbackSawLiveOutput = true
        session.status = .running
        session.handlePromptDetected()

        let expectation = expectation(description: "system restore prompt handling settled")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertFalse(model.recentEvents.contains { $0.type == "waiting_input" })
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testUserCommandClearsResumePrefillFallbackSuppression() async {
        RuntimeSessionManager.shared.resetForTesting()
        // Hermetic: don't let the real ~/.codex/config.toml notify hook
        // suppress the codex waiting-input fallback.
        TerminalSessionModel.hasAuthoritativeNotificationsOverrideForTesting = false
        defer { TerminalSessionModel.hasAuthoritativeNotificationsOverrideForTesting = nil }
        // recentEvents is only populated when the notification ingress accepts
        // the event, which requires a NotificationServices instance. Isolated
        // test mode keeps NotificationManager off UNUserNotificationCenter,
        // which crashes in bundle-less test processes (mirrors
        // AppModelEventRoutingTests).
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
        _ = NSApplication.shared
        let model = AppModel(notifications: NotificationServices())
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()

        let settings = FeatureSettings.shared
        let originalAutoSubmit = settings.autoSubmitRestorePrefill
        settings.autoSubmitRestorePrefill = false
        defer { settings.autoSubmitRestorePrefill = originalAutoSubmit }

        session.ownerTabID = tabID
        session.currentDirectory = "/tmp/mockup"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        // The prefill must actually deliver (view attached, prompt seen) —
        // an undelivered prefill keeps hasPendingResumePrefillActivity true,
        // which suppresses the waiting-input fallback regardless of the
        // per-user-command suppression this test exercises.
        session.attachRustTerminal(RustTerminalView(frame: .zero))
        session.isShellLoading = false
        session.isAtPrompt = true
        XCTAssertEqual(
            session.prefillInput("codex resume 019d0000-0000-7000-8000-000000000000"),
            .delivered
        )

        XCTAssertTrue(session.suppressWaitingInputFallbackUntilNextUserCommand)

        session.handleInputLine("continue")
        XCTAssertFalse(session.suppressWaitingInputFallbackUntilNextUserCommand)

        session.status = .running
        session.handleOutput(Data("assistant output".utf8))
        session.handlePromptDetected()

        // Delivery now flows through the event-spine pump (an async main-actor
        // task), so a single main-queue hop is not enough — poll.
        // A shell `process_ended` event from the finished heuristic command
        // may follow the fallback — look the waiting_input event up instead
        // of relying on order.
        var polledEvent: AIEvent?
        for _ in 0 ..< 200 {
            polledEvent = model.recentEvents.last(where: { $0.type == "waiting_input" })
            if polledEvent != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let event = polledEvent
        XCTAssertEqual(event?.type, "waiting_input")
        XCTAssertEqual(event?.tabID, tabID)
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testHandleInputLineCreatesHeuristicCommandBlockWithCurrentRow() async {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()
        session.ownerTabID = tabID
        session.bufferRowProvider = { 42 }

        CommandBlockManager.shared.clearBlocks(tabID: tabID.uuidString)
        session.handleInputLine("ls -la")
        await flushMainQueue()

        let blocks = CommandBlockManager.shared.blocksForTab(tabID.uuidString)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].command, "ls -la")
        XCTAssertEqual(blocks[0].startLine, 42)
        XCTAssertTrue(blocks[0].isRunning)
    }

    func testHandlePromptDetectedFinishesHeuristicCommandBlockWithoutExitCode() async throws {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()
        session.ownerTabID = tabID
        session.bufferRowProvider = { 64 }

        CommandBlockManager.shared.clearBlocks(tabID: tabID.uuidString)
        session.handleInputLine("continue")
        await flushMainQueue()
        session.handlePromptDetected()
        await flushMainQueue()

        let block = try XCTUnwrap(CommandBlockManager.shared.blocksForTab(tabID.uuidString).first)
        XCTAssertFalse(block.isRunning)
        XCTAssertEqual(block.endLine, 64)
        XCTAssertNil(block.exitCode)
    }

    func testHandlePromptDetectedUsesShellReportedHeuristicExitCode() async throws {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()
        session.ownerTabID = tabID
        session.bufferRowProvider = { 65 }

        CommandBlockManager.shared.clearBlocks(tabID: tabID.uuidString)
        session.handleInputLine("false")
        await flushMainQueue()
        session.handleShellExitStatusReport(17)
        await flushMainQueue()
        session.handlePromptDetected()
        await flushMainQueue()

        let block = try XCTUnwrap(CommandBlockManager.shared.blocksForTab(tabID.uuidString).first)
        XCTAssertFalse(block.isRunning)
        XCTAssertEqual(block.endLine, 65)
        XCTAssertEqual(block.exitCode, 17)
    }

    func testHeuristicFallbackTimeoutMarksSyntheticExitCode() async throws {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()
        session.ownerTabID = tabID
        session.bufferRowProvider = { 80 }

        CommandBlockManager.shared.clearBlocks(tabID: tabID.uuidString)
        session.handleInputLine("long-running")
        await flushMainQueue()

        session.status = .running
        session.lastInputAt = Date.distantPast
        session.lastOutputAt = Date.distantPast
        session.commandStartedAt = Date.distantPast
        // First idle tick marks the long-silent command as .stuck and returns;
        // the next tick (status .stuck) runs the fallback-completion path that
        // stamps the synthetic timeout exit code. Mirrors the production idle
        // timer, which fires repeatedly.
        session.markIdleIfNeeded()
        await flushMainQueue()
        XCTAssertEqual(session.status, .stuck)
        session.markIdleIfNeeded()
        await flushMainQueue()

        let block = try XCTUnwrap(CommandBlockManager.shared.blocksForTab(tabID.uuidString).first)
        XCTAssertEqual(block.exitCode, CommandBlock.syntheticTimeoutExitCode)
        XCTAssertFalse(block.isRunning)
    }

    func testCommandBlockCapturesCurrentRuntimeTurnID() async throws {
        RuntimeSessionManager.shared.resetForTesting()
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()
        session.ownerTabID = tabID
        session.bufferRowProvider = { 24 }

        let runtimeSession = RuntimeSessionManager.shared.createSession(
            tabID: tabID,
            backend: CodexBackend(),
            config: SessionConfig(directory: "/tmp/mockup", provider: "codex")
        )
        _ = runtimeSession.startTurn(prompt: "inspect", resultSchema: nil)

        CommandBlockManager.shared.clearBlocks(tabID: tabID.uuidString)
        session.handleInputLine("continue")
        await flushMainQueue()

        let block = try XCTUnwrap(CommandBlockManager.shared.blocksForTab(tabID.uuidString).first)
        XCTAssertEqual(block.turnID, runtimeSession.currentTurnID)
        RuntimeSessionManager.shared.resetForTesting()
    }

    func testUserInputTrackerCapturesUserAgentAndSystemSources() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.bufferRowProvider = { 9 }
        session.handleInputLine("ls")

        session.bufferRowProvider = { 10 }
        session.activeAppName = "Codex"
        session.handleInputLine("continue")

        session.bufferRowProvider = { 11 }
        session.activeAppName = nil
        session.sendOrQueueSystemRestoreInput(" restore\n")
        session.handleInputLine(" restore")

        let records = session.userInputTracker.sortedRecords()
        XCTAssertEqual(records.map(\.row), [9, 10, 11])
        XCTAssertEqual(records.map(\.source), [.user, .agent, .system])
    }

    // MARK: - Default Current Directory

    func testSessionCurrentDirectoryIsAbsolute() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertTrue(
            session.currentDirectory.hasPrefix("/"),
            "Current directory should be an absolute path"
        )
    }

    func testSessionCurrentDirectoryIsNonEmpty() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertFalse(
            session.currentDirectory.isEmpty,
            "Current directory should not be empty"
        )
    }

    // MARK: - Token Optimization Override Default

    func testTokenOptOverrideDefaultValue() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertEqual(
            session.tokenOptOverride,
            .default,
            "Token optimization override should default to .default"
        )
    }

    // MARK: - Latency Properties Initial Values

    func testLatencyPropertiesInitiallyNil() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertNil(session.inputLatencyMs, "Initial inputLatencyMs should be nil")
        XCTAssertNil(session.inputLatencyAverageMs, "Initial inputLatencyAverageMs should be nil")
        XCTAssertNil(session.outputLatencyMs, "Initial outputLatencyMs should be nil")
        XCTAssertNil(session.outputLatencyAverageMs, "Initial outputLatencyAverageMs should be nil")
        XCTAssertNil(session.scanLagDelayMs, "Initial scanLagDelayMs should be nil")
        XCTAssertNil(session.scanLagAverageMs, "Initial scanLagAverageMs should be nil")
    }

    // MARK: - Terminal View Accessors

    func testExistingTerminalContainerViewNilByDefault() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertNil(
            session.existingTerminalContainerView,
            "No terminal container view should be attached by default"
        )
    }

    func testExistingRustTerminalViewNilByDefault() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertNil(
            session.existingRustTerminalView,
            "No Rust terminal view should be attached by default"
        )
    }

    // MARK: - clearSearch

    func testClearSearchResetsState() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        // Clear search on a fresh session should be safe and leave search state empty
        session.clearSearch()
        XCTAssertTrue(
            session.searchMatches.isEmpty,
            "Search matches should be empty after clearSearch"
        )
        XCTAssertEqual(
            session.activeSearchIndex,
            0,
            "Active search index should be 0 after clearSearch"
        )
    }

    // MARK: - Font Size Default

    func testDefaultFontSizeIsReasonable() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertGreaterThanOrEqual(
            session.fontSize,
            8,
            "Font size should be at least 8pt"
        )
        XCTAssertLessThanOrEqual(
            session.fontSize,
            72,
            "Font size should be at most 72pt"
        )
    }

    func testCloseSessionShutsDownActiveTerminalRendering() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let terminalView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.notifyUpdateChanges = true
        terminalView.isHidden = false
        terminalView.setEventMonitoringEnabled(true)
        session.attachRustTerminal(terminalView)

        session.closeSession()

        XCTAssertFalse(terminalView.notifyUpdateChanges)
        XCTAssertTrue(terminalView.isHidden)
        XCTAssertTrue(session.existingRustTerminalView === terminalView)
    }

    func testCloseSessionForTerminationShutsDownActiveTerminalRendering() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let terminalView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.notifyUpdateChanges = true
        terminalView.isHidden = false
        terminalView.setEventMonitoringEnabled(true)
        session.attachRustTerminal(terminalView)

        session.closeSessionForTermination()

        XCTAssertFalse(terminalView.notifyUpdateChanges)
        XCTAssertTrue(terminalView.isHidden)
        XCTAssertTrue(session.existingRustTerminalView === terminalView)
    }

    func testCloseSessionForTerminationDetachesProcessTerminationCallback() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let terminalView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        session.attachRustTerminal(terminalView)

        session.closeSessionForTermination()

        XCTAssertNil(terminalView.onProcessTerminated)
        XCTAssertTrue(session.existingRustTerminalView === terminalView)
    }

    func testProcessTerminationReleasesRetainedTerminalView() async {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let terminalView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        session.attachRustTerminal(terminalView)

        session.closeSession()
        terminalView.onProcessTerminated?(0)
        await flushMainQueue()

        XCTAssertNil(session.existingRustTerminalView)
    }

    // MARK: - Prefill Input

    func testPrefillInputQueuesUntilTerminalViewAttached() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }

        session.prefillInput("claude --resume abc123")
        XCTAssertTrue(capturedInputs.isEmpty, "command should be deferred before terminal is attached")

        session.attachRustTerminal(terminalView)

        waitUntil { !capturedInputs.isEmpty }
        XCTAssertEqual(capturedInputs, ["claude --resume abc123"])
    }

    func testQueuedInputAndEnterFlushInOriginalOrderOnAttach() throws {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.sendOrQueueInput("hello")
        try session.sendOrQueueKeyPress(TerminalKeyPress(key: "enter"))

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }

        session.attachRustTerminal(terminalView)

        waitUntil { capturedInputs.count >= 2 }
        XCTAssertEqual(capturedInputs, ["hello", "\r"])
    }

    func testPrefillInputAppliesImmediatelyWhenTerminalIsReady() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }
        session.attachRustTerminal(terminalView)
        session.prefillInput("claude --resume xyz789")

        waitUntil { !capturedInputs.isEmpty }
        XCTAssertEqual(capturedInputs, ["claude --resume xyz789"])
    }

    /// The eager 0.3–3s backoff caps at retry 20; after that the retry
    /// pacer must fall back to a 5s heartbeat rather than silently giving
    /// up. Cold-boot regression: when OSC 133 takes longer than the eager
    /// window to arrive (common with many shells racing during multi-tab
    /// restore), the original code returned `.queued` with no scheduled
    /// follow-up, leaving the prefill stuck until the user happened to
    /// trigger an `attachRustTerminal` by switching tabs.
    func testPrefillRetryDelayFallsBackToHeartbeatAfterEagerExhaustion() {
        // Eager backoff: monotonically growing then clamped to 3.0.
        XCTAssertEqual(TerminalSessionModel.nextPrefillRetryDelay(retries: 1), 0.6, accuracy: 0.0001)
        XCTAssertEqual(TerminalSessionModel.nextPrefillRetryDelay(retries: 9), 3.0, accuracy: 0.0001)
        XCTAssertEqual(TerminalSessionModel.nextPrefillRetryDelay(retries: 20), 3.0, accuracy: 0.0001)

        // Heartbeat: every retry past the eager limit returns the same 5s
        // delay. Crucially NON-ZERO and bounded — the pre-fix code returned
        // .queued with no follow-up scheduled at this point.
        XCTAssertEqual(TerminalSessionModel.nextPrefillRetryDelay(retries: 21), 5.0, accuracy: 0.0001)
        XCTAssertEqual(TerminalSessionModel.nextPrefillRetryDelay(retries: 100), 5.0, accuracy: 0.0001)
        XCTAssertEqual(TerminalSessionModel.nextPrefillRetryDelay(retries: 10000), 5.0, accuracy: 0.0001)
    }

    func testPrefillInputTracksResumeMetadataImmediately() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.prefillInput("codex resume 019d25d0-d0bd-7501-99ba-1f937c17b29b")

        XCTAssertEqual(session.effectiveAIProvider, "codex")
        XCTAssertEqual(session.effectiveAISessionId, "019d25d0-d0bd-7501-99ba-1f937c17b29b")
    }

    func testQueuedInputTracksResumeMetadataBeforeAttach() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.sendOrQueueInput("claude --resume abc123\n")

        XCTAssertEqual(session.effectiveAIProvider, "claude")
        XCTAssertEqual(session.effectiveAISessionId, "abc123")
    }

    func testRestoreAIMetadataDoesNotMarkProviderAsLiveDetected() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.restoreAIMetadata(provider: "codex", sessionId: nil)

        XCTAssertNil(session.lastDetectedAppName)
        XCTAssertEqual(session.activeAppName, "Codex")
        XCTAssertEqual(session.effectiveAIProvider, "codex")
    }

    func testPrefillInputWaitsForReadySessionState() {
        let settings = FeatureSettings.shared
        let originalAutoSubmit = settings.autoSubmitRestorePrefill
        settings.autoSubmitRestorePrefill = false
        defer { settings.autoSubmitRestorePrefill = originalAutoSubmit }

        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        // Not ready: shell hasn't reported a prompt yet. (Prompt detection is
        // authoritative over laggy status transitions, so a `.running` status
        // alone no longer blocks delivery — see `isPrefillReady`.)
        session.isShellLoading = false
        session.isAtPrompt = false
        session.status = .idle

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }
        session.attachRustTerminal(terminalView)

        session.prefillInput("claude --resume blocked")
        // Negative check: give the main queue a real window to (incorrectly)
        // deliver the command while no prompt has been seen.
        let notReadyExpectation = expectation(description: "command waits until the shell shows a prompt")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(capturedInputs.isEmpty)
            notReadyExpectation.fulfill()
        }
        wait(for: [notReadyExpectation], timeout: 5.0)

        session.isAtPrompt = true
        session.prefillInput("claude --resume now")

        waitUntil { !capturedInputs.isEmpty }
        XCTAssertEqual(capturedInputs, ["claude --resume now"])
    }

    func testBuildEnvironmentIncludesUserShellConfigHints() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let environment = Dictionary(
            uniqueKeysWithValues: session.buildEnvironment().compactMap { entry -> (String, String)? in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        XCTAssertEqual(environment["CHAU7_USER_HOME"], ShellLaunchEnvironment.userHome())
        XCTAssertEqual(environment["CHAU7_USER_ZDOTDIR"], ShellLaunchEnvironment.userZdotdir())
        XCTAssertEqual(environment["CHAU7_USER_XDG_CONFIG_HOME"], ShellLaunchEnvironment.userXDGConfigHome())
    }

    func testBuildEnvironmentIncludesUTF8LocaleHints() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let environment = Dictionary(
            uniqueKeysWithValues: session.buildEnvironment().compactMap { entry -> (String, String)? in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        XCTAssertTrue(environment["LANG"]?.lowercased().contains("utf") ?? false)
        XCTAssertTrue(environment["LC_CTYPE"]?.lowercased().contains("utf") ?? false)
    }

    func testBuildEnvironmentUsesOwnerTabUUIDForChau7TabIDWhenAvailable() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let ownerTabID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        session.ownerTabID = ownerTabID

        let environment = Dictionary(
            uniqueKeysWithValues: session.buildEnvironment().compactMap { entry -> (String, String)? in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        XCTAssertEqual(environment["CHAU7_TAB_ID"], ownerTabID.uuidString)
    }

    func testBuildEnvironmentUsesStableProxyCorrelationSessionID() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let environment = Dictionary(
            uniqueKeysWithValues: session.buildEnvironment().compactMap { entry -> (String, String)? in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        XCTAssertEqual(environment["TERM_SESSION_ID"], environment["CHAU7_SESSION_ID"])
        XCTAssertEqual(environment["CHAU7_SESSION_ID"], session.proxyCorrelationSessionID)
    }

    func testPrepareProxyCorrelationSessionForShellLaunchRotatesSessionID() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let first = session.proxyCorrelationSessionID
        let second = session.prepareProxyCorrelationSessionForShellLaunch()
        let environment = Dictionary(
            uniqueKeysWithValues: session.buildEnvironment().compactMap { entry -> (String, String)? in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(environment["TERM_SESSION_ID"], second)
        XCTAssertEqual(environment["CHAU7_SESSION_ID"], second)
    }

    func testPreInitializeZshWrapperUsesRuntimeShellEnvironment() throws {
        TerminalSessionModel.preInitialize()
        guard let integrationDir = TerminalSessionModel.getShellIntegrationDir() else {
            XCTFail("Expected shell integration directory")
            return
        }

        let zshrcPath = (integrationDir as NSString).appendingPathComponent(".zshrc")
        let contents = try String(contentsOfFile: zshrcPath, encoding: .utf8)

        XCTAssertTrue(contents.contains("CHAU7_USER_HOME"))
        XCTAssertTrue(contents.contains("CHAU7_USER_ZDOTDIR"))
        XCTAssertTrue(contents.contains("export ZDOTDIR=\"$CHAU7_USER_ZDOTDIR\""))
        XCTAssertFalse(contents.contains("isolation-home/.zshrc"))
    }

    // MARK: - CTO Recalculation Debounce

    /// Burst of `recalculateCTOFlag` calls within the debounce window should
    /// collapse into a single underlying decision record. Process-tree
    /// snapshots and shell-integration events can flip `activeAppName`
    /// several times in tens of milliseconds; without debouncing, each
    /// flip becomes its own (mostly-no-op) recalc and inflates the
    /// `recalcCount` denominator in `decisionsChangeRatePercent`.
    func testRecalculateCTOFlagDebouncesBurstsIntoOneDecision() async {
        let originalMode = FeatureSettings.shared.tokenOptimizationMode
        FeatureSettings.shared.tokenOptimizationMode = .allTabs
        defer { FeatureSettings.shared.tokenOptimizationMode = originalMode }
        CTORuntimeMonitor.shared.reset()

        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        // Fire five times in immediate succession — should coalesce.
        for _ in 0 ..< 5 {
            session.recalculateCTOFlag()
        }

        // Before the debounce window elapses, no decision has been recorded.
        XCTAssertEqual(CTORuntimeMonitor.shared.snapshot().recalcCount, 0)

        // Poll until the debounced decision lands (50ms window), then allow a
        // settling margin so any extra burst decisions would also land before
        // we assert exactly one was recorded.
        let deadline = Date().addingTimeInterval(5)
        while CTORuntimeMonitor.shared.snapshot().recalcCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = CTORuntimeMonitor.shared.snapshot()
        XCTAssertEqual(snapshot.recalcCount, 1, "5 burst calls should yield 1 recorded decision")

        // Clean up the flag file the .allTabs decision just created.
        CTOFlagManager.removeFlag(sessionID: session.tabIdentifier)
    }

    func testRecalculateCTOFlagFlushImmediatelyBypassesDebounce() {
        let originalMode = FeatureSettings.shared.tokenOptimizationMode
        FeatureSettings.shared.tokenOptimizationMode = .allTabs
        defer { FeatureSettings.shared.tokenOptimizationMode = originalMode }
        CTORuntimeMonitor.shared.reset()

        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)

        session.recalculateCTOFlag(flushImmediately: true)

        XCTAssertEqual(
            CTORuntimeMonitor.shared.snapshot().recalcCount,
            1,
            "flushImmediately should record the decision synchronously"
        )

        // Clean up the flag file we just created.
        CTOFlagManager.removeFlag(sessionID: session.tabIdentifier)
    }
}
