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

    func testLaunchCommandDropsInvalidEnvironmentVariableNames() {
        let environment = [
            "SAFE_KEY": "safe value",
            "BAD;KEY": "touch /tmp/pwned"
        ]

        let claudeCommand = ClaudeCodeBackend().launchCommand(
            config: SessionConfig(
                directory: "/tmp",
                provider: "claude",
                environment: environment
            )
        )

        XCTAssertEqual(claudeCommand, "SAFE_KEY='safe value' 'claude'")
        XCTAssertFalse(claudeCommand.contains("BAD;KEY"))
        XCTAssertFalse(claudeCommand.contains("touch /tmp/pwned"))
    }

    func testShellBackendPreservesArgumentBoundaries() {
        let command = GenericShellBackend().launchCommand(
            config: SessionConfig(
                directory: "/tmp",
                provider: "shell",
                args: ["python3", "-c", "print('hello world'); touch /tmp/pwned"]
            )
        )

        XCTAssertEqual(
            command,
            "'python3' '-c' 'print('\\''hello world'\\''); touch /tmp/pwned'"
        )
    }
}
#endif
