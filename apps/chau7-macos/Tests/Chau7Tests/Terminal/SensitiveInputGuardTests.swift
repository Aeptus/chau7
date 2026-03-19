import XCTest
@testable import Chau7Core

final class SensitiveInputGuardTests: XCTestCase {
    func testContainsInlineSecretsDetectsBearerHeader() {
        XCTAssertTrue(
            SensitiveInputGuard.containsInlineSecrets(
                "curl -H 'Authorization: Bearer secret-token' https://example.com"
            )
        )
    }

    func testSanitizedCommandKeepsSafeCommands() {
        XCTAssertEqual(
            SensitiveInputGuard.sanitizedCommandForPersistence("claude --continue"),
            "claude --continue"
        )
    }

    func testSanitizedCommandRedactsInlineSecretButPreservesCommandSummary() {
        XCTAssertEqual(
            SensitiveInputGuard.sanitizedCommandForPersistence("TOKEN=supersecret claude --continue"),
            "claude \(SensitiveInputGuard.redactedPlaceholder)"
        )
    }

    func testSanitizedCommandSkipsSudoWrapperInSummary() {
        XCTAssertEqual(
            SensitiveInputGuard.sanitizedCommandForPersistence("sudo docker login --password hunter2"),
            "docker \(SensitiveInputGuard.redactedPlaceholder)"
        )
    }

    func testSanitizedCommandRedactsEchoDisabledInput() {
        XCTAssertEqual(
            SensitiveInputGuard.sanitizedCommandForPersistence("hunter2", echoDisabled: true),
            SensitiveInputGuard.redactedPlaceholder
        )
    }

    func testSanitizedInputLineDropsEchoDisabledInput() {
        XCTAssertNil(SensitiveInputGuard.sanitizedInputLineForPersistence("hunter2\n", echoDisabled: true))
    }

    func testSanitizedInputLineNormalizesNewlines() {
        XCTAssertEqual(
            SensitiveInputGuard.sanitizedInputLineForPersistence("echo hello\r\n"),
            "echo hello"
        )
    }
}
