import XCTest
@testable import Chau7

final class StatusBarIconPresenterTests: XCTestCase {
    func testMonitoringOff() {
        let presentation = StatusBarIconPresenter.presentation(
            isMonitoring: false,
            badgeCounts: makeCounts(live: 4, approvals: 2, waitingInput: 3)
        )

        assertPresentation(
            presentation,
            symbolName: "bell",
            title: "",
            status: L("statusBar.icon.monitoringPaused", "monitoring paused")
        )
    }

    func testMonitoringOnWithNoSessions() {
        let presentation = StatusBarIconPresenter.presentation(
            isMonitoring: true,
            badgeCounts: .empty
        )

        assertPresentation(
            presentation,
            symbolName: "bell.badge.fill",
            title: "",
            status: L("statusBar.icon.noLiveSessions", "monitoring active, no live sessions")
        )
    }

    func testMonitoringOnWithRunningSessions() {
        let presentation = StatusBarIconPresenter.presentation(
            isMonitoring: true,
            badgeCounts: makeCounts(live: 3, approvals: 0, waitingInput: 0)
        )

        assertPresentation(
            presentation,
            symbolName: "bell.badge.fill",
            title: "",
            status: L("statusBar.icon.liveSession.plural", "%d live sessions", 3)
        )
    }

    func testWaitingInputShowsWaitingCount() {
        let presentation = StatusBarIconPresenter.presentation(
            isMonitoring: true,
            badgeCounts: makeCounts(live: 2, approvals: 0, waitingInput: 1)
        )

        assertPresentation(
            presentation,
            symbolName: "bell.badge.fill",
            title: "1",
            status: L("statusBar.icon.waitingInput.singular", "1 session waiting for input")
        )
    }

    func testApprovalRequiredShowsApprovalCount() {
        let presentation = StatusBarIconPresenter.presentation(
            isMonitoring: true,
            badgeCounts: makeCounts(live: 2, approvals: 1, waitingInput: 0)
        )

        assertPresentation(
            presentation,
            symbolName: "bell.badge.fill",
            title: "1",
            status: L("statusBar.icon.approval.singular", "1 approval required")
        )
    }

    func testMultipleAttentionSessionsPreferApprovalCount() {
        let presentation = StatusBarIconPresenter.presentation(
            isMonitoring: true,
            badgeCounts: makeCounts(live: 7, approvals: 2, waitingInput: 3)
        )

        assertPresentation(
            presentation,
            symbolName: "bell.badge.fill",
            title: "2",
            status: L("statusBar.icon.approval.plural", "%d approvals required", 2)
        )
    }

    private func assertPresentation(
        _ presentation: StatusBarIconPresentation,
        symbolName: String,
        title: String,
        status: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let appName = L("app.name", "Chau7")

        XCTAssertEqual(presentation.symbolName, symbolName, file: file, line: line)
        XCTAssertEqual(presentation.title, title, file: file, line: line)
        XCTAssertEqual(
            presentation.accessibilityLabel,
            L("statusBar.icon.accessibilityLabel", "%@, %@", appName, status),
            file: file,
            line: line
        )
        XCTAssertEqual(
            presentation.tooltip,
            L("statusBar.icon.tooltip", "%@: %@", appName, status),
            file: file,
            line: line
        )
    }

    private func makeCounts(
        live: Int,
        approvals: Int,
        waitingInput: Int
    ) -> CommandCenterBadgeCounts {
        CommandCenterBadgeCounts(
            liveCount: live,
            approvalRequiredCount: approvals,
            waitingInputCount: waitingInput
        )
    }
}
