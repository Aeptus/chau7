import Foundation
import AppKit
import Chau7Core

/// Protocol for UI actions triggered by the notification system. One
/// conformance point routes every tab/window action a handler might
/// need (focus, style, badge, snippet insert, menu bar flash, exact-tab
/// resolution).
@MainActor protocol NotificationActionDelegate: AnyObject {
    func focusTab(tabID: UUID) -> Bool
    @discardableResult func styleTab(tabID: UUID, preset: String, config: [String: String]) -> UUID?
    func tabExists(tabID: UUID) -> Bool
    func badgeTab(tabID: UUID, text: String, color: String) -> Bool
    func insertSnippet(id: String, tabID: UUID, autoExecute: Bool) -> Bool
    func flashMenuBar(duration: Int, animate: Bool)
    func resolveExactTab(target: TabTarget) -> UUID?
}

/// Dispatches notification actions to per-type handlers.
///
/// Before Phase A this class held the implementation of all 24 action
/// types inline plus their shared state (`activeTimers`, `flashWindow`,
/// `speechSynthesizer`). Each action implementation now lives on its
/// own type under `Notifications/Handlers/`; the executor's only job is
/// to:
///
/// 1. Build the `ActionEnvironment` (delegate weakref, styleCoordinator,
///    notification-dispatch closure) that every handler receives.
/// 2. Look up the handler for an incoming action via
///    `NotificationActionRegistry`.
/// 3. Drive the per-config accumulator pattern (`ExecutionReport.append`)
///    across every enabled action.
///
/// Adding a new action becomes additive: write the handler, declare its
/// `supportedActionTypes`, and add a registry entry. No edits here.
@MainActor
final class NotificationActionExecutor {
    static let shared = NotificationActionExecutor()

    struct ExecutionReport: Equatable {
        var successfulActions: [String] = []
        var notes: [String] = []
        var didDispatchBanner = false
        var didStyleTab = false

        mutating func recordSuccess(_ actionType: NotificationActionType) {
            successfulActions.append(actionType.rawValue)
            if actionType == .showNotification {
                didDispatchBanner = true
            }
            if actionType == .styleTab {
                didStyleTab = true
            }
        }

        mutating func recordFailure(_ note: String) {
            notes.append(note)
        }

        mutating func append(_ other: ExecutionReport) {
            successfulActions.append(contentsOf: other.successfulActions)
            notes.append(contentsOf: other.notes)
            didDispatchBanner = didDispatchBanner || other.didDispatchBanner
            didStyleTab = didStyleTab || other.didStyleTab
        }
    }

    // MARK: - Dependencies (injected from app)

    /// Strong reference is safe — the adapter holds only weak refs to
    /// the actual UI objects. The `didSet` keeps the styleCoordinator
    /// + environment in sync so handlers always see the live delegate.
    var delegate: NotificationActionDelegate? {
        didSet {
            styleCoordinator.delegate = delegate
            environment.delegate = delegate
        }
    }

    // MARK: - Owned collaborators

    /// Owns the styleTab state machine. Exposed so
    /// `NotificationManager.assertInteractiveAttentionIfNeeded` can
    /// cancel pending work without going through the action registry.
    private let styleCoordinator = StyleTabCoordinator()

    /// Typed reference to the time-tracking handler so `resetForTesting`
    /// can clear its `activeTimers` without round-tripping through the
    /// registry's existential.
    private let timeTrackingHandler = TimeTrackingActionHandler()

    private let environment: ActionEnvironment
    private let actionRegistry: NotificationActionRegistry

    private init() {
        let coordinator = styleCoordinator
        let env = ActionEnvironment(
            styleCoordinator: coordinator,
            dispatchActionNotification: { title, body, event in
                NotificationManager.shared.dispatchActionNotification(title: title, body: body, for: event)
            }
        )
        self.environment = env
        // Build the registry from the canonical list, swapping in the
        // typed time-tracking handler so it's shared with the executor's
        // explicit reference.
        let handlers: [any NotificationActionHandler] = [
            ShowNotificationActionHandler(),
            PlaySoundActionHandler(),
            FocusWindowActionHandler(),
            DockBounceActionHandler(),
            BadgeTabActionHandler(),
            StyleTabActionHandler(),
            RunScriptActionHandler(),
            RunShortcutActionHandler(),
            ExecuteSnippetActionHandler(),
            WebhookActionHandler(),
            SendSlackActionHandler(),
            SendDiscordActionHandler(),
            DockerBumpActionHandler(),
            DockerComposeActionHandler(),
            KubernetesRolloutActionHandler(),
            CopyToClipboardActionHandler(),
            WriteToFileActionHandler(),
            OpenURLActionHandler(),
            GitCommitActionHandler(),
            VoiceAnnounceActionHandler(),
            FlashScreenActionHandler(),
            MenuBarAlertActionHandler(),
            timeTrackingHandler
        ]
        self.actionRegistry = NotificationActionRegistry(handlers: handlers)
    }

    // MARK: - Main Entry Point

    func execute(actions: [NotificationActionConfig], for event: AIEvent) -> ExecutionReport {
        var report = ExecutionReport()
        for actionConfig in actions where actionConfig.enabled {
            report.append(executeAction(actionConfig, for: event))
        }
        return report
    }

    func cancelPendingStyleWork(tabID: UUID? = nil, sessionID: String? = nil) {
        styleCoordinator.cancelPendingWork(tabID: tabID, sessionID: sessionID)
    }

    func resetForTesting() {
        styleCoordinator.reset()
        timeTrackingHandler.reset()
        delegate = nil
    }

    private func executeAction(_ config: NotificationActionConfig, for event: AIEvent) -> ExecutionReport {
        guard let handler = actionRegistry.handler(for: config.actionType) else {
            var report = ExecutionReport()
            report.recordFailure("\(config.actionType.rawValue) has no registered handler")
            return report
        }
        let payload = ActionPayload(event: event, config: config)
        return handler.execute(payload: payload, environment: environment)
    }
}

// MARK: - Adapter bridging OverlayTabsModel + StatusBarController → NotificationActionDelegate

/// Bridges tab-related actions (via OverlayTabsModel) and menu bar actions (via StatusBarController)
/// into a single NotificationActionDelegate conformance.
@MainActor
final class NotificationActionAdapter: NotificationActionDelegate {
    private weak var overlayModel: OverlayTabsModel?
    private let statusBar: StatusBarController

    init(overlayModel: OverlayTabsModel, statusBar: StatusBarController) {
        self.overlayModel = overlayModel
        self.statusBar = statusBar
    }

    func focusTab(tabID: UUID) -> Bool {
        return TerminalControlService.shared.focusTabAcrossWindows(tabID: tabID)
    }

    @discardableResult
    func styleTab(tabID: UUID, preset: String, config: [String: String]) -> UUID? {
        return TerminalControlService.shared.applyNotificationStyleAcrossWindows(
            to: tabID, stylePreset: preset, config: config
        )
    }

    func badgeTab(tabID: UUID, text: String, color: String) -> Bool {
        return TerminalControlService.shared.badgeTabAcrossWindows(tabID: tabID, text: text, color: color)
    }

    func tabExists(tabID: UUID) -> Bool {
        TerminalControlService.shared.tabExistsAcrossWindows(tabID: tabID)
    }

    func insertSnippet(id: String, tabID: UUID, autoExecute: Bool) -> Bool {
        return TerminalControlService.shared.insertSnippetAcrossWindows(id: id, tabID: tabID, autoExecute: autoExecute)
    }

    func flashMenuBar(duration: Int, animate: Bool) {
        statusBar.flashAlert(duration: duration, animate: animate)
    }

    func resolveExactTab(target: TabTarget) -> UUID? {
        TerminalControlService.shared.resolveTabID(for: target, strictSession: true)
    }
}
