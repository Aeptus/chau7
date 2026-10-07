import XCTest
@testable import Chau7
import Chau7Core

final class MCPRepositoryQueryServiceTests: XCTestCase {
    func testMetadataKeepsSnapshotAndCommandStatisticsContractsOnWorker() async throws {
        let service = MCPRepositoryQueryService(
            statsProvider: { _ in
                XCTAssertFalse(Thread.isMainThread)
                return .empty
            },
            frequentCommandsProvider: { _, limit in
                XCTAssertEqual(limit, 10)
                return [FrequentCommand(command: "git status", count: 3, lastUsed: Date(timeIntervalSince1970: 1000))]
            }
        )
        let json = await Task.detached {
            service.metadataJSON(repoPath: "/repo", cachedMetadata: RepoMetadata(description: "Snapshot", labels: ["work"], favoriteFiles: [], updatedAt: nil))
        }.value
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["repo_name"] as? String, "repo")
        XCTAssertEqual(payload["description"] as? String, "Snapshot")
        XCTAssertEqual(payload["labels"] as? [String], ["work"])
        XCTAssertNil(payload["favorite_files"])
        XCTAssertEqual((payload["stats"] as? [String: Any])?["total_runs"] as? Int, 0)
        XCTAssertEqual((payload["frequent_commands"] as? [[String: Any]])?.first?["command"] as? String, "git status")
    }

    @MainActor
    func testEventsKeepTailOrderMessageLimitAndAllocateOnlyReturnedAliases() throws {
        let service = MCPRepositoryQueryService(statsProvider: { _ in .empty }, frequentCommandsProvider: { _, _ in [] })
        let tabID = UUID()
        let snapshot = (0 ..< 60).map { index in
            AIEvent(
                type: "finished",
                tool: "Codex",
                message: String(repeating: "😀", count: 201),
                ts: String(index),
                tabID: tabID,
                sessionID: "session",
                producer: "runtime",
                reliability: .authoritative
            )
        }
        var aliasCalls = 0
        let json = service.eventsJSON(repoPath: "/repo", snapshot: snapshot, query: RepoEventQuery(limit: 100), truncateMessages: true) { id in
            XCTAssertEqual(id, tabID)
            aliasCalls += 1
            return "tab_7"
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 50)
        XCTAssertEqual(aliasCalls, 50)
        XCTAssertEqual(events.first?["ts"] as? String, "10")
        XCTAssertEqual(events.last?["ts"] as? String, "59")
        XCTAssertEqual((events.first?["message"] as? String)?.count, 200)
        XCTAssertEqual(events.first?["tab_id"] as? String, "tab_7")
        XCTAssertEqual(events.first?["session_id"] as? String, "session")
        XCTAssertEqual(events.first?["reliability"] as? String, "authoritative")
    }
}
