import XCTest
@testable import Chau7Core

final class RuntimeToolEventMetadataTests: XCTestCase {
    func testExtractsSimpleFileToolPath() {
        let path = RuntimeToolEventMetadata.extractFilePath(
            toolName: "Read",
            message: "src/AppDelegate.swift",
            cwd: "/tmp/project"
        )
        XCTAssertEqual(path, "/tmp/project/src/AppDelegate.swift")
    }

    func testExtractsBashFileArgument() {
        let path = RuntimeToolEventMetadata.extractFilePath(
            toolName: "Bash",
            message: "rg -n EventJournal apps/chau7-macos/Sources/Chau7Core/Runtime/EventJournal.swift",
            cwd: "/tmp/project"
        )
        XCTAssertEqual(path, "/tmp/project/apps/chau7-macos/Sources/Chau7Core/Runtime/EventJournal.swift")
    }

    func testArgsSummaryTruncatesLongMessages() {
        let message = String(repeating: "a", count: 240)
        let summary = RuntimeToolEventMetadata.argsSummary(from: message)
        XCTAssertEqual(summary?.count, 200)
    }

    func testInferResultExtractsExitCodeAndError() {
        let result = RuntimeToolEventMetadata.inferResult(
            toolName: "Bash",
            message: "Command failed with exit code 2: rg: file not found"
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertNotNil(result.error)
        XCTAssertNotNil(result.outputPreview)
    }

    func testInferResultDefaultsToSuccessWithoutFailureSignals() {
        let result = RuntimeToolEventMetadata.inferResult(
            toolName: "Read",
            message: "Read 120 lines from RuntimeSession.swift"
        )
        XCTAssertTrue(result.success)
        XCTAssertNil(result.exitCode)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outputPreview, "Read 120 lines from RuntimeSession.swift")
    }
}
