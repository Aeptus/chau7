import Foundation

/// Central registry of every internal `Notification.Name` used as an in-app
/// signal bus. One declaration per name, uniform `com.chau7.` namespace.
///
/// These are UI-refresh and settings-change signals, deliberately *not*
/// routed through the event spine — they carry no domain payload and giving
/// them spine ordering semantics would couple settings-UI refresh to event
/// sequencing for no benefit. Domain-shaped candidates for later spine
/// migration: `taskCandidateReceived`, `monitoringStateChanged`.
///
/// `AppSignalsTests` asserts raw-value uniqueness so a copy-pasted
/// declaration can't silently alias another signal.
extension Notification.Name {

    // MARK: - Feature settings (Settings/FeatureSettings)

    static let repoGroupingModeChanged = Notification.Name("com.chau7.feature.repoGroupingModeChanged")
    static let remoteEnabledChanged = Notification.Name("com.chau7.feature.remoteEnabledChanged")
    static let remoteRelayURLChanged = Notification.Name("com.chau7.feature.remoteRelayURLChanged")

    // MARK: - Terminal appearance / behavior settings (Settings views)

    static let terminalFontChanged = Notification.Name("com.chau7.terminalFontChanged")
    static let terminalColorsChanged = Notification.Name("com.chau7.terminalColorsChanged")
    static let terminalOpacityChanged = Notification.Name("com.chau7.terminalOpacityChanged")
    static let terminalZoomChanged = Notification.Name("com.chau7.terminalZoomChanged")
    static let terminalDangerousCommandHighlightChanged = Notification.Name("com.chau7.terminalDangerousCommandHighlightChanged")
    static let activePollingRateCapChanged = Notification.Name("com.chau7.activePollingRateCapChanged")
    static let terminalDidStart = Notification.Name("com.chau7.terminalDidStart")
    static let settingsProfileChanged = Notification.Name("com.chau7.settingsProfileChanged")
    static let appThemeChanged = Notification.Name("com.chau7.appThemeChanged")
    static let fullscreenToolbarSettingChanged = Notification.Name("com.chau7.fullscreenToolbarSettingChanged")
    static let apiAnalyticsSettingsChanged = Notification.Name("com.chau7.apiAnalyticsSettingsChanged")
    static let usageMonitoringSettingsChanged = Notification.Name("com.chau7.usageMonitoringSettingsChanged")
    static let monitoringStateChanged = Notification.Name("com.chau7.monitoringStateChanged")
    static let windowFloatingChanged = Notification.Name("com.chau7.windowFloatingChanged")

    // MARK: - Proxy / API analytics

    static let apiCallRecorded = Notification.Name("com.chau7.apiCallRecorded")
    static let proxyStatusChanged = Notification.Name("com.chau7.proxyStatusChanged")

    // MARK: - Task candidates (Proxy/TaskCandidate)

    static let taskCandidateReceived = Notification.Name("com.chau7.taskCandidateReceived")
    static let taskStarted = Notification.Name("com.chau7.taskStarted")
    static let taskCandidateDismissed = Notification.Name("com.chau7.taskCandidateDismissed")
    static let taskAssessmentReceived = Notification.Name("com.chau7.taskAssessmentReceived")

    // MARK: - Token optimization (TokenOptimization/CTOManager)

    static let tokenOptimizationModeChanged = Notification.Name("com.chau7.tokenOptimizationModeChanged")
    static let ctoFlagRecalculated = Notification.Name("com.chau7.ctoFlagRecalculated")

    // MARK: - Appearance / localization / performance

    static let minimalModeChanged = Notification.Name("com.chau7.minimalModeChanged")
    static let languageDidChange = Notification.Name("com.chau7.languageDidChange")
    static let chau7MemoryPressureChanged = Notification.Name("com.chau7.memoryPressureChanged")

    // MARK: - Terminal session lifecycle (Terminal/Session/TerminalSessionModel)

    static let terminalSessionRenderSuspensionStateChanged =
        Notification.Name("com.chau7.terminalSessionRenderSuspensionStateChanged")
    static let terminalSessionRuntimeReadinessChanged =
        Notification.Name("com.chau7.terminalSessionRuntimeReadinessChanged")
    static let terminalSessionVisibleFrameReady =
        Notification.Name("com.chau7.terminalSessionVisibleFrameReady")

    // MARK: - Remote viewer (posted by OverlayTabsModel and

    // TerminalControlService, observed by RemoteControlManager)

    static let viewerPendingApproval = Notification.Name("com.chau7.viewerPendingApproval")
    static let overlayTabsDidChange = Notification.Name("com.chau7.overlayTabsDidChange")
}

/// All registry names, for the uniqueness test.
enum AppSignals {
    static let all: [Notification.Name] = [
        .repoGroupingModeChanged, .remoteEnabledChanged, .remoteRelayURLChanged,
        .terminalFontChanged, .terminalColorsChanged, .terminalOpacityChanged,
        .terminalZoomChanged, .terminalDangerousCommandHighlightChanged,
        .activePollingRateCapChanged, .terminalDidStart, .settingsProfileChanged,
        .appThemeChanged, .fullscreenToolbarSettingChanged,
        .apiAnalyticsSettingsChanged, .usageMonitoringSettingsChanged,
        .monitoringStateChanged, .windowFloatingChanged,
        .apiCallRecorded, .proxyStatusChanged,
        .taskCandidateReceived, .taskStarted, .taskCandidateDismissed,
        .taskAssessmentReceived,
        .tokenOptimizationModeChanged, .ctoFlagRecalculated,
        .minimalModeChanged, .languageDidChange, .chau7MemoryPressureChanged,
        .terminalSessionRenderSuspensionStateChanged,
        .terminalSessionRuntimeReadinessChanged, .terminalSessionVisibleFrameReady,
        .viewerPendingApproval, .overlayTabsDidChange
    ]
}
