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
}
