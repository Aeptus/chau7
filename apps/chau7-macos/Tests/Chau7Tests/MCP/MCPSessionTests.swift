import XCTest
@testable import Chau7

final class MCPSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MCPSession.resetSharedToolRateLimiterForTests()
    }

    func testRejectsRequestsBeforeInitialization() throws {
        let response = try XCTUnwrap(
            MCPSession(fd: -1).handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32002)
    }

    func testInitializeNegotiatesSupportedVersionAndRequiresInitializedNotification() throws {
        let session = MCPSession(fd: -1)

        let initialize = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": ["protocolVersion": "2025-11-25"]
            ])
        )
        let initializeResult = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-11-25")

        let preReady = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list"
            ])
        )
        let preReadyError = try XCTUnwrap(preReady["error"] as? [String: Any])
        XCTAssertEqual(preReadyError["code"] as? Int, -32002)

        XCTAssertNil(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "method": "notifications/initialized"
            ])
        )

        let toolList = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/list"
            ])
        )
        let tools = try XCTUnwrap((toolList["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let sessionCurrent = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "session_current" }))
        let inputSchema = try XCTUnwrap(sessionCurrent["inputSchema"] as? [String: Any])
        XCTAssertEqual(inputSchema["additionalProperties"] as? Bool, false)

        let sessionList = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "session_list" }))
        XCTAssertTrue((sessionList["description"] as? String)?.contains("telemetry/history") == true)
        XCTAssertTrue((sessionList["description"] as? String)?.contains("tab_list") == true)

        XCTAssertTrue((sessionCurrent["description"] as? String)?.contains("telemetry-backed") == true)
        XCTAssertTrue((sessionCurrent["description"] as? String)?.contains("tab_status") == true)

        let tabList = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "tab_list" }))
        XCTAssertTrue((tabList["description"] as? String)?.contains("primary live discovery API") == true)

        let tabStatus = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "tab_status" }))
        XCTAssertTrue((tabStatus["description"] as? String)?.contains("AI provider/session metadata") == true)
    }

    func testInitializeRejectsUnsupportedProtocolVersions() throws {
        let response = try XCTUnwrap(
            MCPSession(fd: -1).handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": ["protocolVersion": "2023-01-01"]
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["supported"] as? [String], ["2025-11-25", "2024-11-05"])
    }

    func testUnknownToolReturnsProtocolError() throws {
        let session = initializedSession()

        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "does_not_exist", "arguments": [:]]
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testMissingRequiredArgumentsReturnProtocolError() throws {
        let session = initializedSession()

        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "run_get", "arguments": [:]]
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String)?.contains("missing required argument 'run_id'") == true)
    }

    func testToolExecutionFailuresUseIsErrorResult() throws {
        let session = initializedSession()

        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": "run_get",
                    "arguments": ["run_id": "missing-run"]
                ]
            ])
        )

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structuredContent = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structuredContent["error"] as? String, "Run not found")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Run not found")
    }

    private func initializedSession() -> MCPSession {
        let session = MCPSession(fd: -1)
        _ = session.handleRequestObject([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-11-25"]
        ])
        _ = session.handleRequestObject([
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ])
        return session
    }
}
