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

        let message = "tab attention reconciled tab=\(tabID) "
            + "statuses=\(statuses.joined(separator: ",")) "
            + "previousOwned=\(previousOwnedKind.rawValue) "
            + "desired=\(decision.desiredKind.rawValue) "
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
}
