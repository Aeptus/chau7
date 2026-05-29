import XCTest
@testable import Chau7
@testable import Chau7Core

#if !SWIFT_PACKAGE

@MainActor
final class NotificationMultiWindowTests: XCTestCase {

    func testTabTargetIncludesSessionID() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-01-01T00:00:00Z",
            directory: "/tmp/repo",
            sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b"
        )
        let target = event.tabTarget
        XCTAssertEqual(target.sessionID, "019d25d0-d0bd-7501-99ba-1f937c17b29b")
        XCTAssertEqual(target.tool, "Codex")
        XCTAssertEqual(target.directory, "/tmp/repo")
    }

    func testNotificationTitleIncludesRepoName() {
        let event = AIEvent(
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-01-01T00:00:00Z"
        )
        let title = event.notificationTitle(toolOverride: "MyProject", repoName: "Chau7")
        XCTAssertTrue(title.contains("Chau7"))
        XCTAssertTrue(title.contains("MyProject"))
        XCTAssertTrue(title.contains("Finished"))
    }

    func testNotificationTitleOmitsRepoWhenSameAsToolName() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-01-01T00:00:00Z"
        )
        let title = event.notificationTitle(toolOverride: "Codex", repoName: "Codex")
        // Should not duplicate: "Codex — Codex: Finished"
        XCTAssertEqual(title, "Codex: Finished")
    }

    func testNotificationSubtitleIncludesRepoAndTabContext() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-01-01T00:00:00Z"
        )

        XCTAssertEqual(
            event.notificationSubtitle(tabTitle: "Mockup", repoName: "Chau7"),
            "Repo: Chau7 · Tab: Mockup"
        )
    }

    func testNotificationSubtitleDeduplicatesToolAndRepo() {
        let event = AIEvent(
            source: .claudeCode,
            type: "waiting_input",
            tool: "Claude",
            message: "",
            ts: "2026-01-01T00:00:00Z"
        )

        XCTAssertEqual(
            event.notificationSubtitle(tabTitle: "Claude", repoName: "Claude"),
            "Repo: Claude"
        )
    }

    func testNotificationSubtitleFallsBackToDirectoryName() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-01-01T00:00:00Z",
            directory: "/Users/christophehenner/Downloads/Repositories/Chau7"
        )

        XCTAssertEqual(event.notificationSubtitle(), "Dir: Chau7")
    }

    func testNotificationBodyForFinished() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "Codex finished in Mockup",
            ts: "2026-01-01T00:00:00Z"
        )
        XCTAssertEqual(event.notificationBody, "Codex finished in Mockup")
    }

    func testNotificationBodyFallbackForEmptyMessage() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "",
            ts: "2026-01-01T00:00:00Z"
        )
        XCTAssertEqual(event.notificationBody, "Done.")
    }
}

#endif
