import XCTest
import AppKit
@testable import Chau7
@testable import Chau7Core

final class RepoNotificationMutingTests: XCTestCase {

    // MARK: - Pure gate

    func testIndefiniteMuteMatchesRepoPathAndSubdirectories() {
        let muted = ["/repo/mockup": RepoMute()]
        let now = Date()
        XCTAssertTrue(RepoNotificationMuting.isMuted(repoPath: "/repo/mockup", directory: nil, mutedRepos: muted, now: now))
        XCTAssertTrue(RepoNotificationMuting.isMuted(repoPath: nil, directory: "/repo/mockup/src", mutedRepos: muted, now: now))
        XCTAssertTrue(RepoNotificationMuting.isMuted(repoPath: nil, directory: "/repo/mockup", mutedRepos: muted, now: now))
        XCTAssertFalse(RepoNotificationMuting.isMuted(repoPath: nil, directory: "/repo/mockup-sibling", mutedRepos: muted, now: now), "prefix match must be path-segment aware")
        XCTAssertFalse(RepoNotificationMuting.isMuted(repoPath: "/repo/other", directory: nil, mutedRepos: muted, now: now))
    }

    func testSnoozeExpiresDeterministically() {
        let t0 = Date(timeIntervalSince1970: 1_751_000_000)
        let muted = ["/repo/mockup": RepoMute(snoozeUntil: t0.addingTimeInterval(3600))]

        XCTAssertTrue(RepoNotificationMuting.isMuted(repoPath: "/repo/mockup", directory: nil, mutedRepos: muted, now: t0))
        XCTAssertTrue(RepoNotificationMuting.isMuted(repoPath: "/repo/mockup", directory: nil, mutedRepos: muted, now: t0.addingTimeInterval(3599)))
        XCTAssertFalse(RepoNotificationMuting.isMuted(repoPath: "/repo/mockup", directory: nil, mutedRepos: muted, now: t0.addingTimeInterval(3600)), "snooze boundary is exclusive")
    }

    func testPrunedDropsExpiredSnoozesKeepsActiveMutes() {
        let t0 = Date(timeIntervalSince1970: 1_751_000_000)
        let muted: [String: RepoMute] = [
            "/expired": RepoMute(snoozeUntil: t0.addingTimeInterval(-1)),
            "/active-snooze": RepoMute(snoozeUntil: t0.addingTimeInterval(60)),
            "/indefinite": RepoMute()
        ]
        let pruned = RepoNotificationMuting.pruned(muted, now: t0)
        XCTAssertEqual(Set(pruned.keys), ["/active-snooze", "/indefinite"])
    }

    // MARK: - Manager integration

    @MainActor
    func testMutedRepoDropsEventAtTheManagerGate() {
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
        _ = NSApplication.shared
        let services = NotificationServices()

        let original = FeatureSettings.shared.notificationSettings.mutedRepos
        FeatureSettings.shared.notificationSettings.mutedRepos = ["/tmp/muted-repo": RepoMute()]
        defer { FeatureSettings.shared.notificationSettings.mutedRepos = original }

        let mutedEvent = AIEvent(
            source: .claudeCode, type: "finished", tool: "Claude Code",
            message: "done", ts: DateFormatters.nowISO8601(),
            directory: "/tmp/muted-repo/src", sessionID: "muted-1"
        )
        XCTAssertNil(
            services.manager.processUnifiedEvent(mutedEvent, deliveryRequested: true),
            "event under a muted root must be dropped before every surface"
        )

        let unmutedEvent = AIEvent(
            source: .claudeCode, type: "finished", tool: "Claude Code",
            message: "done", ts: DateFormatters.nowISO8601(),
            directory: "/tmp/other-repo", sessionID: "unmuted-1"
        )
        XCTAssertNotNil(services.manager.processUnifiedEvent(unmutedEvent, deliveryRequested: true))
    }
}
