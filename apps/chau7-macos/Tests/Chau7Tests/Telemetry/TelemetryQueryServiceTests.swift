import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class TelemetryQueryServiceTests: XCTestCase {
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

    private func parseJSONArray(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return json
    }
}
#endif
