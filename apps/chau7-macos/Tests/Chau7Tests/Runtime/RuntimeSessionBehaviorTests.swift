#if !SWIFT_PACKAGE
import XCTest
@testable import Chau7

final class RuntimeSessionBehaviorTests: XCTestCase {
    func testDuplicateCompleteTurnLeavesSessionReady() {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-duplicate-complete", provider: "claude")
        )

        session.transition(.backendReady)
        XCTAssertNotNil(session.startTurn(prompt: "Hello"))

        _ = session.completeTurn(summary: "done", terminalOutput: nil)
        XCTAssertEqual(session.state, .ready)

        _ = session.completeTurn(summary: "duplicate", terminalOutput: nil)
        XCTAssertEqual(session.state, .ready)
    }

    func testDuplicateApprovalRequestWithoutActiveTurnIsIgnored() {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/runtime-duplicate-approval", provider: "claude")
        )

        session.transition(.backendReady)
        let approval = session.requestApproval(tool: "Read", description: "Need approval")

        XCTAssertNil(approval)
        XCTAssertEqual(session.state, .ready)
        XCTAssertNil(session.pendingApproval)
    }
}
#endif
