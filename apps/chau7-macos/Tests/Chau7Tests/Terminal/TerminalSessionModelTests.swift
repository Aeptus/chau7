import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7
import Chau7Core

@MainActor
final class TerminalSessionModelTests: XCTestCase {

    // MARK: - CommandStatus Enum

    func testCommandStatusRawValues() {
        XCTAssertEqual(CommandStatus.idle.rawValue, "idle")
        XCTAssertEqual(CommandStatus.running.rawValue, "running")
        XCTAssertEqual(CommandStatus.waitingForInput.rawValue, "waitingForInput")
        XCTAssertEqual(CommandStatus.stuck.rawValue, "stuck")
        XCTAssertEqual(CommandStatus.exited.rawValue, "exited")
    }

    func testCommandStatusCasesAreDistinct() {
        let all: [CommandStatus] = [.idle, .running, .waitingForInput, .stuck, .exited]
        let rawValues = Set(all.map(\.rawValue))
        XCTAssertEqual(
            rawValues.count,
            all.count,
            "All CommandStatus cases should have unique raw values"
        )
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
        XCTAssertTrue(all.contains(.highlight))
    }

    func testLagKindRawValues() {
        XCTAssertEqual(TerminalSessionModel.LagKind.input.rawValue, "input")
        XCTAssertEqual(TerminalSessionModel.LagKind.output.rawValue, "output")
        XCTAssertEqual(TerminalSessionModel.LagKind.highlight.rawValue, "highlight")
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
        let identity = KnownRepoIdentity(
            rootPath: "/Users/me/Downloads/Repositories/Chau7",
            lastConfirmedAt: Date(timeIntervalSince1970: 0),
            lastKnownBranch: "main"
        )

        let state = TerminalSessionModel.repositoryState(
            from: .cachedIdentity(identity: identity, access: snapshot)
        )

        XCTAssertTrue(state.isGitRepo)
        XCTAssertEqual(state.gitRootPath, identity.rootPath)
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

    func testDisplayRepoIdentityFallsBackToKnownIdentity() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }

        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let repoRoot = "/tmp/Downloads/Repositories/Chau7"

        KnownRepoIdentityStore.shared.reset()
        KnownRepoIdentityStore.shared.record(rootPath: repoRoot, branch: "feature/protected")

        session.currentDirectory = repoRoot + "/apps/chau7-macos"
        session.isGitRepo = false
        session.gitRootPath = nil
        session.gitBranch = nil

        XCTAssertTrue(session.hasRepositoryIdentity)
        XCTAssertEqual(session.displayGitRootPath, repoRoot)
        XCTAssertEqual(session.displayGitBranch, "feature/protected")
        XCTAssertEqual(session.tabPathDisplayName(), "Chau7")
    }

    func testDisplayRepoIdentityPrefersLiveGitState() {
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousKnownIdentities) }

        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let repoRoot = "/tmp/Downloads/Repositories/Chau7"

        KnownRepoIdentityStore.shared.reset()
        KnownRepoIdentityStore.shared.record(rootPath: repoRoot, branch: "main")

        session.currentDirectory = repoRoot + "/apps/chau7-macos"
        session.isGitRepo = true
        session.gitRootPath = repoRoot
        session.gitBranch = "feature/live"

        XCTAssertTrue(session.hasRepositoryIdentity)
        XCTAssertEqual(session.displayGitRootPath, repoRoot)
        XCTAssertEqual(session.displayGitBranch, "feature/live")
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

        session.handlePromptDetected()
        let expectation = expectation(description: "waiting input event recorded")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)

        let event = model.recentEvents.last
        XCTAssertEqual(event?.source, .codex)
        XCTAssertEqual(event?.type, "waiting_input")
        XCTAssertEqual(event?.tabID, tabID)
        XCTAssertEqual(event?.producer, "terminal_prompt_waiting_input")
        XCTAssertEqual(event?.reliability, .fallback)
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
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let tabID = UUID()

        session.ownerTabID = tabID
        session.currentDirectory = "/tmp/mockup"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.prefillInput("codex resume 019d0000-0000-7000-8000-000000000000")

        XCTAssertTrue(session.suppressWaitingInputFallbackUntilNextUserCommand)

        session.handleInputLine("continue")
        XCTAssertFalse(session.suppressWaitingInputFallbackUntilNextUserCommand)

        session.status = .running
        session.handleOutput(Data("assistant output".utf8))
        session.handlePromptDetected()

        let expectation = expectation(description: "prompt handling settled")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)

        let event = model.recentEvents.last
        XCTAssertEqual(event?.type, "waiting_input")
        XCTAssertEqual(event?.tabID, tabID)
        RuntimeSessionManager.shared.resetForTesting()
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
        XCTAssertNil(session.dangerousHighlightDelayMs, "Initial dangerousHighlightDelayMs should be nil")
        XCTAssertNil(session.dangerousHighlightAverageMs, "Initial dangerousHighlightAverageMs should be nil")
    }

    // MARK: - Terminal View Accessors

    func testExistingTerminalViewNilByDefault() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertNil(
            session.existingTerminalView,
            "No terminal view should be attached by default"
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

    // MARK: - Snapshot

    func testLastRenderedSnapshotNilByDefault() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        XCTAssertNil(
            session.lastRenderedSnapshot,
            "No snapshot should exist for a fresh session"
        )
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

        let expectationDone = expectation(description: "queued prefill is flushed on attach")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(capturedInputs, ["claude --resume abc123"])
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 1.0)
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

        let expectationDone = expectation(description: "queued text and enter flush in order")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(capturedInputs, ["hello", "\r"])
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 1.0)
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

        let expectationDone = expectation(description: "prefill inserted on ready terminal")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(capturedInputs, ["claude --resume xyz789"])
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 1.0)
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
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .running

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }
        session.attachRustTerminal(terminalView)

        session.prefillInput("claude --resume blocked")
        let notReadyExpectation = expectation(description: "command waits while session is running")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(capturedInputs.isEmpty)
            notReadyExpectation.fulfill()
        }
        wait(for: [notReadyExpectation], timeout: 1.0)

        session.status = .idle
        session.prefillInput("claude --resume now")

        let readyExpectation = expectation(description: "command inserts once session becomes ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(capturedInputs, ["claude --resume now"])
            readyExpectation.fulfill()
        }
        wait(for: [readyExpectation], timeout: 1.0)
    }

    func testBuildEnvironmentIncludesUserShellConfigHints() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let environment = Dictionary(
            uniqueKeysWithValues: session.buildEnvironment().compactMap { entry in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        XCTAssertEqual(environment["CHAU7_USER_HOME"], ShellLaunchEnvironment.userHome())
        XCTAssertEqual(environment["CHAU7_USER_ZDOTDIR"], ShellLaunchEnvironment.userZdotdir())
        XCTAssertEqual(environment["CHAU7_USER_XDG_CONFIG_HOME"], ShellLaunchEnvironment.userXDGConfigHome())
    }

    func testBuildEnvironmentUsesOwnerTabUUIDForChau7TabIDWhenAvailable() {
        let model = AppModel()
        let session = TerminalSessionModel(appModel: model)
        let ownerTabID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        session.ownerTabID = ownerTabID

        let environment = Dictionary(
            uniqueKeysWithValues: session.buildEnvironment().compactMap { entry in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        XCTAssertEqual(environment["CHAU7_TAB_ID"], ownerTabID.uuidString)
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
}
#endif
