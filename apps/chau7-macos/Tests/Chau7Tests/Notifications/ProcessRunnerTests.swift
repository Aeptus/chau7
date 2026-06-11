import XCTest
@testable import Chau7

/// Focused tests for the SIGTERM → SIGKILL escalation that handles
/// scripts that ignore SIGTERM. Uses a trivial shell process that traps
/// SIGTERM and would otherwise hang past the test timeout.
final class ProcessRunnerTests: XCTestCase {

    /// Helper to build a Process running an arbitrary shell snippet.
    private func makeShellProcess(_ snippet: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", snippet]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return process
    }

    func testTerminateReturnsTrueImmediatelyWhenProcessAlreadyExited() {
        let process = makeShellProcess("exit 0")
        try? process.run()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        XCTAssertTrue(
            ProcessRunner.terminate(process, label: "test:noop", gracePeriod: 0.05),
            "Terminate on an exited process must short-circuit to true"
        )
    }

    func testTerminateKillsTrapImmuneCPUBoundLoop() {
        // CPU-bound loop with SIGTERM trapped at the sh level. Naive
        // process.terminate() leaves this running. The value-add of
        // ProcessRunner.terminate() is that it falls back to SIGKILL
        // when the grace period passes — testing the "process actually
        // dies" property rather than which signal did the job, since
        // signal-group propagation depends on the kernel.
        let process = makeShellProcess("trap '' TERM; while :; do :; done")
        try? process.run()
        XCTAssertTrue(process.isRunning)

        _ = ProcessRunner.terminate(
            process,
            label: "test:trap",
            gracePeriod: 0.2
        )

        // Give the kernel a moment to reap after SIGKILL.
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(process.isRunning, "Trap-immune CPU loop must be killed (SIGKILL fallback)")
    }

    func testTerminateUsesSIGTERMWhenProcessHonorsIt() {
        let process = makeShellProcess("while true; do sleep 1; done")
        try? process.run()
        XCTAssertTrue(process.isRunning)

        let exitedWithSIGTERM = ProcessRunner.terminate(
            process,
            label: "test:honors",
            gracePeriod: 1.0
        )

        XCTAssertTrue(exitedWithSIGTERM, "SIGTERM-honoring process must exit before SIGKILL")
    }
}
