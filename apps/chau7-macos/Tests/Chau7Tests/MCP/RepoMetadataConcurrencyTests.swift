import Foundation
import XCTest
@testable import Chau7

@MainActor
final class RepoMetadataConcurrencyTests: XCTestCase {
    func testMCPMetadataStatisticsWaitLeavesMainActorResponsive() async throws {
        let started = expectation(description: "Statistics entered on the MCP worker")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let service = TerminalControlService(repoStatsProvider: { _ in
            XCTAssertFalse(Thread.isMainThread, "Database statistics must not wait on the UI thread")
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return .empty
        })
        let session = MCPSession(fd: -1, controlService: service)
        _ = session.handleRequestObject([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25"]
        ])
        _ = session.handleRequestObject(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let root = NSTemporaryDirectory() + "chau7-metadata-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        RepoMetadataStore.save(
            RepoMetadata(description: "Saved metadata", labels: ["test"], favoriteFiles: [], updatedAt: nil),
            repoRoot: root
        )
        let request = Task.detached {
            let response = session.handleRequestObject([
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": "repo_get_metadata", "arguments": ["repo_path": root]]
            ])
            let data = try JSONSerialization.data(withJSONObject: response ?? [:])
            return String(decoding: data, as: UTF8.self)
        }
        await fulfillment(of: [started], timeout: 2)
        // This continuation needs the main actor while statistics remain blocked.
        XCTAssertTrue(Thread.isMainThread)
        release.signal()
        let responseText = try await request.value
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(responseText.utf8)) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(payload["description"] as? String, "Saved metadata")
        XCTAssertEqual(payload["labels"] as? [String], ["test"])
        XCTAssertEqual((payload["stats"] as? [String: Any])?["total_runs"] as? Int, 0)
    }
}
