import XCTest
@testable import Chau7Core

final class ShellCommandOutcomePolicyTests: XCTestCase {
    func testClassifiesPackageAndTaskRunnerScripts() {
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("npm run build"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("pnpm lint"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("yarn test"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("swift test"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("cargo clippy"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("make verify"), .script)
    }

    func testClassifiesScriptFilesAndInterpreterInvocations() {
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("./Scripts/ci-local"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("python3 tools/check.py"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("bash scripts/release"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("node tools/check.mjs"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("swift tools/check.swift"), .script)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("python -m pytest"), .script)
    }

    func testKeepsOrdinaryAndPackageManagementCommandsQuiet() {
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("ls -la"), .ordinary)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("git status"), .ordinary)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("npm install"), .ordinary)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("pnpm add swift-argument-parser"), .ordinary)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("python -c 'print(1)'"), .ordinary)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("swift package resolve"), .ordinary)
    }

    func testClassifiesDevServersBeforeGeneralScripts() {
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("npm run dev"), .devServer)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("pnpm start"), .devServer)
        XCTAssertEqual(ShellCommandOutcomePolicy.classify("npx vite"), .devServer)
    }

    func testIntentionalDevServerStopsAreNotFailures() {
        XCTAssertFalse(ShellCommandOutcomePolicy.devServerExitIsFailure(0))
        XCTAssertFalse(ShellCommandOutcomePolicy.devServerExitIsFailure(130))
        XCTAssertFalse(ShellCommandOutcomePolicy.devServerExitIsFailure(143))
        XCTAssertTrue(ShellCommandOutcomePolicy.devServerExitIsFailure(1))
        XCTAssertTrue(ShellCommandOutcomePolicy.devServerExitIsFailure(137))
    }

    func testCompletionDispositionRequiresAuthoritativeStatus() {
        XCTAssertEqual(
            ShellCommandOutcomePolicy.completionDisposition(commandLine: "swift test", exitCode: 0),
            .scriptSucceeded
        )
        XCTAssertEqual(
            ShellCommandOutcomePolicy.completionDisposition(commandLine: "swift test", exitCode: 1),
            .scriptFailed
        )
        XCTAssertEqual(
            ShellCommandOutcomePolicy.completionDisposition(commandLine: "swift test", exitCode: nil),
            .suppress
        )
        XCTAssertEqual(
            ShellCommandOutcomePolicy.completionDisposition(commandLine: "npm run dev", exitCode: 130),
            .suppress
        )
        XCTAssertEqual(
            ShellCommandOutcomePolicy.completionDisposition(commandLine: "npm run dev", exitCode: 137),
            .devServerFailed
        )
        XCTAssertEqual(
            ShellCommandOutcomePolicy.completionDisposition(commandLine: "git status", exitCode: 1),
            .ordinary
        )
    }
}
