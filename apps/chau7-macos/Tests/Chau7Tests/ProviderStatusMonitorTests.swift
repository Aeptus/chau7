import XCTest
@testable import Chau7

@MainActor
final class ProviderStatusMonitorTests: XCTestCase {
    func testRefreshPublishesCanonicalProviderSnapshots() async {
        let monitor = ProviderStatusMonitor(fetcher: StubStatusFetcher())

        await monitor.refresh()

        XCTAssertEqual(
            monitor.activeSnapshot(for: "Claude Code")?.severity,
            .outage
        )
        XCTAssertNil(monitor.activeSnapshot(for: "Codex"))
        XCTAssertNil(monitor.activeSnapshot(for: "Gemini"))
        XCTAssertNil(monitor.activeSnapshot(for: "Unknown Tool"))
        XCTAssertEqual(
            Set(monitor.snapshotsByProvider.keys),
            Set(["anthropic", "openai", "github", "google"])
        )
    }
}

private struct StubStatusFetcher: ProviderStatusDataFetching {
    func data(from url: URL) async throws -> Data {
        switch url.host {
        case "status.claude.com":
            return Data(
                """
                {
                  "components": [
                    {"id":"api","name":"Claude API","status":"major_outage"},
                    {"id":"code","name":"Claude Code","status":"major_outage"}
                  ],
                  "incidents": [{
                    "name":"Elevated errors",
                    "status":"investigating",
                    "components":[{"id":"api"},{"id":"code"}]
                  }]
                }
                """.utf8
            )
        case "status.openai.com":
            // OpenAI's current summary shape may omit the incidents key when
            // there are no unresolved incidents.
            return Data(
                """
                {
                  "components": [
                    {"id":"responses","name":"Responses","status":"operational"},
                    {"id":"codex","name":"Codex API","status":"operational"}
                  ]
                }
                """.utf8
            )
        case "www.githubstatus.com":
            return Data(
                """
                {
                  "components": [
                    {"id":"copilot","name":"Copilot","status":"operational"}
                  ],
                  "incidents":[]
                }
                """.utf8
            )
        case "status.cloud.google.com":
            return Data("[]".utf8)
        default:
            throw StubStatusError.unexpectedURL
        }
    }
}

private enum StubStatusError: Error {
    case unexpectedURL
}
