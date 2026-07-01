import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class TerminalControlServiceTests: XCTestCase {
    private var appModel: AppModel!
    private var overlayModel: OverlayTabsModel!
    private var savedPermissionMode: MCPPermissionMode!
    private var savedRequiresApproval = false
    private var savedMCPEnabled = false

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        savedPermissionMode = FeatureSettings.shared.mcpPermissionMode
        savedRequiresApproval = FeatureSettings.shared.mcpRequiresApproval
        savedMCPEnabled = FeatureSettings.shared.mcpEnabled
        FeatureSettings.shared.mcpPermissionMode = .allowAll
        FeatureSettings.shared.mcpRequiresApproval = false
        FeatureSettings.shared.mcpEnabled = true
        appModel = AppModel()
        overlayModel = OverlayTabsModel(appModel: appModel, restoreState: false)
        TerminalControlService.shared.register(overlayModel)
    }

    override func tearDown() {
        if let overlayModel {
            TerminalControlService.shared.unregister(overlayModel)
        }
        TerminalControlService.shared.activeOverlayModelProvider = nil
        FeatureSettings.shared.mcpPermissionMode = savedPermissionMode
        FeatureSettings.shared.mcpRequiresApproval = savedRequiresApproval
        FeatureSettings.shared.mcpEnabled = savedMCPEnabled
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        overlayModel = nil
        appModel = nil
        super.tearDown()
    }

    func testTabStatusUsesEffectiveStateForAutomation() throws {
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.status = .running
        session.isAtPrompt = false
        session.isShellLoading = false
        session.restoreAIMetadata(provider: "claude", sessionId: "session-123")
        appModel.sessionStatuses = [
            SessionStatus(
                id: "Claude-session-123",
                sessionId: "session-123",
                tool: "Claude",
                state: .idle,
                lastSeen: Date()
            )
        ]

        let response = TerminalControlService.shared.tabStatus(tabID: overlayModel.selectedTabID.uuidString)
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["status"] as? String, CommandStatus.idle.rawValue)
        XCTAssertEqual(json["is_at_prompt"] as? Bool, true)
        XCTAssertEqual(json["active_app"] as? String, "Claude")
        XCTAssertEqual(json["ai_provider"] as? String, "claude")
        XCTAssertEqual(json["ai_session_id"] as? String, "session-123")

        XCTAssertEqual(json["raw_status"] as? String, CommandStatus.running.rawValue)
        XCTAssertEqual(json["raw_is_at_prompt"] as? Bool, false)
        XCTAssertEqual(json["can_accept_exec"] as? Bool, false)
        XCTAssertEqual(json["exec_acceptance_mode"] as? String, "blocked")
        XCTAssertEqual(json["ready_for_exec"] as? Bool, false)
        XCTAssertEqual(json["readiness_reason"] as? String, "not_at_prompt")
        XCTAssertEqual(json["has_terminal_view"] as? Bool, false)
    }

    func testTabStatusIncludesReadyForExecWhenRawPromptAndViewAreAvailable() throws {
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.status = .running
        session.isShellLoading = false
        session.isAtPrompt = true

        let terminalView = RustTerminalView(frame: .zero)
        session.attachRustTerminal(terminalView)

        let response = TerminalControlService.shared.tabStatus(tabID: overlayModel.selectedTabID.uuidString)
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["can_accept_exec"] as? Bool, true)
        XCTAssertEqual(json["exec_acceptance_mode"] as? String, "immediate")
        XCTAssertEqual(json["ready_for_exec"] as? Bool, true)
        XCTAssertEqual(json["readiness_reason"] as? String, "ready")
        XCTAssertEqual(json["has_terminal_view"] as? Bool, true)
    }

    func testWaitForTabReadyReturnsImmediateSnapshotWhenExecCanBeAccepted() throws {
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.status = .idle
        session.isShellLoading = true
        session.isAtPrompt = true

        let response = TerminalControlService.shared.waitForTabReady(
            tabID: overlayModel.selectedTabID.uuidString,
            timeoutMs: 10
        )
        let json = try XCTUnwrap(parseJSONObject(response))
        let status = try XCTUnwrap(json["status"] as? [String: Any])

        XCTAssertEqual(json["can_accept_exec"] as? Bool, true)
        XCTAssertEqual(json["ready_for_exec"] as? Bool, false)
        XCTAssertEqual(json["timed_out"] as? Bool, false)
        XCTAssertEqual(status["exec_acceptance_mode"] as? String, "queued")
        XCTAssertEqual(status["readiness_reason"] as? String, "shell_loading")
    }

    func testWaitForTabReadyReturnsLastObservedStatusOnTimeout() throws {
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.status = .running
        session.isShellLoading = false
        session.isAtPrompt = false

        let response = TerminalControlService.shared.waitForTabReady(
            tabID: overlayModel.selectedTabID.uuidString,
            timeoutMs: 5
        )
        let json = try XCTUnwrap(parseJSONObject(response))
        let status = try XCTUnwrap(json["status"] as? [String: Any])

        XCTAssertEqual(json["can_accept_exec"] as? Bool, false)
        XCTAssertEqual(json["timed_out"] as? Bool, true)
        XCTAssertEqual(status["shell_loading"] as? Bool, false)
        XCTAssertEqual(status["exec_acceptance_mode"] as? String, "blocked")
        XCTAssertEqual(status["readiness_reason"] as? String, "not_at_prompt")
    }

    func testBackgroundTabCreationDisablesAutoFocusOnAttach() {
        overlayModel.newTab(selectNewTab: false)
        let backgroundSession = overlayModel.tabs.last?.session

        XCTAssertEqual(overlayModel.selectedTabID, overlayModel.tabs.first?.id)
        XCTAssertEqual(backgroundSession?.autoFocusOnAttachEnabled, false)

        overlayModel.newTab()
        let selectedSession = overlayModel.tabs.last?.session
        XCTAssertEqual(selectedSession?.autoFocusOnAttachEnabled, true)
    }

    func testCloseTabRejectsApprovalRequiredStatusWithoutForce() throws {
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.status = .approvalRequired

        let response = TerminalControlService.shared.closeTab(
            tabID: overlayModel.selectedTabID.uuidString,
            force: false
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["error"] as? String, "Tab has a running process (status: approvalRequired). Use force=true to close anyway.")
    }

    func testListTabsReturnsDeterministicControlPlaneIDs() throws {
        let response = TerminalControlService.shared.listTabs()
        let json = try XCTUnwrap(parseJSONArray(response))
        let first = try XCTUnwrap(json.first)

        XCTAssertEqual(first["tab_id"] as? String, "tab_1")
    }

    func testControlPlaneIDsAreReusedAfterTabClose() throws {
        // Aliases are assigned lazily — pin the initial tab to tab_1 first so
        // slot numbering below is deterministic.
        let firstTabID = try XCTUnwrap(overlayModel.tabs.first?.id)
        XCTAssertEqual(TerminalControlService.shared.controlPlaneTabID(for: firstTabID), "tab_1")

        overlayModel.newTab(selectNewTab: false)
        let createdID = try XCTUnwrap(overlayModel.tabs.last?.id)
        XCTAssertEqual(TerminalControlService.shared.controlPlaneTabID(for: createdID), "tab_2")

        _ = TerminalControlService.shared.closeTab(tabID: "tab_2", force: true)

        overlayModel.newTab(selectNewTab: false)
        let recreatedID = try XCTUnwrap(overlayModel.tabs.last?.id)
        XCTAssertEqual(TerminalControlService.shared.controlPlaneTabID(for: recreatedID), "tab_2")
    }

    func testCreateTabDefaultsToActiveOverlayWindow() throws {
        let secondAppModel = AppModel()
        let secondOverlayModel = OverlayTabsModel(appModel: secondAppModel, restoreState: false)
        TerminalControlService.shared.register(secondOverlayModel)
        defer { TerminalControlService.shared.unregister(secondOverlayModel) }

        TerminalControlService.shared.activeOverlayModelProvider = { secondOverlayModel }

        let firstWindowCount = overlayModel.tabs.count
        let secondWindowCount = secondOverlayModel.tabs.count

        let response = TerminalControlService.shared.createTab(directory: nil, windowID: nil)
        let json = try XCTUnwrap(parseJSONObject(response))

        // Window IDs increment monotonically per registration across the whole
        // process, so resolve the expected ID instead of hardcoding it.
        let expectedWindowID = TerminalControlService.shared.allModels
            .first(where: { $0.model === secondOverlayModel })?.windowID
        XCTAssertEqual(json["window_id"] as? Int, expectedWindowID)
        XCTAssertEqual(overlayModel.tabs.count, firstWindowCount)
        XCTAssertEqual(secondOverlayModel.tabs.count, secondWindowCount + 1)
        XCTAssertEqual(secondOverlayModel.selectedTabID, secondOverlayModel.tabs.first?.id)
    }

    func testIsToolAtPromptCanBeScopedToSessionID() throws {
        let promptSession = try XCTUnwrap(overlayModel.tabs.first?.session)
        promptSession.activeAppName = "Codex"
        promptSession.isAtPrompt = true
        promptSession.restoreAIMetadata(provider: "codex", sessionId: "session-prompt")

        overlayModel.newTab(selectNewTab: false)
        let activeSession = try XCTUnwrap(overlayModel.tabs.last?.session)
        activeSession.activeAppName = "Codex"
        activeSession.isAtPrompt = false
        activeSession.restoreAIMetadata(provider: "codex", sessionId: "session-active")

        XCTAssertTrue(TerminalControlService.shared.isToolAtPrompt(toolName: "Codex"))
        XCTAssertTrue(TerminalControlService.shared.isToolAtPrompt(toolName: "Codex", sessionID: "session-prompt"))
        XCTAssertFalse(TerminalControlService.shared.isToolAtPrompt(toolName: "Codex", sessionID: "session-active"))
    }

    func testUpdateSessionDirectorySkipsSessionAdoptionWhenAdoptionIsNotAllowed() throws {
        let root = try makeTempDirectoryTree(name: "aethyme", subpaths: ["packages/aethyme"])
        defer { removeTempDirectory(root) }
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.currentDirectory = root
        session.gitRootPath = root
        session.restoreAIMetadata(
            provider: "claude",
            sessionId: "d3da599e-f985-4eaf-a834-f9eb069d6802"
        )

        let updated = TerminalControlService.shared.updateSessionDirectoryAcrossWindows(
            tabID: tab.id,
            sessionID: "fc48a626-5528-403f-b7da-6e9386493643",
            directory: "\(root)/packages/aethyme",
            allowSessionIDAdoption: false
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(session.currentDirectory, "\(root)/packages/aethyme")
        XCTAssertEqual(session.lastAISessionId, "d3da599e-f985-4eaf-a834-f9eb069d6802")
    }

    func testRunCommandPrearmsAILoggingForKnownToolWithoutLaunchableLookup() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let tabID = TerminalControlService.shared.controlPlaneTabID(for: tab.id)
        let session = try XCTUnwrap(tab.session)
        session.currentDirectory = "/tmp"

        let response = TerminalControlService.shared.execInTab(
            tabID: tabID,
            command: "codex --model gpt-5.3-codex"
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["ok"] as? Bool, true)
        // execInTab pre-arms AI logging asynchronously on the main queue.
        XCTAssertTrue(waitUntil(timeout: 5.0) { session.activeAppName == "Codex" })
        XCTAssertNotNil(session.currentPTYLogPath())
    }

    func testSubmitPromptIssuesSecondEnterWhenCodexDraftPersists() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let tabID = TerminalControlService.shared.controlPlaneTabID(for: tab.id)
        let session = try XCTUnwrap(tab.session)
        session.activeAppName = "Codex"
        session.status = .running
        session.isAtPrompt = true
        session.cachedRemoteOutputText = "› Audit Chau7 MCP and report back with bugs and fixes"

        let response = TerminalControlService.shared.submitPrompt(tabID: tabID)
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["enter_count"] as? Int, 2)
        XCTAssertEqual(json["resolved_intermediate_prompt"] as? Bool, true)
    }

    func testTabOutputPTYLogReadsActiveSessionOutputBeforeClose() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.startAILoggingIfNeeded(toolName: "Codex", commandLine: "codex --model gpt-5.3-codex")
        session.aiLogSession?.recordOutput(Data("\u{1B}[32mWorking...\u{1B}[0m\n{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[],\"confidence\":\"high\"}\n".utf8))

        let response = TerminalControlService.shared.tabOutput(
            tabID: TerminalControlService.shared.controlPlaneTabID(for: tab.id),
            lines: 50,
            source: "pty_log"
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["source"] as? String, "pty_log")
        XCTAssertTrue((json["output"] as? String)?.contains("Working...") == true)
        XCTAssertTrue((json["output"] as? String)?.contains("\"summary\":\"ok\"") == true)
    }

    func testTabOutputPTYLogSupportsStablePolling() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.startAILoggingIfNeeded(toolName: "Codex", commandLine: "codex --model gpt-5.3-codex")
        session.aiLogSession?.recordOutput(
            Data(
                "line one\n__CHAU7_REVIEW_JSON_BEGIN__\n{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[],\"confidence\":\"high\"}\n__CHAU7_REVIEW_JSON_END__\n".utf8
            )
        )

        let response = TerminalControlService.shared.tabOutput(
            tabID: TerminalControlService.shared.controlPlaneTabID(for: tab.id),
            lines: 50,
            waitForStableMs: 300,
            source: "pty_log"
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["source"] as? String, "pty_log")
        XCTAssertTrue((json["output"] as? String)?.contains("__CHAU7_REVIEW_JSON_END__") == true)
    }

    func testTabOutputPTYLogPrefersTabLocalTranscriptOverProviderLog() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.startAILoggingIfNeeded(toolName: "Codex", commandLine: "codex")
        session.aiLogSession?.recordOutputSync(Data("provider-global-log-should-not-win\n".utf8))
        session.terminalTranscriptCapture.append(Data("tab-local-transcript-wins\n".utf8))

        let response = TerminalControlService.shared.tabOutput(
            tabID: TerminalControlService.shared.controlPlaneTabID(for: tab.id),
            lines: 50,
            source: "pty_log"
        )
        let json = try XCTUnwrap(parseJSONObject(response))
        let output = try XCTUnwrap(json["output"] as? String)

        XCTAssertEqual(json["source"] as? String, "pty_log")
        XCTAssertTrue(output.contains("tab-local-transcript-wins"))
        XCTAssertFalse(output.contains("provider-global-log-should-not-win"))
    }

    func testRepoGetEventsSupportsFilteringAndFullMessages() throws {
        let repoPath = "/tmp/chau7-review-repo"
        let selectedTabID = try XCTUnwrap(overlayModel.tabs.first?.id)
        let otherTabID = UUID()
        let longMessage = "Review complete\n__CHAU7_REVIEW_JSON_BEGIN__\n"
            + "{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[\"none\"],\"confidence\":\"high\"}\n"
            + "__CHAU7_REVIEW_JSON_END__\n"
            + String(repeating: "x", count: 300)

        appModel.eventsByRepo[repoPath] = [
            AIEvent(
                source: .runtime,
                type: "waiting_input",
                tool: "Codex",
                message: longMessage,
                ts: DateFormatters.nowISO8601(),
                repoPath: repoPath,
                tabID: selectedTabID,
                producer: "runtime_session_manager",
                reliability: .authoritative
            ),
            AIEvent(
                source: .runtime,
                type: "finished",
                tool: "Codex",
                message: "other tab",
                ts: DateFormatters.nowISO8601(),
                repoPath: repoPath,
                tabID: otherTabID,
                producer: "runtime_session_manager",
                reliability: .authoritative
            )
        ]

        let response = TerminalControlService.shared.repoGetEvents(
            repoPath: repoPath,
            limit: 10,
            tabID: "tab_1",
            eventTypes: ["waiting_input"],
            tool: "Codex",
            producer: "runtime_session_manager",
            truncateMessages: false
        )
        let json = try XCTUnwrap(parseJSONObject(response))
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let first = try XCTUnwrap(events.first)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(first["tab_id"] as? String, "tab_1")
        XCTAssertEqual(first["type"] as? String, "waiting_input")
        XCTAssertEqual(first["producer"] as? String, "runtime_session_manager")
        XCTAssertEqual(first["reliability"] as? String, AIEventReliability.authoritative.rawValue)
        XCTAssertEqual(first["message"] as? String, longMessage)
    }

    func testRenameTabPropagatesToAllSplitSessions() throws {
        overlayModel.splitCurrentTabHorizontally()
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let sessions = tab.splitController.terminalSessions.map(\.1)
        XCTAssertEqual(sessions.count, 2)

        let response = TerminalControlService.shared.renameTab(
            tabID: tab.id.uuidString,
            title: "Split Tab"
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["title"] as? String, "Split Tab")
        XCTAssertTrue(sessions.allSatisfy { $0.tabTitleOverride == "Split Tab" })
    }

    func testApplyNotificationStyleAcrossWindowsFindsTabInLaterWindow() throws {
        let secondAppModel = AppModel()
        let secondOverlayModel = OverlayTabsModel(appModel: secondAppModel, restoreState: false)
        TerminalControlService.shared.register(secondOverlayModel)
        defer { TerminalControlService.shared.unregister(secondOverlayModel) }

        let secondTabID = try XCTUnwrap(secondOverlayModel.tabs.first?.id)
        let resolvedTabID = TerminalControlService.shared.applyNotificationStyleAcrossWindows(
            to: secondTabID,
            stylePreset: "attention",
            config: [:]
        )

        XCTAssertEqual(resolvedTabID, secondTabID)
        XCTAssertNil(overlayModel.tabs.first?.notificationStyle)
        XCTAssertEqual(secondOverlayModel.tabs.first?.notificationStyle, .attention)
    }

    func testApplyNotificationStyleAcrossWindowsTreatsUnchangedStyleAsSuccess() throws {
        let tabID = try XCTUnwrap(overlayModel.tabs.first?.id)
        overlayModel.tabs[0].notificationStyle = .attention

        let resolvedTabID = TerminalControlService.shared.applyNotificationStyleAcrossWindows(
            to: tabID,
            stylePreset: "attention",
            config: [:]
        )

        XCTAssertEqual(resolvedTabID, tabID)
        XCTAssertEqual(overlayModel.tabs.first?.notificationStyle, .attention)
    }

    func testUpdateSessionDirectoryAppliesWhenSessionMatchesLiveAISession() throws {
        let root = try makeTempDirectoryTree(name: "repo", subpaths: ["subdir"])
        defer { removeTempDirectory(root) }
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.lastAISessionId = "session-live"
        // Seed a cwd inside the same repo so the directory sanity check
        // (introduced by 606a0dc, refined by feb677d) treats the writeback
        // as a normal within-repo cd rather than a foreign event. Without
        // this seed the test would fail under the two-axis policy because
        // the default cwd is unrelated to the repo subdir.
        session.updateCurrentDirectory(root)
        let originalCwd = session.currentDirectory

        let applied = TerminalControlService.shared.updateSessionDirectoryAcrossWindows(
            tabID: tab.id,
            sessionID: "session-live",
            directory: "\(root)/subdir"
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(session.currentDirectory, "\(root)/subdir")
        XCTAssertNotEqual(session.currentDirectory, originalCwd)
    }

    func testUpdateSessionDirectorySkipsWhenSessionIsStale() throws {
        // The motivating bug: a tab hosting Claude session 'live' has its cwd
        // oscillated by stale events arriving from a previously-resumed Claude
        // session 'stale' that still emits to claude-events.jsonl.
        let pinned = try makeTempDirectoryTree(name: "live-path")
        defer { removeTempDirectory(pinned) }
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.lastAISessionId = "session-live"
        session.updateCurrentDirectory(pinned)

        let applied = TerminalControlService.shared.updateSessionDirectoryAcrossWindows(
            tabID: tab.id,
            sessionID: "session-stale",
            directory: "/tmp/stale-path"
        )

        XCTAssertFalse(applied)
        XCTAssertEqual(session.currentDirectory, pinned)
    }

    func testUpdateSessionDirectoryAdoptsNewSessionWhenDirectoryRelates() throws {
        // The stuck-binding case the user hit on Eval: a stale lastAISessionId
        // from a previous claude invocation was persisted. The user restarted
        // claude in the same tab — new sessionID, same repo. Without this
        // logic the legitimate event for the new session is refused forever.
        let root = try makeTempDirectoryTree(name: "aethyme", subpaths: ["subdir"])
        defer { removeTempDirectory(root) }
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.lastAISessionId = "stale-from-disk"
        session.updateCurrentDirectory(root)
        session.gitRootPath = root

        let applied = TerminalControlService.shared.updateSessionDirectoryAcrossWindows(
            tabID: tab.id,
            sessionID: "fresh-claude-session",
            directory: "\(root)/subdir"
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(session.currentDirectory, "\(root)/subdir")
        XCTAssertEqual(
            session.lastAISessionId,
            "fresh-claude-session",
            "Tab adopts the new sessionID when directory confirms the event is for this tab"
        )
    }

    func testUpdateSessionDirectoryRefusesForeignDirectoryEvenWhenSessionMatches() throws {
        // The stuck-binding case: lastAISessionId was persisted from a prior
        // misattribution (now removed at source by other commits), so a new
        // event arrives whose sessionID matches the stale value. The session
        // check passes, but the directory is clearly foreign to this tab.
        let root = try makeTempDirectoryTree(name: "aethyme")
        defer { removeTempDirectory(root) }
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.lastAISessionId = "session-bound-from-disk"
        session.updateCurrentDirectory(root)
        session.gitRootPath = root

        let applied = TerminalControlService.shared.updateSessionDirectoryAcrossWindows(
            tabID: tab.id,
            sessionID: "session-bound-from-disk",
            directory: "/tmp/totally-unrelated-repo"
        )

        XCTAssertFalse(applied)
        XCTAssertEqual(
            session.currentDirectory,
            root,
            "Foreign directory write must be refused even when session ids agree"
        )
    }

    func testUpdateSessionDirectoryAcceptsRelatedDirectory() throws {
        // Regression-guard the inverse: cd'ing within the same repo (parent →
        // subdir) must still be applied; this is the legitimate Claude-TUI
        // chpwd-replacement path that the foreign-cwd refusal must not block.
        let root = try makeTempDirectoryTree(name: "repo", subpaths: ["subdir"])
        defer { removeTempDirectory(root) }
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.lastAISessionId = "session-live"
        session.updateCurrentDirectory(root)
        session.gitRootPath = root

        let applied = TerminalControlService.shared.updateSessionDirectoryAcrossWindows(
            tabID: tab.id,
            sessionID: "session-live",
            directory: "\(root)/subdir"
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(session.currentDirectory, "\(root)/subdir")
    }

    func testUpdateSessionDirectoryAppliesWhenTabHasNoLiveAISessionYet() throws {
        // First-event-binding case: tab restored without a live AI session
        // identity yet AND no cwd/gitRoot anchor. With both signals empty
        // shouldRefuseCwdWriteAsForeign returns false (no anchor to reject
        // against), so the writeback seeds the very first cwd.
        let root = try makeTempDirectoryTree(name: "first-bind")
        defer { removeTempDirectory(root) }
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.lastAISessionId = nil
        session.currentDirectory = ""
        session.gitRootPath = nil

        let applied = TerminalControlService.shared.updateSessionDirectoryAcrossWindows(
            tabID: tab.id,
            sessionID: "session-first",
            directory: root
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(session.currentDirectory, root)
    }

    private func makeTempDirectoryTree(name: String, subpaths: [String] = []) throws -> String {
        let root = "/tmp/chau7-tcs-\(name)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for sub in subpaths {
            try FileManager.default.createDirectory(atPath: "\(root)/\(sub)", withIntermediateDirectories: true)
        }
        return root
    }

    private func removeTempDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func parseJSONArray(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return json
    }

    func testAgentLaunchCommandWithoutPRIsAgentCommandVerbatim() {
        XCTAssertEqual(
            TerminalControlService.agentLaunchCommand(agentCommand: "claude", prNumber: nil),
            "claude"
        )
    }

    func testAgentLaunchCommandWithPRPrependsCheckout() {
        XCTAssertEqual(
            TerminalControlService.agentLaunchCommand(agentCommand: "codex", prNumber: 323),
            "gh pr checkout 323 && codex"
        )
    }

    func testPromptVisibilityNeedlesUseMeaningfulPromptLines() {
        let needles = TerminalControlService.promptVisibilityNeedles(from: """

        MAGI independent analysis
        Run: magi-123
        Round: round-1
        Short
        This line should not be reached
        """)

        XCTAssertEqual(
            needles,
            [
                "MAGI independent analysis",
                "Run: magi-123",
                "Round: round-1"
            ]
        )
    }

    func testAgentStatusReportsRunningUsesRawStatusWhenEffectiveStateLags() {
        XCTAssertTrue(TerminalControlService.agentStatusReportsRunning([
            "active_app": "Codex",
            "ai_provider": "codex",
            "status": CommandStatus.idle.rawValue,
            "raw_status": CommandStatus.running.rawValue
        ]))
    }

    func testAgentStatusReportsRunningRequiresAgentIdentity() {
        XCTAssertFalse(TerminalControlService.agentStatusReportsRunning([
            "status": CommandStatus.running.rawValue,
            "raw_status": CommandStatus.running.rawValue
        ]))
    }

    func testAgentPromptInjectionTimeoutCapsBelowMCPReadBudget() {
        XCTAssertEqual(TerminalControlService.agentPromptInjectionTimeoutMs(readyTimeoutMs: 60_000), 25_000)
        XCTAssertEqual(TerminalControlService.agentPromptInjectionTimeoutMs(readyTimeoutMs: 10_000), 10_000)
        XCTAssertEqual(TerminalControlService.agentPromptInjectionTimeoutMs(readyTimeoutMs: -1), 0)
    }

    func testAgentLaunchExitedBeforePromptDetectsReturnedShellWithStaleProvider() {
        XCTAssertTrue(TerminalControlService.agentLaunchExitedBeforePrompt([
            "active_app": "Codex",
            "ai_provider": "codex",
            "status": CommandStatus.done.rawValue,
            "raw_status": CommandStatus.done.rawValue,
            "is_at_prompt": true,
            "raw_is_at_prompt": true,
            "can_accept_exec": true,
            "ready_for_exec": true
        ]))
    }

    func testAgentLaunchExitedBeforePromptIgnoresInitialIdlePrompt() {
        XCTAssertFalse(TerminalControlService.agentLaunchExitedBeforePrompt([
            "active_app": "Codex",
            "ai_provider": "codex",
            "status": CommandStatus.idle.rawValue,
            "raw_status": CommandStatus.idle.rawValue,
            "is_at_prompt": true,
            "raw_is_at_prompt": true,
            "can_accept_exec": true,
            "ready_for_exec": true
        ]))
    }

    func testAgentLaunchExitedBeforePromptIgnoresLiveRawAgent() {
        XCTAssertFalse(TerminalControlService.agentLaunchExitedBeforePrompt([
            "active_app": "Codex",
            "raw_active_app": "Codex",
            "ai_provider": "codex",
            "status": CommandStatus.done.rawValue,
            "raw_status": CommandStatus.done.rawValue,
            "is_at_prompt": true,
            "raw_is_at_prompt": true,
            "can_accept_exec": true,
            "ready_for_exec": true
        ]))
    }

    func testAgentOutputLooksResponsiveForCodexSurface() {
        XCTAssertTrue(TerminalControlService.agentOutputLooksResponsive("""
        ╭──────────────────────────────────────────────────╮
        │ >_ OpenAI Codex (v0.142.5)                       │
        ╰──────────────────────────────────────────────────╯
        • Queued follow-up inputs
        """))
    }

    func testAgentOutputLooksResponsiveDoesNotTreatPromptTextAsAgentResponse() {
        XCTAssertFalse(TerminalControlService.agentOutputLooksResponsive("""
        MAGI independent analysis
        Run: magi-123
        Round: round-1
        Work independently in this round.
        """))
    }

    func testAgentOutputLooksResponsiveDoesNotMatchProviderEchoOnly() {
        XCTAssertFalse(TerminalControlService.agentOutputLooksResponsive("""
        MAGI independent analysis
        Member: Casper
        Provider: codex
        Question: What is the best Final Fantasy
        """, provider: "codex"))
    }

    func testAgentOutputLooksInputReadyForCodexSurface() {
        XCTAssertTrue(TerminalControlService.agentOutputLooksInputReady("""
        ╭──────────────────────────────────────────────────╮
        │ >_ OpenAI Codex (v0.142.5)                       │
        ╰──────────────────────────────────────────────────╯
        gpt-5-codex
        """, provider: "codex"))
    }

    func testAgentOutputLooksInputReadyDoesNotTreatPromptEchoAsReady() {
        XCTAssertFalse(TerminalControlService.agentOutputLooksInputReady("""
        MAGI independent analysis
        Member: Casper
        Provider: codex
        Question: What is the best Final Fantasy
        """, provider: "codex"))
    }
}
