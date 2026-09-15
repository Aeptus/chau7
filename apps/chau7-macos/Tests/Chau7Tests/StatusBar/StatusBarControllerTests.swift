import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class StatusBarControllerTests: XCTestCase {

    // MARK: - Singleton

    func testSharedInstanceIsSingleton() {
        let first = StatusBarController.shared
        let second = StatusBarController.shared
        XCTAssertTrue(
            first === second,
            "StatusBarController.shared should always return the same instance"
        )
    }

    // MARK: - Initial State

    func testInitialStateHasNoStatusItem() {
        // Before setup(model:), the controller should have no status item or popover.
        // We verify this indirectly by calling cleanup without setup -- it should not crash.
        let controller = StatusBarController.shared
        // cleanup() is safe to call even when not set up
        controller.cleanup()
    }

    // MARK: - Cleanup Idempotency

    func testCleanupIsIdempotent() {
        let controller = StatusBarController.shared
        // Calling cleanup multiple times should not crash
        controller.cleanup()
        controller.cleanup()
        controller.cleanup()
    }

    // MARK: - Update Icon Without Setup

    func testUpdateIconWithoutSetupDoesNotCrash() {
        let controller = StatusBarController.shared
        controller.cleanup() // Ensure clean state
        // updateIcon is @objc and could be called via notification even if
        // statusItem is nil. It should guard safely.
        controller.updateIcon()
    }

    // MARK: - Notification Integration

    func testMonitoringStateChangedNotificationName() {
        // The controller observes `.monitoringStateChanged`; the panel posts the same
        // production constant. The raw value moved to the com.chau7. namespace when
        // the AppSignals registry centralized every internal Notification.Name
        // (process-internal only, so the rename is safe).
        XCTAssertEqual(
            Notification.Name.monitoringStateChanged.rawValue,
            "com.chau7.monitoringStateChanged",
            "Notification name should match the registry constant"
        )
    }

    func testCommandCenterViewModelLiveSessionsUseAgnosticSourceAndLimitToFive() {
        let model = AppModel()
        let sessions = [
            makeSummary(id: "6", state: .running, lastActivityOffset: 5),
            makeSummary(id: "5", state: .waitingInput, lastActivityOffset: 10),
            makeSummary(id: "4", state: .stuck, lastActivityOffset: 20),
            makeSummary(id: "3", state: .running, lastActivityOffset: 30),
            makeSummary(id: "2", state: .running, lastActivityOffset: 40),
            makeSummary(id: "1", state: .running, lastActivityOffset: 50)
        ]

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(sessionSource: { sessions }),
            autoRefresh: false
        )

        XCTAssertEqual(
            viewModel.liveSessions.map(\.id),
            ["6", "5", "4", "3", "2"],
            "Live sessions should come from the AI-agnostic source, newest first, and cap at five"
        )
        XCTAssertEqual(viewModel.totalLiveSessionCount, 6)
    }

    func testCommandCenterViewModelAttentionSessionsUseWaitingInputWhenNoApprovalIsPending() {
        let model = AppModel()
        let sessions = [
            makeSummary(id: "input", state: .waitingInput, lastActivityOffset: 10),
            makeSummary(id: "stuck", state: .stuck, lastActivityOffset: 20),
            makeSummary(id: "running", state: .running, lastActivityOffset: 5)
        ]

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(sessionSource: { sessions }),
            autoRefresh: false
        )

        XCTAssertEqual(
            viewModel.attentionSessions.map(\.id),
            ["input"],
            "Waiting input should be the primary attention state when no approval is pending."
        )
        XCTAssertEqual(
            viewModel.badgeCounts,
            CommandCenterBadgeCounts(liveCount: 3, approvalRequiredCount: 0, waitingInputCount: 1)
        )
        XCTAssertEqual(viewModel.primaryAttentionKind, .waitingForInput)
        XCTAssertEqual(viewModel.attentionCount, 1)
    }

    func testCommandCenterViewModelPrioritizesApprovalRequiredBadgeCounts() {
        let model = AppModel()
        let sessions = [
            makeSummary(id: "approval-newer", state: .approvalRequired, lastActivityOffset: 5),
            makeSummary(id: "input", state: .waitingInput, lastActivityOffset: 10),
            makeSummary(id: "approval-older", state: .approvalRequired, lastActivityOffset: 20),
            makeSummary(id: "running", state: .running, lastActivityOffset: 1)
        ]

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(sessionSource: { sessions }),
            autoRefresh: false
        )

        XCTAssertEqual(
            viewModel.badgeCounts,
            CommandCenterBadgeCounts(liveCount: 4, approvalRequiredCount: 2, waitingInputCount: 1)
        )
        XCTAssertEqual(viewModel.primaryAttentionKind, .approvalRequired)
        XCTAssertEqual(viewModel.attentionCount, 2)
        XCTAssertEqual(
            viewModel.attentionSessions.map(\.id),
            ["approval-newer", "approval-older"],
            "Approval-required sessions should be the only hero/badge attention bucket while approvals are pending."
        )
    }

    func testCommandCenterViewModelRefreshUpdatesBadgeCountsAndCallback() {
        let model = AppModel()
        var sessions = [
            makeSummary(id: "input-1", state: .waitingInput, lastActivityOffset: 5),
            makeSummary(id: "running-1", state: .running, lastActivityOffset: 10),
            makeSummary(id: "stuck-1", state: .stuck, lastActivityOffset: 15)
        ]

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(sessionSource: { sessions }),
            autoRefresh: false
        )

        XCTAssertEqual(
            viewModel.badgeCounts,
            CommandCenterBadgeCounts(liveCount: 3, approvalRequiredCount: 0, waitingInputCount: 1)
        )
        XCTAssertEqual(viewModel.liveSessions.map(\.id), ["input-1", "running-1", "stuck-1"])
        XCTAssertEqual(viewModel.attentionSessions.map(\.id), ["input-1"])

        var observedBadgeCounts: [CommandCenterBadgeCounts] = []
        viewModel.onBadgeCountsChange = { observedBadgeCounts.append($0) }

        sessions = [
            makeSummary(id: "input-2", state: .waitingInput, lastActivityOffset: 1),
            makeSummary(id: "input-3", state: .waitingInput, lastActivityOffset: 2),
            makeSummary(id: "running-2", state: .running, lastActivityOffset: 3),
            makeSummary(id: "stuck-2", state: .stuck, lastActivityOffset: 4),
            makeSummary(id: "running-3", state: .running, lastActivityOffset: 5),
            makeSummary(id: "running-4", state: .running, lastActivityOffset: 6)
        ]

        viewModel.refreshSessions()

        XCTAssertEqual(
            viewModel.badgeCounts,
            CommandCenterBadgeCounts(liveCount: 6, approvalRequiredCount: 0, waitingInputCount: 2)
        )
        XCTAssertEqual(viewModel.totalLiveSessionCount, 6)
        XCTAssertEqual(viewModel.attentionCount, 2)
        XCTAssertEqual(
            viewModel.liveSessions.map(\.id),
            ["input-2", "input-3", "running-2", "stuck-2", "running-3"],
            "Live sessions should remain capped at five after refresh."
        )
        XCTAssertEqual(viewModel.attentionSessions.map(\.id), ["input-2", "input-3"])
        XCTAssertEqual(
            observedBadgeCounts,
            [CommandCenterBadgeCounts(liveCount: 6, approvalRequiredCount: 0, waitingInputCount: 2)]
        )
    }

    func testCommandCenterViewModelHeroStatusUsesOpinionatedPriority() {
        withRestoredMonitoringPreference {
            let model = AppModel()
            model.isMonitoring = false
            let sessions = [
                makeSummary(id: "running", state: .running, lastActivityOffset: 1),
                makeSummary(id: "input", state: .waitingInput, lastActivityOffset: 2),
                makeSummary(id: "approval", state: .approvalRequired, lastActivityOffset: 3)
            ]

            let viewModel = CommandCenterViewModel(
                model: model,
                environment: .testing(sessionSource: { sessions }),
                autoRefresh: false
            )

            XCTAssertEqual(viewModel.heroStatus.tone, .approvalRequired)
            XCTAssertEqual(viewModel.heroStatus.title, L("statusBar.hero.approvalRequired", "Approval required"))
        }
    }

    func testCommandCenterViewModelHeroStatusShowsMonitoringPausedBeforeRunning() {
        withRestoredMonitoringPreference {
            let model = AppModel()
            model.isMonitoring = false
            let sessions = [
                makeSummary(id: "running", state: .running, lastActivityOffset: 1)
            ]
            let viewModel = CommandCenterViewModel(
                model: model,
                environment: .testing(sessionSource: { sessions }),
                autoRefresh: false
            )

            XCTAssertEqual(viewModel.heroStatus.tone, .monitoringPaused)
            XCTAssertEqual(viewModel.heroStatus.title, L("statusBar.hero.monitoringPaused", "Monitoring paused"))
        }
    }

    func testCommandCenterViewModelHeroStatusShowsRunningThenQuiet() {
        withRestoredMonitoringPreference {
            let runningModel = AppModel()
            runningModel.isMonitoring = true
            let runningSessions = [
                makeSummary(id: "running-1", state: .running, lastActivityOffset: 1),
                makeSummary(id: "running-2", state: .running, lastActivityOffset: 2)
            ]
            let runningViewModel = CommandCenterViewModel(
                model: runningModel,
                environment: .testing(sessionSource: { runningSessions }),
                autoRefresh: false
            )

            XCTAssertEqual(runningViewModel.heroStatus.tone, .running)
            XCTAssertEqual(runningViewModel.heroStatus.title, L("statusBar.hero.running.plural", "%d sessions running", 2))

            let quietModel = AppModel()
            quietModel.isMonitoring = true
            let quietViewModel = CommandCenterViewModel(
                model: quietModel,
                environment: .testing(sessionSource: { [] }),
                autoRefresh: false
            )

            XCTAssertEqual(quietViewModel.heroStatus.tone, .quiet)
            XCTAssertEqual(quietViewModel.heroStatus.title, L("statusBar.hero.quiet", "Quiet"))
        }
    }

    func testCommandCenterViewModelActionSessionsPrioritizeAttentionThenRunningAndCapAtFive() {
        let model = AppModel()
        let sessions = [
            makeSummary(id: "stuck-new", state: .stuck, lastActivityOffset: 0),
            makeSummary(id: "running-new", state: .running, lastActivityOffset: 1),
            makeSummary(id: "waiting-new", state: .waitingInput, lastActivityOffset: 2),
            makeSummary(id: "approval-new", state: .approvalRequired, lastActivityOffset: 10),
            makeSummary(id: "waiting-old", state: .waitingInput, lastActivityOffset: 50),
            makeSummary(id: "running-old", state: .running, lastActivityOffset: 80),
            makeSummary(id: "approval-old", state: .approvalRequired, lastActivityOffset: 90)
        ]

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(sessionSource: { sessions }),
            autoRefresh: false
        )

        XCTAssertEqual(
            viewModel.actionSessions.map(\.id),
            ["approval-new", "approval-old", "waiting-new", "waiting-old", "running-new"],
            "The popover action list should show attention first, running sessions second, and never exceed five rows."
        )
    }

    func testPhaseEightRegressionCollectsSessionsAcrossWindowsAndStates() {
        let running = makeOverlayModelWithLiveSession(
            directory: "/tmp/window-running",
            status: .running,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let waiting = makeOverlayModelWithLiveSession(
            directory: "/tmp/window-waiting",
            status: .waitingForInput,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let stuck = makeOverlayModelWithLiveSession(
            directory: "/tmp/window-stuck",
            status: .stuck,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let approval = makeOverlayModelWithLiveSession(
            directory: "/tmp/window-approval",
            status: .approvalRequired,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_300)
        )

        let summaries = CommandCenterSessionSummary.collectLiveSessions(in: [
            running,
            waiting,
            stuck,
            approval
        ])

        XCTAssertEqual(
            summaries.map(\.directory),
            ["/tmp/window-approval", "/tmp/window-stuck", "/tmp/window-waiting", "/tmp/window-running"]
        )
        XCTAssertEqual(
            summaries.map(\.state),
            [.approvalRequired, .stuck, .waitingInput, .running]
        )
    }

    func testPhaseEightRegressionPresentsApprovalWaitingAndStuckDistinctly() {
        XCTAssertEqual(
            CommandCenterSessionPresentation.presentation(for: .approvalRequired),
            CommandCenterSessionPresentation(
                symbolName: "hand.raised",
                description: L("statusBar.session.approvalRequired", "Approval required"),
                tone: .approvalRequired,
                needsAttention: true
            )
        )
        XCTAssertEqual(
            CommandCenterSessionPresentation.presentation(for: .waitingInput),
            CommandCenterSessionPresentation(
                symbolName: "bubble.left.and.exclamationmark.bubble.right",
                description: L("statusBar.session.waitingInput", "Waiting for input"),
                tone: .waitingInput,
                needsAttention: true
            )
        )
        XCTAssertEqual(
            CommandCenterSessionPresentation.presentation(for: .stuck),
            CommandCenterSessionPresentation(
                symbolName: "exclamationmark.triangle",
                description: L("statusBar.session.stuck", "No recent output"),
                tone: .stuck,
                needsAttention: false
            )
        )
    }

    func testPhaseEightRegressionBadgePresenterPrioritizesApprovalOverWaiting() {
        let presentation = StatusBarIconPresenter.presentation(
            isMonitoring: true,
            badgeCounts: CommandCenterBadgeCounts(
                liveCount: 6,
                approvalRequiredCount: 2,
                waitingInputCount: 4
            )
        )

        XCTAssertEqual(presentation.symbolName, "bell.badge.fill")
        XCTAssertEqual(presentation.title, "2")
        XCTAssertEqual(
            presentation.tooltip,
            L(
                "statusBar.icon.tooltip",
                "%@: %@",
                L("app.name", "Chau7"),
                L("statusBar.icon.approval.plural", "%d approvals required", 2)
            )
        )
    }

    func testCommandCenterSessionSummaryPreservesApprovalRequiredState() {
        XCTAssertEqual(CommandCenterSessionSummary.state(for: .approvalRequired), .approvalRequired)
        XCTAssertFalse(CommandCenterSessionSummary.state(for: .approvalRequired) == .waitingInput)
        XCTAssertEqual(CommandCenterSessionSummary.State.approvalRequired.attentionKind, .approvalRequired)
        XCTAssertEqual(CommandCenterSessionSummary.State.approvalRequired.dashboardAgentState, .awaitingApproval)
        XCTAssertEqual(CommandCenterSessionSummary.State.waitingInput.attentionKind, .waitingForInput)
        XCTAssertEqual(CommandCenterSessionSummary.State.waitingInput.dashboardAgentState, .waitingInput)
    }

    func testCommandCenterViewModelTabTargetUsesExactTabIDAndDirectory() {
        let model = AppModel()
        let session = makeSummary(id: "target", state: .running, lastActivityOffset: 5)
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(sessionSource: { [session] }),
            autoRefresh: false
        )

        let target = viewModel.tabTarget(for: session)

        XCTAssertEqual(target.tool, "Codex")
        XCTAssertEqual(target.directory, "/tmp/target")
        XCTAssertEqual(target.tabID, UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }

    func testCommandCenterViewModelTimelineUsesRecentEventsSuffixAndCapsAtEight() {
        let model = AppModel()
        model.recentEvents = (0 ..< 10).map { index in
            makeEvent(index: index, message: "raw-\(index)")
        }
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(),
            autoRefresh: false
        )

        let timeline = viewModel.unifiedTimeline(historyEntries: [])

        XCTAssertEqual(timeline.count, 8)
        XCTAssertEqual(
            timeline.map(\.detail),
            Array((2 ..< 10).reversed()).map { "raw-\($0)" },
            "The current timeline takes the last eight raw events, then sorts them newest-first."
        )
    }

    func testCommandCenterViewModelTimelineKeepsUnrelatedEventsWithinTwoSeconds() {
        let model = AppModel()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let unrelatedRawEvent = makeEvent(
            index: 1,
            timestamp: baseDate.addingTimeInterval(1),
            message: "raw-near-history"
        )
        model.recentEvents = [unrelatedRawEvent]

        let historyEntry = makeHistoryEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            timestamp: baseDate,
            message: "history-entry"
        )
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(),
            autoRefresh: false
        )

        let timeline = viewModel.unifiedTimeline(historyEntries: [historyEntry])

        XCTAssertEqual(
            timeline.map(\.detail),
            ["raw-near-history", "history-entry"],
            "Timeline dedup should not drop unrelated events only because they happened near a notification."
        )
    }

    func testCommandCenterViewModelTimelinePrefersNotificationHistoryForMatchingRawEvent() {
        let model = AppModel()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        model.recentEvents = [
            makeEvent(
                index: 1,
                id: eventID,
                type: "finished",
                timestamp: baseDate.addingTimeInterval(1),
                message: "raw-loses"
            )
        ]

        let historyEntry = makeHistoryEntry(
            id: eventID,
            timestamp: baseDate,
            message: "history-wins"
        )
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(),
            autoRefresh: false
        )

        let timeline = viewModel.unifiedTimeline(historyEntries: [historyEntry])

        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline.first?.detail, "history-wins")
        XCTAssertFalse(timeline.contains { $0.detail == "raw-loses" })
    }

    func testCommandCenterViewModelTimelineKeepsDistinctEventIDsWithMatchingFields() {
        let model = AppModel()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let historyID = UUID(uuidString: "00000000-0000-0000-0000-000000000121")!
        let rawID = UUID(uuidString: "00000000-0000-0000-0000-000000000122")!
        model.recentEvents = [
            makeEvent(
                index: 1,
                id: rawID,
                type: "finished",
                timestamp: baseDate.addingTimeInterval(1),
                message: "same-message"
            )
        ]

        let historyEntry = makeHistoryEntry(
            id: historyID,
            timestamp: baseDate,
            message: "same-message"
        )
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(),
            autoRefresh: false
        )

        let timeline = viewModel.unifiedTimeline(historyEntries: [historyEntry])

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(Set(timeline.map(\.id)), [historyID, rawID])
    }

    func testCommandCenterViewModelTimelineUsesUnknownToolSourceFallback() {
        let model = AppModel()
        model.recentEvents = [
            makeEvent(
                index: 1,
                source: AIEventSource(rawValue: "mystery_tool"),
                type: "finished",
                tool: "",
                message: "custom completed"
            )
        ]
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(),
            autoRefresh: false
        )

        let timeline = viewModel.unifiedTimeline(historyEntries: [])

        XCTAssertEqual(timeline.first?.title, "Mystery Tool: Finished")
        XCTAssertEqual(timeline.first?.detail, "custom completed")
    }

    func testCommandCenterViewModelTimelineUsesRegistryDerivedDisplayNames() {
        let model = AppModel()
        model.recentEvents = [
            makeEvent(
                index: 1,
                source: .copilot,
                type: "finished",
                tool: "copilot-cli",
                message: "done"
            )
        ]
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(),
            autoRefresh: false
        )

        let timeline = viewModel.unifiedTimeline(historyEntries: [])

        XCTAssertEqual(timeline.first?.title, "GitHub Copilot: Finished")
    }

    func testPhaseEightRegressionTimelineUsesCanonicalFormatterAndHistoryIdentity() {
        let model = AppModel()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let matchingID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        model.recentEvents = [
            makeEvent(
                index: 1,
                id: matchingID,
                type: "finished",
                timestamp: baseDate,
                message: "raw-duplicate"
            ),
            makeEvent(
                index: 2,
                source: .copilot,
                type: "finished",
                tool: "copilot-cli",
                timestamp: baseDate.addingTimeInterval(10),
                message: "registry-formatted"
            )
        ]
        let historyEntry = makeHistoryEntry(
            id: matchingID,
            timestamp: baseDate.addingTimeInterval(1),
            message: "history-canonical"
        )
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(),
            autoRefresh: false
        )

        let timeline = viewModel.unifiedTimeline(historyEntries: [historyEntry])

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline.map(\.detail), ["registry-formatted", "history-canonical"])
        XCTAssertEqual(timeline.first?.title, "GitHub Copilot: Finished")
        XCTAssertFalse(timeline.contains { $0.detail == "raw-duplicate" })
    }

    func testCommandCenterViewModelUsesInjectedNotificationHistorySource() {
        let model = AppModel()
        let historyEntry = makeHistoryEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            timestamp: Date(timeIntervalSince1970: 1_800_000_100),
            message: "history-from-environment"
        )
        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(notificationHistorySource: { [historyEntry] }),
            autoRefresh: false
        )

        XCTAssertEqual(viewModel.unifiedTimeline().map(\.detail), ["history-from-environment"])
    }

    func testCommandCenterViewModelUsesInjectedActionsAndClosesPopover() {
        let model = AppModel()
        let session = makeSummary(id: "target", state: .waitingInput, lastActivityOffset: 1)
        let snippet = makeSnippetEntry(id: "quick")
        var focusedSessions: [CommandCenterSessionSummary] = []
        var openedSettingsRoutes: [(section: SettingsSection?, anchorID: String?)] = []
        var insertedSnippets: [SnippetEntry] = []
        var closeCount = 0

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(
                sessionSource: { [session] },
                focusSession: { focusedSessions.append($0) },
                openSettings: { section, anchorID in
                    openedSettingsRoutes.append((section, anchorID))
                },
                insertSnippet: {
                    insertedSnippets.append($0)
                    return .inserted
                },
                closePopover: { closeCount += 1 }
            ),
            autoRefresh: false
        )

        viewModel.focusSession(session)
        viewModel.openSettings()
        viewModel.executeSnippet(snippet)

        XCTAssertEqual(focusedSessions, [session])
        XCTAssertEqual(openedSettingsRoutes.count, 1)
        XCTAssertNil(openedSettingsRoutes.first?.section)
        XCTAssertNil(openedSettingsRoutes.first?.anchorID)
        XCTAssertEqual(insertedSnippets, [snippet])
        XCTAssertEqual(closeCount, 3)
    }

    func testCommandCenterViewModelRoutesStatusPanelSettingsIntents() {
        let model = AppModel()
        var openedSettingsRoutes: [(section: SettingsSection?, anchorID: String?)] = []
        var closeCount = 0

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(
                openSettings: { section, anchorID in
                    openedSettingsRoutes.append((section, anchorID))
                },
                closePopover: { closeCount += 1 }
            ),
            autoRefresh: false
        )

        viewModel.openDefaultSettings()
        viewModel.openMonitoringSettings()
        viewModel.openPinnedSnippetSettings()

        XCTAssertEqual(openedSettingsRoutes.count, 3)
        XCTAssertEqual(openedSettingsRoutes[0].section, .startHere)
        XCTAssertNil(openedSettingsRoutes[0].anchorID)
        XCTAssertEqual(openedSettingsRoutes[1].section, .notifications)
        XCTAssertEqual(openedSettingsRoutes[1].anchorID, "eventMonitoring")
        XCTAssertEqual(openedSettingsRoutes[2].section, .snippetsTools)
        XCTAssertEqual(openedSettingsRoutes[2].anchorID, "snippets")
        XCTAssertEqual(closeCount, 3)
    }

    func testCommandCenterViewModelSnippetFallbackShowsCopiedAndKeepsPopoverOpen() {
        let model = AppModel()
        let snippet = makeSnippetEntry(id: "fallback")
        var insertedSnippets: [SnippetEntry] = []
        var closeCount = 0

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(
                insertSnippet: {
                    insertedSnippets.append($0)
                    return .copiedToClipboard
                },
                closePopover: { closeCount += 1 }
            ),
            autoRefresh: false
        )

        viewModel.executeSnippet(snippet)

        XCTAssertEqual(insertedSnippets, [snippet])
        XCTAssertEqual(viewModel.copiedSnippetID, snippet.id)
        XCTAssertEqual(closeCount, 0)
    }

    func testPhaseEightRegressionSnippetInsertionClosesPopoverWhenInserted() {
        let model = AppModel()
        let snippet = makeSnippetEntry(id: "inserted")
        var insertedSnippets: [SnippetEntry] = []
        var closeCount = 0

        let viewModel = CommandCenterViewModel(
            model: model,
            environment: .testing(
                insertSnippet: {
                    insertedSnippets.append($0)
                    return .inserted
                },
                closePopover: { closeCount += 1 }
            ),
            autoRefresh: false
        )
        viewModel.copiedSnippetID = "previous-copy"

        viewModel.executeSnippet(snippet)

        XCTAssertEqual(insertedSnippets, [snippet])
        XCTAssertNil(viewModel.copiedSnippetID)
        XCTAssertEqual(closeCount, 1)
    }

    func testCommandCenterSessionSummaryCollectsLiveSessionsAcrossOverlayModels() {
        let older = makeOverlayModelWithLiveSession(
            directory: "/tmp/window-1",
            status: .running,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let newer = makeOverlayModelWithLiveSession(
            directory: "/tmp/window-2",
            status: .waitingForInput,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let summaries = CommandCenterSessionSummary.collectLiveSessions(in: [older, newer])

        XCTAssertEqual(summaries.map(\.directory), ["/tmp/window-2", "/tmp/window-1"])
        XCTAssertEqual(summaries.map(\.state), [.waitingInput, .running])
    }

    func testCommandCenterSessionSummaryCollectsApprovalRequiredWithoutCollapsingToInput() {
        let approval = makeOverlayModelWithLiveSession(
            directory: "/tmp/approval-window",
            status: .approvalRequired,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_200)
        )

        let summaries = CommandCenterSessionSummary.collectLiveSessions(in: [approval])

        XCTAssertEqual(summaries.map(\.state), [.approvalRequired])
        XCTAssertEqual(summaries.first?.state.attentionKind, .approvalRequired)
        XCTAssertFalse(summaries.first?.state == .waitingInput)
    }

    func testCommandCenterEnvironmentFocusSessionSelectsTargetSplitPane() throws {
        let previousSplitPaneSetting = FeatureSettings.shared.isSplitPanesEnabled
        defer { FeatureSettings.shared.isSplitPanesEnabled = previousSplitPaneSetting }
        FeatureSettings.shared.isSplitPanesEnabled = true

        let overlayModel = makeOverlayModelWithLiveSession(
            directory: "/tmp/split-primary",
            status: .running,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_300)
        )
        guard let tab = overlayModel.tabs.first else {
            return XCTFail("Expected a test tab")
        }

        let splitController = tab.splitController
        let primaryPaneID = try XCTUnwrap(splitController.terminalSessions.first?.0)
        splitController.splitWithTerminal(direction: .horizontal)
        let targetPane = try XCTUnwrap(
            splitController.terminalSessions.first { paneID, _ in paneID != primaryPaneID }
        )
        targetPane.1.currentDirectory = "/tmp/split-target"
        targetPane.1.lastAIProvider = "codex"
        targetPane.1.lastAISessionId = "split-target-session"
        targetPane.1.lastAISessionIdentitySource = .explicit
        targetPane.1.status = .waitingForInput
        targetPane.1.lastInputAt = Date(timeIntervalSince1970: 1_800_000_301)
        targetPane.1.lastOutputAt = Date(timeIntervalSince1970: 1_800_000_301)
        splitController.setFocusedPane(primaryPaneID)

        let summaries = CommandCenterSessionSummary.collectLiveSessions(in: overlayModel)
        let targetSummary = try XCTUnwrap(summaries.first { $0.paneID == targetPane.0 })

        XCTAssertTrue(CommandCenterEnvironment.focusSession(targetSummary, in: overlayModel))
        XCTAssertEqual(overlayModel.selectedTabID, targetSummary.tabID)
        XCTAssertEqual(splitController.focusedPaneID, targetPane.0)
    }

    private func makeSummary(
        id: String,
        state: CommandCenterSessionSummary.State,
        lastActivityOffset: TimeInterval
    ) -> CommandCenterSessionSummary {
        CommandCenterSessionSummary(
            id: id,
            tabID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            paneID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Project \(id)",
            appName: "Codex",
            directory: "/tmp/\(id)",
            lastActivity: Date().addingTimeInterval(-lastActivityOffset),
            state: state
        )
    }

    private func withRestoredMonitoringPreference(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "isMonitoring")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "isMonitoring")
            } else {
                defaults.removeObject(forKey: "isMonitoring")
            }
        }
        body()
    }

    private func makeOverlayModelWithLiveSession(
        directory: String,
        status: CommandStatus,
        lastActivity: Date
    ) -> OverlayTabsModel {
        let appModel = AppModel()
        let overlayModel = OverlayTabsModel(appModel: appModel, restoreState: false)
        let splitController = SplitPaneController(appModel: appModel)
        var tab = OverlayTab(
            appModel: appModel,
            splitController: splitController,
            id: UUID(),
            createdAt: lastActivity
        )
        tab.stampOwnerTabID()
        overlayModel.tabs = [tab]
        overlayModel.selectedTabID = tab.id

        let session = overlayModel.tabs[0].session!
        session.currentDirectory = directory
        session.lastAIProvider = "codex"
        session.lastAISessionId = "session-\(directory)"
        session.lastAISessionIdentitySource = .explicit
        session.status = status
        session.lastInputAt = lastActivity
        session.lastOutputAt = lastActivity
        return overlayModel
    }

    private func makeSnippetEntry(id: String) -> SnippetEntry {
        SnippetEntry(
            snippet: Snippet(id: id, title: "Quick \(id)", body: "echo \(id)"),
            source: .global,
            sourcePath: "/tmp/snippets.json",
            isOverridden: false,
            repoRoot: nil
        )
    }

    private func makeEvent(
        index: Int,
        id: UUID? = nil,
        source: AIEventSource = .codex,
        type: String = "user_prompt",
        tool: String = "Codex",
        timestamp: Date? = nil,
        message: String,
        tabID: UUID? = nil,
        sessionID: String? = nil
    ) -> AIEvent {
        let date = timestamp ?? Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index))
        return AIEvent(
            id: id ?? UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            source: source,
            type: type,
            tool: tool,
            message: message,
            ts: DateFormatters.iso8601.string(from: date),
            tabID: tabID,
            sessionID: sessionID
        )
    }

    private func makeHistoryEntry(
        id: UUID,
        source: AIEventSource = .codex,
        type: String = "finished",
        semanticKind: NotificationSemanticKind = .taskFinished,
        tool: String = "Codex",
        timestamp: Date,
        message: String,
        resolvedTabID: UUID? = nil,
        wasRateLimited: Bool = false
    ) -> NotificationHistory.Entry {
        NotificationHistory.Entry(
            id: id,
            source: source.rawValue,
            type: type,
            rawType: nil,
            semanticKind: semanticKind.rawValue,
            tool: tool,
            message: message,
            notificationType: nil,
            timestamp: timestamp,
            reliability: AIEventReliability.authoritative.rawValue,
            producer: "test",
            triggerId: NotificationTriggerCatalog.triggerId(source: source, type: type),
            actionsExecuted: [],
            wasRateLimited: wasRateLimited,
            deliveryState: NotificationHistory.DeliveryState.completed.rawValue,
            dropReason: nil,
            resolutionMethod: nil,
            resolvedTabID: resolvedTabID?.uuidString,
            didDispatchBanner: true,
            didStyleTab: false,
            notes: []
        )
    }
}
