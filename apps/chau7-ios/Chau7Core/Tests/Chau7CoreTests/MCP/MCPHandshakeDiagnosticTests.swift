import XCTest
import Chau7Core

final class MCPHandshakeDiagnosticTests: XCTestCase {
    func testLifecycleProducesNonSecretReadyPayload() {
        var diagnostic = MCPHandshakeDiagnostic()
        diagnostic.recordAttempt(
            clientName: "codex\nforged-field",
            clientVersion: "0.146.0",
            requestedProtocolVersion: "2025-06-18"
        )
        diagnostic.recordAccepted(negotiatedProtocolVersion: "2025-06-18")
        diagnostic.recordReady()

        let payload = diagnostic.payload(
            bridgeCommandPath: "/Users/me/.chau7/bin/chau7-mcp-bridge",
            socketPath: "/Users/me/.chau7/mcp.sock"
        )

        XCTAssertEqual(payload["server_name"], "chau7")
        XCTAssertEqual(payload["client_name"], "codex forged-field")
        XCTAssertEqual(payload["requested_protocol_version"], "2025-06-18")
        XCTAssertEqual(payload["negotiated_protocol_version"], "2025-06-18")
        XCTAssertEqual(payload["startup_status"], "ready")
        XCTAssertEqual(payload["error_class"], "none")
        XCTAssertFalse(payload.values.contains(where: { $0.contains("api_key") }))
    }

    func testRejectedHandshakeReportsStableErrorClass() {
        var diagnostic = MCPHandshakeDiagnostic()
        diagnostic.recordAttempt(
            clientName: "codex",
            clientVersion: "0.146.0",
            requestedProtocolVersion: "2023-01-01"
        )
        diagnostic.recordRejected(errorClass: .unsupportedProtocolVersion)

        XCTAssertEqual(diagnostic.status, .rejected)
        XCTAssertEqual(diagnostic.errorClass, "unsupported_protocol_version")
        XCTAssertTrue(diagnostic.logSummary.contains("startup_status=rejected"))
    }
}
