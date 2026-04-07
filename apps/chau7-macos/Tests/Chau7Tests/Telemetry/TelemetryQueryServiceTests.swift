import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class TelemetryQueryServiceTests: XCTestCase {
    func testListRunsDoesNotDuplicateActiveRunAlreadyPersisted() throws {
        let service = TelemetryQueryService()
        let tabID = "tab-\(UUID().uuidString)"
        let repoPath = "/tmp/telemetry-active-\(UUID().uuidString)"

        TelemetryRecorder.shared.runStarted(
            tabID: tabID,
            provider: "codex",
            cwd: repoPath,
            repoPath: repoPath,
            sessionID: "session-\(UUID().uuidString)"
        )
        defer {
            TelemetryRecorder.shared.runEnded(tabID: tabID, exitStatus: 0)
        }

        let response = service.listRuns([
            "repo_path": repoPath,
            "limit": 10
        ])

        let json = try XCTUnwrap(parseJSONArray(response))
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json.first?["run_state"] as? String, "active")

        let sessions = try XCTUnwrap(parseJSONArray(service.listSessions(repoPath: repoPath)))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?["active_run_count"] as? Int, 1)
        XCTAssertEqual(sessions.first?["completed_run_count"] as? Int, 0)
        XCTAssertEqual(sessions.first?["latest_run_state"] as? String, "active")
    }

    func testListRunsFiltersByParentRunID() throws {
        let service = TelemetryQueryService()
        let tabID = "tab-\(UUID().uuidString)"
        let repoPath = "/tmp/telemetry-parent-\(UUID().uuidString)"
        let parentRunID = "parent-\(UUID().uuidString)"

        TelemetryRecorder.shared.runStarted(
            tabID: tabID,
            provider: "shell",
            cwd: repoPath,
            repoPath: repoPath,
            parentRunID: parentRunID,
            metadata: [
                "runtime_session_id": "rs_test123",
                "runtime_purpose": "code_review"
            ]
        )
        TelemetryRecorder.shared.runEnded(tabID: tabID, exitStatus: 0)

        let response = service.listRuns([
            "repo_path": repoPath,
            "parent_run_id": parentRunID,
            "limit": 10
        ])

        let json = try XCTUnwrap(parseJSONArray(response))
        let matchingRun = json.first { ($0["parentRunID"] as? String) == parentRunID }

        XCTAssertNotNil(matchingRun)
        XCTAssertEqual(matchingRun?["repoPath"] as? String, repoPath)
        let metadata = matchingRun?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["runtime_session_id"] as? String, "rs_test123")
        XCTAssertEqual(metadata?["runtime_purpose"] as? String, "code_review")
    }

    func testGetTranscriptUsesActiveCodexHistoryFallback() throws {
        let service = TelemetryQueryService()
        let tabID = "tab-\(UUID().uuidString)"
        let repoPath = "/tmp/telemetry-history-\(UUID().uuidString)"
        let sessionID = "session-\(UUID().uuidString)"
        let homeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chau7-history-\(UUID().uuidString)", isDirectory: true)
        let codexDir = homeRoot.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let historyPath = codexDir.appendingPathComponent("history.jsonl")
        try """
        {"session_id":"\(sessionID)","ts":1775581702,"text":"first live prompt"}
        {"session_id":"\(sessionID)","ts":1775581710,"text":"second live prompt"}
        """.write(to: historyPath, atomically: true, encoding: .utf8)

        setenv("CHAU7_HOME_ROOT", homeRoot.path, 1)
        defer {
            unsetenv("CHAU7_HOME_ROOT")
            try? FileManager.default.removeItem(at: homeRoot)
            TelemetryRecorder.shared.runEnded(tabID: tabID, exitStatus: 0)
        }

        TelemetryRecorder.shared.runStarted(
            tabID: tabID,
            provider: "codex",
            cwd: repoPath,
            repoPath: repoPath,
            sessionID: sessionID
        )

        let runs = try XCTUnwrap(parseJSONArray(service.listRuns([
            "repo_path": repoPath,
            "limit": 10
        ])))
        let runID = try XCTUnwrap(runs.first?["id"] as? String)
        XCTAssertEqual(runs.first?["content_state"] as? String, "partial")
        let transcript = try XCTUnwrap(parseJSONArray(service.getTranscript(runID)))

        XCTAssertEqual(transcript.count, 2)
        XCTAssertEqual(transcript.compactMap { $0["content"] as? String }, [
            "first live prompt",
            "second live prompt"
        ])
    }

    private func parseJSONArray(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return json
    }
}
#endif
