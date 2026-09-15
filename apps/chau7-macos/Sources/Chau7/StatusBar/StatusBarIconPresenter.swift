import Foundation
import Chau7Core

// MARK: - Status Bar Icon Presenter

struct StatusBarIconPresentation: Equatable {
    let symbolName: String
    let title: String
    let accessibilityLabel: String
    let tooltip: String
}

struct StatusBarIconPresenter {
    static func presentation(
        isMonitoring: Bool,
        badgeCounts: CommandCenterBadgeCounts
    ) -> StatusBarIconPresentation {
        let appName = L("app.name", "Chau7")

        guard isMonitoring else {
            let status = L("statusBar.icon.monitoringPaused", "monitoring paused")
            return StatusBarIconPresentation(
                symbolName: "bell",
                title: "",
                accessibilityLabel: accessibilityLabel(appName: appName, status: status),
                tooltip: tooltip(appName: appName, status: status)
            )
        }

        let status = statusDescription(for: badgeCounts)
        return StatusBarIconPresentation(
            symbolName: "bell.badge.fill",
            title: badgeCounts.attentionCount > 0 ? "\(badgeCounts.attentionCount)" : "",
            accessibilityLabel: accessibilityLabel(appName: appName, status: status),
            tooltip: tooltip(appName: appName, status: status)
        )
    }

    private static func statusDescription(for badgeCounts: CommandCenterBadgeCounts) -> String {
        switch badgeCounts.attentionKind {
        case .approvalRequired:
            return approvalDescription(count: badgeCounts.approvalRequiredCount)
        case .waitingForInput:
            return waitingInputDescription(count: badgeCounts.waitingInputCount)
        case .none:
            return liveSessionDescription(count: badgeCounts.liveCount)
        }
    }

    private static func approvalDescription(count: Int) -> String {
        if count == 1 {
            return L("statusBar.icon.approval.singular", "1 approval required")
        }
        return L("statusBar.icon.approval.plural", "%d approvals required", count)
    }

    private static func waitingInputDescription(count: Int) -> String {
        if count == 1 {
            return L("statusBar.icon.waitingInput.singular", "1 session waiting for input")
        }
        return L("statusBar.icon.waitingInput.plural", "%d sessions waiting for input", count)
    }

    private static func liveSessionDescription(count: Int) -> String {
        if count == 0 {
            return L("statusBar.icon.noLiveSessions", "monitoring active, no live sessions")
        }
        if count == 1 {
            return L("statusBar.icon.liveSession.singular", "1 live session")
        }
        return L("statusBar.icon.liveSession.plural", "%d live sessions", count)
    }

    private static func accessibilityLabel(appName: String, status: String) -> String {
        L("statusBar.icon.accessibilityLabel", "%@, %@", appName, status)
    }

    private static func tooltip(appName: String, status: String) -> String {
        L("statusBar.icon.tooltip", "%@: %@", appName, status)
    }
}
