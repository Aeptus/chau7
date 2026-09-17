import XCTest
@testable import Chau7Core

final class SubprocessRunnerTests: XCTestCase {
    func testDrainsLargeStderrBeforeStdoutWithoutDeadlocking() throws {
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 1>&2 2>/dev/null; printf done"],
            timeout: 3
        ))
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done")
        XCTAssertEqual(result.stderr.count, 256 * 1024)
    }

    func testDeadlineTerminatesAnOwnedStalledCommand() throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/bin/sleep", arguments: ["10"], timeout: 0.1
        ))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.completed)
        XCTAssertNotNil(result.status, "The owned command must have exited")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 2)
    }

    func testDeadlineStillAppliesWhenCommandClosesItsPipes() throws {
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/bin/sh",
            arguments: ["-c", "exec 1>&- 2>&-; exec /bin/sleep 10"],
            timeout: 0.1
        ))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.completed)
    }

    func testDeadlineEscalatesOnlyTheOwnedCommandWhenItIgnoresTermination() throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 10"],
            timeout: 0.1
        ))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.status, 9)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 2)
    }

    func testDeadlineDoesNotWaitForDescendantToCloseInheritedPipes() throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/bin/sh", arguments: ["-c", "/bin/sleep 1 & exit 0"], timeout: 0.1
        ))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.completed)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 0.9)
    }

    func testCombinedOutputLimitBoundsCapture() throws {
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 12345; printf 67890 >&2"],
            maximumOutputBytes: 8
        ))
        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.stdout.count + result.stderr.count, 8)
    }

    func testExactOutputLimitIsNotTruncation() throws {
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/bin/echo", arguments: ["-n", "12345678"], maximumOutputBytes: 8
        ))
        XCTAssertTrue(result.completed)
        XCTAssertFalse(result.outputLimitExceeded)
        XCTAssertEqual(result.stdout.count, 8)
    }

    func testContinuousOutputCannotBypassLimit() throws {
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/usr/bin/yes", arguments: [], timeout: 2, maximumOutputBytes: 4096
        ))
        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 4096)
    }

    func testCapturePreservesExitStatusButTextInterfaceRejectsFailure() throws {
        let arguments = ["-c", "printf partial; printf failed >&2; exit 7"]
        let result = try XCTUnwrap(SubprocessRunner.capture(executablePath: "/bin/sh", arguments: arguments))
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "failed")
        XCTAssertNil(SubprocessRunner.run(executablePath: "/bin/sh", arguments: arguments))
    }

    func testCommandsGetEOFOnStdinAndExplicitEnvironmentAndDirectory() throws {
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: "/bin/sh",
            arguments: ["-c", "read value && exit 9; printf '%s:%s' \"$PWD\" \"$CHAU7_CAPTURE_FIXTURE\""],
            currentDirectoryURL: URL(fileURLWithPath: "/private/tmp"),
            environment: ["CHAU7_CAPTURE_FIXTURE": "ok"]
        ))
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "/private/tmp:ok")
    }

    func testInvalidLimitsDoNotLaunch() {
        for timeout in [0.0, -1.0, .infinity, .nan] {
            XCTAssertNil(SubprocessRunner.capture(executablePath: "/bin/echo", arguments: [], timeout: timeout))
        }
        XCTAssertNil(SubprocessRunner.capture(executablePath: "/bin/echo", arguments: [], maximumOutputBytes: 0))
    }

    func testRunCapturesStdout() {
        let output = SubprocessRunner.run(
            executablePath: "/bin/echo",
            arguments: ["chau7"]
        )

        XCTAssertEqual(output, "chau7\n")
    }

    func testRunReturnsNilForMissingExecutable() {
        XCTAssertNil(
            SubprocessRunner.run(
                executablePath: "/path/that/does/not/exist",
                arguments: []
            )
        )
    }
}
