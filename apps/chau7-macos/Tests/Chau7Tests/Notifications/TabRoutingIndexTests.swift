import XCTest
@testable import Chau7Core

final class TabRoutingIndexTests: XCTestCase {
    func testStrictSessionResolutionUsesSessionID() {
        let targetTabID = UUID()
        let otherTabID = UUID()
        let index = TabRoutingIndex(records: [
            TabRouteRecord(
                tabID: targetTabID,
                directory: "/tmp/project",
                provider: "codex",
                displayName: "Codex",
                sessionID: "session-1"
            ),
            TabRouteRecord(
                tabID: otherTabID,
                directory: "/tmp/project",
                provider: "codex",
                displayName: "Codex",
                sessionID: "session-2"
            )
        ])

        let resolved = index.resolve(
            TabTarget(tool: "Codex", directory: "/tmp/project", sessionID: "session-1"),
            strictSession: true
        )

        XCTAssertEqual(resolved, targetTabID)
    }

    func testStrictSessionResolutionDisambiguatesByDirectory() {
        let targetTabID = UUID()
        let otherTabID = UUID()
        let index = TabRoutingIndex(records: [
            TabRouteRecord(
                tabID: targetTabID,
                directory: "/tmp/project",
                provider: "claude",
                displayName: "Claude",
                sessionID: "shared-session"
            ),
            TabRouteRecord(
                tabID: otherTabID,
                directory: "/tmp/other",
                provider: "claude",
                displayName: "Claude",
                sessionID: "shared-session"
            )
        ])

        let resolved = index.resolve(
            TabTarget(tool: "Claude", directory: "/tmp/project/subdir", sessionID: "shared-session"),
            strictSession: true
        )

        XCTAssertEqual(resolved, targetTabID)
    }

    func testStrictSessionResolutionRefusesAmbiguousEqualMatches() {
        let index = TabRoutingIndex(records: [
            TabRouteRecord(
                tabID: UUID(),
                directory: "/tmp/project",
                provider: "codex",
                displayName: "Codex",
                sessionID: "shared-session",
                lastActivity: Date(timeIntervalSince1970: 10)
            ),
            TabRouteRecord(
                tabID: UUID(),
                directory: "/tmp/project",
                provider: "codex",
                displayName: "Codex",
                sessionID: "shared-session",
                lastActivity: Date(timeIntervalSince1970: 10)
            )
        ])

        let resolved = index.resolve(
            TabTarget(tool: "Codex", directory: "/tmp/project", sessionID: "shared-session"),
            strictSession: true
        )

        XCTAssertNil(resolved)
    }

    func testNonSessionResolutionUsesToolAndDirectory() {
        let targetTabID = UUID()
        let index = TabRoutingIndex(records: [
            TabRouteRecord(
                tabID: targetTabID,
                directory: "/tmp/project",
                provider: "codex",
                displayName: "Codex"
            ),
            TabRouteRecord(
                tabID: UUID(),
                directory: "/tmp/other",
                provider: "codex",
                displayName: "Codex"
            )
        ])

        let resolved = index.resolve(
            TabTarget(tool: "codex", directory: "/tmp/project"),
            strictSession: false
        )

        XCTAssertEqual(resolved, targetTabID)
    }

    /// An unmatched sessionID must FAIL CLOSED — even in non-strict mode.
    /// The prior behaviour fell through to tool+directory routing, which
    /// let external claudes (Terminal.app, iTerm2, ...) attach their
    /// session ids to whichever Chau7 tab happened to match the cwd. The
    /// proper recovery path is the hook's CHAU7_TAB_ID ownership stamp +
    /// fast-path tabID match, not relaxing this check.
    func testNonStrictFailsClosedWhenSessionIDDoesNotMatchAnyTab() {
        let index = TabRoutingIndex(records: [
            TabRouteRecord(
                tabID: UUID(),
                directory: "/tmp/project",
                provider: "claude",
                displayName: "Claude",
                sessionID: "tab-owned-session"
            )
        ])

        let resolved = index.resolve(
            TabTarget(
                tool: "claude",
                directory: "/tmp/project",
                sessionID: "foreign-session-id"
            ),
            strictSession: false
        )

        XCTAssertNil(resolved)
    }

    func testStrictModeStillFailsClosedOnUnknownSessionID() {
        let index = TabRoutingIndex(records: [
            TabRouteRecord(
                tabID: UUID(),
                directory: "/tmp/project",
                provider: "codex",
                displayName: "Codex",
                sessionID: "rollout-session-id"
            )
        ])

        let resolved = index.resolve(
            TabTarget(
                tool: "codex",
                directory: "/tmp/project",
                sessionID: "unknown"
            ),
            strictSession: true
        )

        XCTAssertNil(resolved)
    }
}
