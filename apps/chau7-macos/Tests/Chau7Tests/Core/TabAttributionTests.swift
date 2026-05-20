import XCTest
@testable import Chau7Core

final class TabAttributionTests: XCTestCase {

    // MARK: - trustStampedTabID

    func testTrustStampedTabIDMatchesWhenTabExists() {
        let tabID = UUID()
        let resolver = TabAttribution(snapshotProvider: {
            [TabRouteRecord(tabID: tabID, directory: "/tmp/x", provider: "claude")]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", tabID: tabID),
            policy: .trustStampedTabID
        )
        XCTAssertEqual(result, .matched(tabID, signal: .stampedTabID))
    }

    func testTrustStampedTabIDRefusesAbsentTab() {
        let stamped = UUID()
        let other = UUID()
        let resolver = TabAttribution(snapshotProvider: {
            [TabRouteRecord(tabID: other, directory: "/tmp/x", provider: "claude")]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", tabID: stamped),
            policy: .trustStampedTabID
        )
        guard case .refused = result else {
            return XCTFail("expected refused, got \(result)")
        }
    }

    func testTrustStampedTabIDRefusesNilTabID() {
        let resolver = TabAttribution(snapshotProvider: { [] })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude"),
            policy: .trustStampedTabID
        )
        guard case .refused = result else {
            return XCTFail("expected refused, got \(result)")
        }
    }

    // MARK: - requireSessionMatch

    func testRequireSessionMatchMatchesUniqueTab() {
        let target = UUID()
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(
                    tabID: target,
                    directory: "/tmp/x",
                    provider: "claude",
                    sessionID: "session-a"
                ),
                TabRouteRecord(
                    tabID: UUID(),
                    directory: "/tmp/y",
                    provider: "claude",
                    sessionID: "session-b"
                )
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", sessionID: "session-a"),
            policy: .requireSessionMatch
        )
        XCTAssertEqual(result, .matched(target, signal: .sessionMatchExact))
    }

    func testRequireSessionMatchDisambiguatesByDirectory() {
        let target = UUID()
        let other = UUID()
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(
                    tabID: target,
                    directory: "/tmp/repo",
                    provider: "claude",
                    sessionID: "shared"
                ),
                TabRouteRecord(
                    tabID: other,
                    directory: "/tmp/other",
                    provider: "claude",
                    sessionID: "shared"
                )
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", directory: "/tmp/repo/subdir", sessionID: "shared"),
            policy: .requireSessionMatch
        )
        XCTAssertEqual(result, .matched(target, signal: .sessionMatchExactDirectoryRanked))
    }

    func testRequireSessionMatchReturnsAmbiguousWhenDirectoryCantBreakTie() {
        let a = UUID()
        let b = UUID()
        let date = Date(timeIntervalSince1970: 0)
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(
                    tabID: a,
                    directory: "/tmp/repo",
                    provider: "claude",
                    sessionID: "shared",
                    lastActivity: date
                ),
                TabRouteRecord(
                    tabID: b,
                    directory: "/tmp/repo",
                    provider: "claude",
                    sessionID: "shared",
                    lastActivity: date
                )
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", directory: "/tmp/repo", sessionID: "shared"),
            policy: .requireSessionMatch
        )
        guard case let .ambiguous(candidates, _) = result else {
            return XCTFail("expected ambiguous, got \(result)")
        }
        XCTAssertEqual(Set(candidates), Set([a, b]))
    }

    func testRequireSessionMatchNoMatch() {
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(
                    tabID: UUID(),
                    directory: "/tmp/x",
                    provider: "claude",
                    sessionID: "tab-owned"
                )
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", sessionID: "foreign-session"),
            policy: .requireSessionMatch
        )
        XCTAssertEqual(result, .noMatch)
    }

    func testRequireSessionMatchRefusesNilSessionID() {
        let resolver = TabAttribution(snapshotProvider: { [] })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude"),
            policy: .requireSessionMatch
        )
        guard case .refused = result else {
            return XCTFail("expected refused, got \(result)")
        }
    }

    /// Regression for today's external-Terminal.app leak — refuse to attribute
    /// an unknown sessionID just because some Chau7 tab is in the same repo.
    func testRequireSessionMatchRefusesForeignTerminalAppClaude() {
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(
                    tabID: UUID(),
                    directory: "/Users/me/Repositories/Chau7/apps/chau7-macos",
                    provider: "claude",
                    sessionID: "tab-owned-session-id"
                )
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(
                tool: "Claude",
                directory: "/Users/me/Repositories/Chau7/apps/chau7-macos",
                sessionID: "external-terminal-app-session-id"
            ),
            policy: .requireSessionMatch
        )
        XCTAssertEqual(result, .noMatch)
    }

    // MARK: - bindUnboundByDirectory

    func testBindUnboundByDirectoryMatchesSingleUnboundTab() {
        let target = UUID()
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(
                    tabID: target,
                    directory: "/tmp/aethyme",
                    provider: "claude",
                    sessionID: nil
                )
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", directory: "/tmp/aethyme/subdir"),
            policy: .bindUnboundByDirectory
        )
        XCTAssertEqual(result, .matched(target, signal: .directoryUnboundUnique))
    }

    // Regression: an already-bound tab matching by directory is the
    // external-claude leak signature. Must refuse.
    func testBindUnboundByDirectoryRefusesAlreadyBoundTab() {
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(
                    tabID: UUID(),
                    directory: "/tmp/aethyme",
                    provider: "claude",
                    sessionID: "already-bound-to-different-claude"
                )
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", directory: "/tmp/aethyme"),
            policy: .bindUnboundByDirectory
        )
        guard case .refused = result else {
            return XCTFail("expected refused, got \(result)")
        }
    }

    func testBindUnboundByDirectoryReturnsAmbiguousOnMultipleUnboundMatches() {
        let a = UUID()
        let b = UUID()
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(tabID: a, directory: "/tmp/repo", provider: "claude", sessionID: nil),
                TabRouteRecord(tabID: b, directory: "/tmp/repo", provider: "claude", sessionID: nil)
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", directory: "/tmp/repo"),
            policy: .bindUnboundByDirectory
        )
        guard case let .ambiguous(candidates, _) = result else {
            return XCTFail("expected ambiguous, got \(result)")
        }
        XCTAssertEqual(Set(candidates), Set([a, b]))
    }

    func testBindUnboundByDirectoryNoMatch() {
        let resolver = TabAttribution(snapshotProvider: {
            [TabRouteRecord(tabID: UUID(), directory: "/tmp/aethyme", provider: "claude", sessionID: nil)]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", directory: "/tmp/totally-different"),
            policy: .bindUnboundByDirectory
        )
        XCTAssertEqual(result, .noMatch)
    }

    func testBindUnboundByDirectoryRefusesNilDirectory() {
        let resolver = TabAttribution(snapshotProvider: { [] })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude"),
            policy: .bindUnboundByDirectory
        )
        guard case .refused = result else {
            return XCTFail("expected refused, got \(result)")
        }
    }

    // MARK: - audit

    func testAuditReturnsAllCandidatesWithReasons() {
        let a = UUID()
        let b = UUID()
        let resolver = TabAttribution(snapshotProvider: {
            [
                TabRouteRecord(tabID: a, directory: "/tmp/repo", provider: "claude", sessionID: "s1"),
                TabRouteRecord(tabID: b, directory: "/tmp/repo", provider: "claude", sessionID: nil)
            ]
        })
        let result = resolver.resolve(
            target: TabTarget(tool: "Claude", directory: "/tmp/repo", sessionID: "s1"),
            policy: .audit
        )
        guard case let .auditTrail(candidates) = result else {
            return XCTFail("expected auditTrail, got \(result)")
        }
        XCTAssertEqual(candidates.count, 2)
        let aReasons = candidates.first { $0.tabID == a }?.reasons ?? []
        XCTAssertTrue(aReasons.contains("sessionID matches"))
        let bReasons = candidates.first { $0.tabID == b }?.reasons ?? []
        XCTAssertTrue(bReasons.contains("unbound"))
    }
}
