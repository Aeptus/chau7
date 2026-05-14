import Chau7Core
import Foundation

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

    private func reconcileTabAttentionStyle(at index: Int, reason: String) -> Bool {
        let statuses = tabs[index].splitController.terminalSessions.map { _, session in
            session.effectiveStatus.rawValue
        }
        let decision = TabAttentionStatePolicy.reconcile(TabAttentionSnapshot(
            rawStatuses: statuses,
            currentOwnedKind: tabs[index].stateAttentionKind,
            hasVisibleStyle: tabs[index].notificationStyle != nil
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
