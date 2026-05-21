import Chau7Core
import Foundation

private enum NotificationAttentionSessionAssertion {
    case asserted
    case noMatchingSession
    case skippedTerminatedSession
}

extension OverlayTabsModel {
    /// Repairs tab attention from terminal state only. This deliberately avoids
    /// NotificationActionExecutor so native banners/sounds/rate limits stay
    /// notification-owned while persistent tab highlights stay state-owned.
    @discardableResult
    func reconcileTabAttentionStyles(reason: String) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        var changedCount = 0

        for index in tabs.indices {
            if reconcileTabAttentionStyle(at: index, reason: reason) {
                changedCount += 1
            }
        }

        return changedCount
    }

    /// Promotes a resolved notification event into durable tab attention.
    ///
    /// Notification delivery can be suppressed by trigger settings, repeated
    /// event suppression, focus rules, or rate limits. Interactive tab
    /// attention cannot depend on those delivery paths: a resolved
    /// waiting/approval event means the tab should remain visibly marked until
    /// terminal/session state proves it is resolved.
    @discardableResult
    func assertNotificationAttention(
        tabID: UUID,
        kind: TabAttentionKind,
        sessionID: String?,
        reason: String
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard kind.isInteractive,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return false
        }

        switch assertSessionAttentionStatus(at: index, kind: kind, sessionID: sessionID) {
        case .asserted:
            let changed = reconcileTabAttentionStyle(at: index, reason: reason)
            if !changed {
                logNotificationAttentionAssertion(
                    tabID: tabID,
                    index: index,
                    action: "notificationAssertNoop",
                    reason: reason,
                    sessionMatched: true
                )
            }
            return changed

        case .noMatchingSession:
            return applyNotificationAttentionFallback(
                tabID: tabID,
                index: index,
                kind: kind,
                reason: reason
            )

        case .skippedTerminatedSession:
            logNotificationAttentionAssertion(
                tabID: tabID,
                index: index,
                action: "notificationAssertSkippedTerminated",
                reason: reason,
                sessionMatched: true
            )
            return false
        }
    }

    @discardableResult
    func clearNotificationAttention(
        tabID: UUID,
        sessionID: String?,
        resolvedStatus: CommandStatus,
        reason: String
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return false
        }

        var changed = false
        let candidates = notificationAttentionCandidateSessions(at: index, sessionID: sessionID)
        for session in candidates {
            guard session.status == .waitingForInput || session.status == .approvalRequired else {
                continue
            }
            session.status = resolvedStatus
            changed = true
        }

        if !candidates.isEmpty, tabs[index].stateAttentionKind.isInteractive {
            changed = reconcileTabAttentionStyle(at: index, reason: reason) || changed
        } else if !candidates.isEmpty, tabs[index].notificationStyle?.persistent == true {
            tabs[index].notificationStyle = nil
            changed = true
        }

        if changed {
            logNotificationAttentionAssertion(
                tabID: tabID,
                index: index,
                action: "notificationResolvedClear",
                reason: reason,
                sessionMatched: !candidates.isEmpty
            )
        }
        return changed
    }

    private func reconcileTabAttentionStyle(at index: Int, reason: String) -> Bool {
        let statuses = tabs[index].splitController.terminalSessions.map { _, session in
            session.effectiveStatus.rawValue
        }
        let decision = TabAttentionStatePolicy.reconcile(TabAttentionSnapshot(
            rawStatuses: statuses,
            currentOwnedKind: tabs[index].stateAttentionKind,
            hasVisibleStyle: tabs[index].notificationStyle != nil,
            isSelected: tabs[index].id == selectedTabID
        ))

        guard decision.action != .none else { return false }

        let tabID = tabs[index].id
        let previousOwnedKind = tabs[index].stateAttentionKind

        if decision.shouldApplyStyle {
            tabs[index].notificationStyle = stateAttentionStyle(for: decision.desiredKind)
        } else if decision.shouldClearVisibleStyle {
            tabs[index].notificationStyle = nil
        }
        tabs[index].stateAttentionKind = decision.nextOwnedKind

        let message = "attentionReport tab=\(tabID) "
            + "\(attentionReport(for: tabs[index]).compactLine) "
            + "previousOwned=\(previousOwnedKind.rawValue) "
            + "action=\(decision.action.rawValue) reason=\(reason)"
        Log.info(message)
        return true
    }

    private func assertSessionAttentionStatus(
        at index: Int,
        kind: TabAttentionKind,
        sessionID: String?
    ) -> NotificationAttentionSessionAssertion {
        guard let targetStatus = commandStatus(for: kind) else {
            return .noMatchingSession
        }

        let candidates = notificationAttentionCandidateSessions(at: index, sessionID: sessionID)
        guard !candidates.isEmpty else {
            return .noMatchingSession
        }

        var assertedLiveSession = false
        for session in candidates {
            guard session.status != .exited else { continue }
            assertedLiveSession = true
            let currentKind = TabAttentionKind.fromStatus(session.status.rawValue)
            guard kind.priority >= currentKind.priority else { continue }
            if session.status != targetStatus {
                session.status = targetStatus
            }
        }

        return assertedLiveSession ? .asserted : .skippedTerminatedSession
    }

    private func notificationAttentionCandidateSessions(
        at index: Int,
        sessionID: String?
    ) -> [TerminalSessionModel] {
        let sessions = tabs[index].splitController.terminalSessions.map { _, session in session }
        if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            return sessions.filter { $0.effectiveAISessionId == sessionID }
        }
        if let displaySession = tabs[index].displaySession {
            return [displaySession]
        }
        if sessions.count == 1 {
            return sessions
        }
        return []
    }

    private func applyNotificationAttentionFallback(
        tabID: UUID,
        index: Int,
        kind: TabAttentionKind,
        reason: String
    ) -> Bool {
        if tabs[index].stateAttentionKind.isInteractive {
            logNotificationAttentionAssertion(
                tabID: tabID,
                index: index,
                action: "notificationAssertNoMatchPreservedOwned",
                reason: reason,
                sessionMatched: false
            )
            return false
        }

        let previousStyle = tabs[index].notificationStyle
        tabs[index].notificationStyle = stateAttentionStyle(for: kind)
        let changed = previousStyle != tabs[index].notificationStyle
        logNotificationAttentionAssertion(
            tabID: tabID,
            index: index,
            action: changed ? "notificationFallbackApply" : "notificationFallbackNoop",
            reason: reason,
            sessionMatched: false
        )
        return changed
    }

    private func commandStatus(for kind: TabAttentionKind) -> CommandStatus? {
        switch kind {
        case .waitingForInput:
            return .waitingForInput
        case .approvalRequired:
            return .approvalRequired
        case .none:
            return nil
        }
    }

    private func logNotificationAttentionAssertion(
        tabID: UUID,
        index: Int,
        action: String,
        reason: String,
        sessionMatched: Bool
    ) {
        let message = "attentionReport tab=\(tabID) "
            + "\(attentionReport(for: tabs[index]).compactLine) "
            + "action=\(action) reason=\(reason) sessionMatched=\(sessionMatched)"
        Log.info(message)
    }

    private func stateAttentionStyle(for kind: TabAttentionKind) -> TabNotificationStyle? {
        guard kind.isInteractive else { return nil }

        var style = buildNotificationStyle(preset: "attention", config: [
            "customColor": "orange",
            "borderWidth": "2",
            "pulse": "true",
            "persistent": "true"
        ])
        style.persistent = true
        return style
    }

    func attentionReport(for tab: OverlayTab) -> TabAttentionReport {
        TabAttentionReport(
            statuses: attentionStatuses(for: tab),
            ownedKind: tab.stateAttentionKind,
            hasVisibleStyle: tab.notificationStyle != nil,
            isSelected: tab.id == selectedTabID,
            styleSummary: notificationStyleSummary(tab.notificationStyle)
        )
    }

    func attentionReportPayload(for tab: OverlayTab) -> [String: Any] {
        let report = attentionReport(for: tab)
        return [
            "statuses": report.statuses,
            "desired_kind": report.desiredKind.rawValue,
            "owned_kind": report.ownedKind.rawValue,
            "has_visible_style": report.hasVisibleStyle,
            "is_selected": report.isSelected,
            "style": report.styleSummary,
            "compact": report.compactLine
        ]
    }

    private func attentionStatuses(for tab: OverlayTab) -> [String] {
        tab.splitController.terminalSessions.map { _, session in
            session.effectiveStatus.rawValue
        }
    }

    private func notificationStyleSummary(_ style: TabNotificationStyle?) -> String {
        guard let style else { return "none" }
        var parts: [String] = []
        if let icon = style.icon {
            parts.append("icon=\(icon)")
        }
        if style.persistent {
            parts.append("persistent")
        }
        if style.shouldPulse {
            parts.append("pulse")
        }
        if style.borderWidth > 0 {
            parts.append("border=\(style.borderWidth)")
        }
        if let badge = style.badgeText {
            parts.append("badge=\(badge)")
        }
        return parts.isEmpty ? "custom" : parts.joined(separator: "+")
    }
}
