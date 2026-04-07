import XCTest
@testable import Chau7Core

final class TelemetryQueryProjectionTests: XCTestCase {
    func testMergeRunsDeduplicatesActiveRunAlreadyPersisted() {
        let startedAt = Date(timeIntervalSince1970: 1_775_581_761)
        let duplicateRun = TelemetryRun(
            id: "run-active",
            sessionID: "session-1",
            tabID: "tab-1",
            provider: "codex",
            cwd: "/tmp/chau7",
            repoPath: "/tmp/chau7",
            startedAt: startedAt
        )
        let olderRun = TelemetryRun(
            id: "run-older",
            sessionID: "session-1",
            tabID: "tab-1",
            provider: "codex",
            cwd: "/tmp/chau7",
            repoPath: "/tmp/chau7",
            startedAt: startedAt.addingTimeInterval(-60)
        )

        let merged = TelemetryQueryProjection.mergeRuns(
            activeRuns: [duplicateRun],
            storedRuns: [duplicateRun, olderRun],
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(merged.map(\.id), ["run-active", "run-older"])
    }

    func testTurnsFromHistoryFiltersSessionAndStartTime() {
        let startedAt = Date(timeIntervalSince1970: 1_775_581_700)
        let jsonl = """
        {"session_id":"session-1","ts":1775581690,"text":"before run"}
        {"session_id":"session-2","ts":1775581701,"text":"wrong session"}
        {"session_id":"session-1","ts":1775581702,"text":"first live prompt"}
        {"session_id":"session-1","ts":1775581710,"text":"second live prompt"}
        """

        let turns = CodexLiveHistoryParser.turns(
            from: jsonl,
            sessionID: "session-1",
            runID: "run-1",
            startedAt: startedAt
        )

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.map { $0.content ?? "" }, ["first live prompt", "second live prompt"])
        XCTAssertEqual(turns.map(\.role), [.human, .human])
        XCTAssertEqual(turns.map(\.runID), ["run-1", "run-1"])
    }
}
