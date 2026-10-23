import XCTest
@testable import Chau7Core

/// Regression coverage for the `go build` failure-message contract.
///
/// The bug these lock down: `RemoteAgentBinaryProvider` used to merge the
/// child's stdout and stderr into one `Pipe` and read it only *after*
/// `waitUntilExit()` returned on the main actor. The message-building logic was
/// untestable because it was welded to the view-adjacent provider; moving it
/// here is what makes the precedence between "never launched", "timed out", and
/// "exited non-zero with diagnostics" a real contract.
final class SubprocessFailureMessageTests: XCTestCase {
    private let notLaunched = "Failed to launch."
    private let timedOut = "Timed out."
    private let missingTool = "Make sure Go is installed."

    private func describe(_ result: SubprocessRunner.Result?) -> String? {
        SubprocessFailureMessage.describe(
            result,
            notLaunchedMessage: notLaunched,
            timedOutMessage: timedOut,
            missingToolMessage: missingTool
        )
    }

    private func result(
        status: Int32? = 0,
        stdout: Data = Data(),
        stderr: Data = Data(),
        timedOut: Bool = false,
        outputLimitExceeded: Bool = false,
        readFailed: Bool = false
    ) -> SubprocessRunner.Result {
        SubprocessRunner.Result(
            status: status,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            outputLimitExceeded: outputLimitExceeded,
            readFailed: readFailed
        )
    }

    // MARK: - Success

    /// The only case that must produce no message at all: `nil` is how the
    /// caller learns the build worked.
    func testSuccessfulCaptureProducesNoMessage() {
        XCTAssertNil(describe(result(status: 0, stdout: Data("ok".utf8))))
    }

    // MARK: - Failure precedence

    /// A nil result means the process never started, so the launch message wins
    /// over everything else.
    func testNilResultReportsLaunchFailure() {
        XCTAssertEqual(describe(nil), notLaunched)
    }

    /// A deadline trip is more actionable than the partial output, so it takes
    /// precedence even when diagnostics exist.
    func testTimeoutTakesPrecedenceOverOutput() {
        let timedOutResult = result(
            status: 1,
            stderr: Data("package main: build stopped".utf8),
            timedOut: true
        )

        XCTAssertEqual(describe(timedOutResult), timedOut)
    }

    /// A non-zero exit with no diagnostic text is the shape of a missing
    /// toolchain, which needs its own advice rather than an empty suffix.
    func testSilentNonZeroExitReportsMissingTool() {
        XCTAssertEqual(describe(result(status: 1)), missingTool)
    }

    func testNonZeroExitSurfacesDiagnostic() {
        let failed = result(status: 1, stderr: Data("# github.com/x/y\nundefined: foo".utf8))

        XCTAssertEqual(describe(failed), "Command failed: # github.com/x/y\nundefined: foo")
    }

    /// A truncated diagnostic dump would otherwise be presented as a complete
    /// error, which is actively misleading when debugging a build.
    func testOutputLimitIsDisclosed() {
        let truncated = result(
            status: 1,
            stdout: Data("...3000 lines elided...".utf8),
            outputLimitExceeded: true
        )

        XCTAssertEqual(
            describe(truncated),
            "Output was too large to report fully: ...3000 lines elided..."
        )
    }

    /// A read failure with no output must be reported as a read failure, not as
    /// a missing toolchain. "We could not read the child's output" and "the
    /// child produced no output" send the reader to completely different places,
    /// and conflating them was a real ordering bug in an earlier revision.
    func testReadFailureIsDisclosedEvenWithNoOutput() {
        XCTAssertEqual(
            describe(result(status: nil, readFailed: true)),
            "Failed to read command output: \(missingTool)"
        )
    }

    func testReadFailureWithOutputDisclosesBoth() {
        let readFailed = result(
            status: 1,
            stderr: Data("partial diagnostic".utf8),
            readFailed: true
        )

        XCTAssertEqual(
            describe(readFailed),
            "Failed to read command output: partial diagnostic"
        )
    }

    // MARK: - Merged output

    /// stdout and stderr were historically one pipe, so both halves must appear
    /// in the reconstructed message, stdout first.
    func testMergedOutputJoinsBothStreamsInOrder() {
        let merged = SubprocessFailureMessage.mergedOutput(
            result(stdout: Data("go: finding module\n".utf8), stderr: Data("build constraint\n".utf8))
        )

        XCTAssertEqual(merged, "go: finding module\nbuild constraint")
    }

    func testMergedOutputDropsBlankStreams() {
        let merged = SubprocessFailureMessage.mergedOutput(
            result(stdout: Data("   \n".utf8), stderr: Data("real error\n".utf8))
        )

        XCTAssertEqual(merged, "real error")
    }

    func testMergedOutputTrimsSurroundingWhitespace() {
        let merged = SubprocessFailureMessage.mergedOutput(result(stdout: Data("\n\n  hello  \n\n".utf8)))

        XCTAssertEqual(merged, "hello")
    }

    func testMergedOutputIsEmptyWhenBothStreamsBlank() {
        XCTAssertEqual(SubprocessFailureMessage.mergedOutput(result()), "")
    }
}
