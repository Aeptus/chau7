import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class BackendLaunchCommandTests: XCTestCase {
    func testCodexLaunchCommandEscapesResumeSessionID() {
        let command = CodexBackend().launchCommand(
            config: SessionConfig(
                directory: "/tmp",
                provider: "codex",
                resumeSessionID: "abc; touch /tmp/pwned"
            )
        )

        XCTAssertEqual(command, "'codex' 'resume' 'abc; touch /tmp/pwned'")
    }

    func testClaudeLaunchCommandEscapesResumeSessionID() {
        let command = ClaudeCodeBackend().launchCommand(
            config: SessionConfig(
                directory: "/tmp",
                provider: "claude",
                resumeSessionID: "abc; touch /tmp/pwned"
            )
        )

        XCTAssertEqual(command, "'claude' '--resume' 'abc; touch /tmp/pwned'")
    }
}
#endif
