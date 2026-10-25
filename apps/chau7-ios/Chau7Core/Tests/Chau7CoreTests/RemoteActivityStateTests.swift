import XCTest
@testable import Chau7Core

final class RemoteActivityStateTests: XCTestCase {
    func testWaitingInputBeatsSelectedRunningSession() {
        let now = Date(timeIntervalSince1970: 1000)
        let running = RemoteActivityCandidate(
            activityID: "tab-1",
            tabID: 1,
            tabTitle: "Claude",
            toolName: "Claude",
            projectName: "repo-a",
            status: .running,
            isSelected: true,
            updatedAt: now
        )
        let waiting = RemoteActivityCandidate(
            activityID: "tab-2",
            tabID: 2,
            tabTitle: "Codex",
            toolName: "Codex",
            projectName: "repo-b",
            status: .approvalRequired,
            isSelected: false,
            updatedAt: now.addingTimeInterval(-10),
            approval: RemoteActivityApproval(
                requestID: "req-1",
                command: "rm -rf build",
                flaggedCommand: "rm -rf build"
            )
        )

        let projected = RemoteActivityProjection.project(from: [running, waiting])

        XCTAssertEqual(projected?.tabID, 2)
        XCTAssertEqual(projected?.status, .approvalRequired)
        XCTAssertEqual(projected?.headline, "Approval required")
        XCTAssertEqual(projected?.detail, "rm -rf build")
    }

    func testSelectedRunningSessionBeatsMoreRecentBackgroundRunningSession() {
        let now = Date(timeIntervalSince1970: 2000)
        let selected = RemoteActivityCandidate(
            activityID: "tab-1",
            tabID: 1,
            tabTitle: "Claude",
            toolName: "Claude",
            projectName: "repo-a",
            status: .running,
            isSelected: true,
            updatedAt: now.addingTimeInterval(-5)
        )
        let background = RemoteActivityCandidate(
            activityID: "tab-2",
            tabID: 2,
            tabTitle: "Codex",
            toolName: "Codex",
            projectName: "repo-b",
            status: .running,
            isSelected: false,
            updatedAt: now
        )

        let projected = RemoteActivityProjection.project(from: [background, selected])

        XCTAssertEqual(projected?.tabID, 1)
        XCTAssertEqual(projected?.headline, "Claude is active")
        XCTAssertEqual(projected?.detail, "repo-a")
    }

    func testCompletedStateUsesExplicitDetail() {
        let now = Date(timeIntervalSince1970: 3000)
        let completed = RemoteActivityCandidate(
            activityID: "tab-3",
            tabID: 3,
            tabTitle: "Gemini",
            toolName: "Gemini",
            projectName: "repo-c",
            status: .completed,
            detail: "Updated 4 files",
            isSelected: false,
            updatedAt: now
        )

        let projected = RemoteActivityProjection.project(from: [completed])

        XCTAssertEqual(projected?.status, .completed)
        XCTAssertEqual(projected?.headline, "Gemini finished")
        XCTAssertEqual(projected?.detail, "Updated 4 files")
    }

    func testIdleOnlyCandidatesReturnNil() {
        let projected = RemoteActivityProjection.project(from: [
            RemoteActivityCandidate(
                activityID: "tab-1",
                tabID: 1,
                tabTitle: "Shell",
                toolName: "Claude",
                status: .idle,
                isSelected: true,
                updatedAt: Date()
            )
        ])

        XCTAssertNil(projected)
    }

    func testProjectionCarriesDisplayMetadata() {
        let projected = RemoteActivityProjection.project(from: [
            RemoteActivityCandidate(
                activityID: "tab-1",
                tabID: 1,
                tabTitle: "Claude",
                toolName: "Claude",
                projectName: "repo-a",
                status: .running,
                detail: nil,
                logoAssetName: "claude-logo",
                tabColorName: "purple",
                isSelected: true,
                updatedAt: Date()
            )
        ])

        XCTAssertEqual(projected?.logoAssetName, "claude-logo")
        XCTAssertEqual(projected?.tabColorName, "purple")
    }
}
