import Foundation
import Observation
import Chau7Core

// MARK: - Command Center View Model

struct CommandCenterBadgeCounts: Equatable {
    let liveCount: Int
    let approvalRequiredCount: Int
    let waitingInputCount: Int

    static let empty = CommandCenterBadgeCounts(
        liveCount: 0,
        approvalRequiredCount: 0,
        waitingInputCount: 0
    )

    var attentionKind: TabAttentionKind {
        if approvalRequiredCount > 0 {
            return .approvalRequired
        }
        if waitingInputCount > 0 {
            return .waitingForInput
        }
        return .none
    }

    var attentionCount: Int {
        switch attentionKind {
        case .approvalRequired:
            return approvalRequiredCount
        case .waitingForInput:
            return waitingInputCount
        case .none:
            return 0
        }
    }
}

struct CommandCenterHeroStatus: Equatable {
    enum Tone: Equatable {
        case approvalRequired
        case waitingForInput
        case monitoringPaused
        case running
        case quiet
    }

    let tone: Tone
    let title: String
    let detail: String
}

/// Shared state for the command center panel — survives popover open/close cycles.
///
/// **Data sources** (all tool-agnostic):
/// - open overlay tabs / terminal sessions → hero zone + live sessions
/// - `model.recentEvents` (`[AIEvent]`) → unified timeline. This is the **tool-agnostic** event stream
///   fed by all monitors (file tailer, terminal sessions, API proxy, etc.). Do NOT use
///   `model.claudeCodeEvents` here — that stream is Claude Code hook-specific and would exclude events
///   from Cursor, Codex, Copilot, Aider, and other monitored tools.
/// - `NotificationHistory` → unified timeline (notification-fired events, also tool-agnostic via `AIEvent`)
///
/// All derived state is computed from observable properties, so SwiftUI re-evaluates automatically.
@MainActor
@Observable
final class CommandCenterViewModel {
    @ObservationIgnored let model: AppModel
    @ObservationIgnored let environment: CommandCenterEnvironment
    private(set) var liveSessions: [CommandCenterSessionSummary] = []
    private(set) var actionSessions: [CommandCenterSessionSummary] = []
    private(set) var attentionSessions: [CommandCenterSessionSummary] = []
    private(set) var runningSessionCount = 0
    private(set) var badgeCounts: CommandCenterBadgeCounts = .empty {
        didSet { onBadgeCountsChange?(badgeCounts) }
    }

    var showQuitConfirmation = false
    var copiedSnippetID: String?
    @ObservationIgnored private var refreshTimer: Timer?

    /// Callback for StatusBarController to observe badge changes without Combine.
    @ObservationIgnored var onBadgeCountsChange: ((CommandCenterBadgeCounts) -> Void)?

    init(
        model: AppModel,
        environment: CommandCenterEnvironment,
        autoRefresh: Bool = true
    ) {
        self.model = model
        self.environment = environment
        refreshSessions()

        if autoRefresh {
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshSessions()
                }
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    var attentionCount: Int {
        badgeCounts.attentionCount
    }

    var primaryAttentionKind: TabAttentionKind {
        badgeCounts.attentionKind
    }

    var totalLiveSessionCount: Int {
        badgeCounts.liveCount
    }

    var heroStatus: CommandCenterHeroStatus {
        if badgeCounts.approvalRequiredCount > 0 {
            return CommandCenterHeroStatus(
                tone: .approvalRequired,
                title: L("statusBar.hero.approvalRequired", "Approval required"),
                detail: Self.approvalDetail(count: badgeCounts.approvalRequiredCount)
            )
        }

        if badgeCounts.waitingInputCount > 0 {
            return CommandCenterHeroStatus(
                tone: .waitingForInput,
                title: L("statusBar.hero.waitingForInput", "Waiting for input"),
                detail: Self.waitingInputDetail(count: badgeCounts.waitingInputCount)
            )
        }

        if !model.isMonitoring {
            return CommandCenterHeroStatus(
                tone: .monitoringPaused,
                title: L("statusBar.hero.monitoringPaused", "Monitoring paused"),
                detail: L("statusBar.hero.monitoringPaused.detail", "New AI activity is not being watched")
            )
        }

        if runningSessionCount > 0 {
            return CommandCenterHeroStatus(
                tone: .running,
                title: Self.runningSessionTitle(count: runningSessionCount),
                detail: L("statusBar.hero.running.detail", "No action needed right now")
            )
        }

        return CommandCenterHeroStatus(
            tone: .quiet,
            title: L("statusBar.hero.quiet", "Quiet"),
            detail: L("statusBar.hero.quiet.detail", "No live AI sessions")
        )
    }

    func refreshSessions() {
        let sessions = environment.sessionSource()
        liveSessions = Array(sessions.prefix(5))
        actionSessions = Self.prioritizedActionSessions(from: sessions)
        runningSessionCount = sessions.filter { $0.state == .running }.count
        let approvalRequiredCount = sessions.filter { $0.state == .approvalRequired }.count
        let waitingInputCount = sessions.filter { $0.state == .waitingInput }.count
        let nextBadgeCounts = CommandCenterBadgeCounts(
            liveCount: sessions.count,
            approvalRequiredCount: approvalRequiredCount,
            waitingInputCount: waitingInputCount
        )
        attentionSessions = sessions.filter { $0.state.attentionKind == nextBadgeCounts.attentionKind }
        badgeCounts = nextBadgeCounts
    }

    func tabTarget(for session: CommandCenterSessionSummary) -> TabTarget {
        session.tabTarget
    }

    func focusSession(_ session: CommandCenterSessionSummary) {
        environment.focusSession(session)
        environment.closePopover()
    }

    func openSettings(section: SettingsSection? = nil, anchorID: String? = nil) {
        environment.openSettings(section, anchorID)
        environment.closePopover()
    }

    func openDefaultSettings() {
        openSettings(section: .startHere)
    }

    func openMonitoringSettings() {
        openSettings(section: .notifications, anchorID: "eventMonitoring")
    }

    func openPinnedSnippetSettings() {
        openSettings(section: .snippetsTools, anchorID: "snippets")
    }

    func executeSnippet(_ entry: SnippetEntry) {
        switch environment.insertSnippet(entry) {
        case .inserted:
            copiedSnippetID = nil
            environment.closePopover()
        case .copiedToClipboard:
            copiedSnippetID = entry.id
        }
    }

    private static func prioritizedActionSessions(
        from sessions: [CommandCenterSessionSummary]
    ) -> [CommandCenterSessionSummary] {
        Array(sessions
            .sorted { lhs, rhs in
                let lhsRank = actionPriority(for: lhs.state)
                let rhsRank = actionPriority(for: rhs.state)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.lastActivity > rhs.lastActivity
            }
            .prefix(5))
    }

    private static func actionPriority(for state: CommandCenterSessionSummary.State) -> Int {
        switch state {
        case .approvalRequired:
            return 0
        case .waitingInput:
            return 1
        case .running:
            return 2
        case .stuck:
            return 3
        }
    }

    private static func approvalDetail(count: Int) -> String {
        if count == 1 {
            return L("statusBar.hero.approvalRequired.detail.singular", "1 session needs approval")
        }
        return L("statusBar.hero.approvalRequired.detail.plural", "%d sessions need approval", count)
    }

    private static func waitingInputDetail(count: Int) -> String {
        if count == 1 {
            return L("statusBar.hero.waitingForInput.detail.singular", "1 session is waiting")
        }
        return L("statusBar.hero.waitingForInput.detail.plural", "%d sessions are waiting", count)
    }

    private static func runningSessionTitle(count: Int) -> String {
        if count == 1 {
            return L("statusBar.hero.running.singular", "1 session running")
        }
        return L("statusBar.hero.running.plural", "%d sessions running", count)
    }
}
