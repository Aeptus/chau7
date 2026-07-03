import os.log
import XCTest
@testable import Chau7

/// Exercises the shared Go-sidecar lifecycle with tiny shell-script stubs in
/// place of the real chau7-remote/chau7-proxy binaries: launch → running,
/// output handlers receive stdout/stderr, deliberate stop terminates without
/// firing the exit handler, and unexpected exits surface through `onExit`
/// (the seam the managers' restart/error policies hang off).
@MainActor
final class ManagedGoSidecarTests: XCTestCase {

    /// Thread-safe stdout/stderr accumulator; the sidecar's output handlers
    /// fire on a background queue.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            chunks.append(data)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return chunks.map { String(decoding: $0, as: UTF8.self) }.joined()
        }
    }

    /// Records `onExit` statuses; only touched on the main actor.
    private final class ExitRecorder {
        private(set) var statuses: [Int32] = []
        func record(_ status: Int32) {
            statuses.append(status)
        }
    }

    private let logger = Logger(subsystem: "com.chau7.tests", category: "ManagedGoSidecarTests")

    /// Async poll helper. `RunLoop.main.run` does not drain main-queue work
    /// from an async context, so tests await `Task.sleep` instead.
    private func waitUntilAsync(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Writes a `#!/bin/sh` stub script into a fresh temp directory and
    /// returns its URL alongside the directory (used as the launch cwd).
    /// The script is written non-executable on purpose — `launch()` owns the
    /// chmod, so launching also covers that step.
    private func makeScript(_ body: String) throws -> (script: URL, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedGoSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stub.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return (url, dir)
    }

    private func makeSidecar(
        stdout: OutputCollector,
        stderr: OutputCollector,
        exits: ExitRecorder,
        stopsPipeMonitoringBeforeTerminate: Bool = false
    ) -> ManagedGoSidecar {
        ManagedGoSidecar(
            configuration: ManagedGoSidecar.Configuration(
                name: "test sidecar",
                logger: logger,
                stopsPipeMonitoringBeforeTerminate: stopsPipeMonitoringBeforeTerminate,
                onStdoutData: { stdout.append($0) },
                onStderrData: { stderr.append($0) },
                onExit: { exits.record($0) }
            )
        )
    }

    // MARK: - Launch and output

    func testLaunchRunsProcessAndRoutesStdoutAndStderr() async throws {
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        let exits = ExitRecorder()
        let sidecar = makeSidecar(stdout: stdout, stderr: stderr, exits: exits)
        let (script, dir) = try makeScript("echo out-hello; echo err-hello 1>&2; sleep 30")

        try sidecar.launch(ManagedGoSidecar.LaunchSpec(
            binaryURL: script,
            currentDirectoryURL: dir,
            environment: ProcessInfo.processInfo.environment
        ))
        defer { sidecar.stop() }

        XCTAssertTrue(sidecar.hasProcess)
        XCTAssertTrue(sidecar.isProcessRunning)

        await waitUntilAsync {
            stdout.text.contains("out-hello") && stderr.text.contains("err-hello")
        }
        XCTAssertTrue(stdout.text.contains("out-hello"), "stdout handler should receive script output")
        XCTAssertTrue(stderr.text.contains("err-hello"), "stderr handler should receive script output")
        XCTAssertFalse(stdout.text.contains("err-hello"), "streams must not be cross-wired")
        XCTAssertTrue(exits.statuses.isEmpty, "onExit must not fire while the process runs")
    }

    func testLaunchSpecPassesArgumentsEnvironmentAndWorkingDirectory() async throws {
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        let exits = ExitRecorder()
        let sidecar = makeSidecar(stdout: stdout, stderr: stderr, exits: exits)
        let (script, dir) = try makeScript(#"echo "arg=$1 var=$CHAU7_SIDECAR_TEST cwd=$(pwd)""#)

        var env = ProcessInfo.processInfo.environment
        env["CHAU7_SIDECAR_TEST"] = "injected"
        try sidecar.launch(ManagedGoSidecar.LaunchSpec(
            binaryURL: script,
            arguments: ["alpha"],
            currentDirectoryURL: dir,
            environment: env
        ))

        await waitUntilAsync { stdout.text.contains("cwd=") }
        let output = stdout.text
        XCTAssertTrue(output.contains("arg=alpha"), "arguments should reach the child: \(output)")
        XCTAssertTrue(output.contains("var=injected"), "environment should reach the child: \(output)")
        // Compare on the unique directory name: `pwd` reports the physical
        // /private/var/... path while URL APIs report the /var/... symlink.
        XCTAssertTrue(output.contains(dir.lastPathComponent), "cwd should be the spec's directory: \(output)")
    }

    // MARK: - Stop

    func testStopTerminatesProcessWithoutFiringExitHandler() async throws {
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        let exits = ExitRecorder()
        let sidecar = makeSidecar(stdout: stdout, stderr: stderr, exits: exits)
        let (script, dir) = try makeScript("echo ready; sleep 30")

        try sidecar.launch(ManagedGoSidecar.LaunchSpec(
            binaryURL: script,
            currentDirectoryURL: dir,
            environment: ProcessInfo.processInfo.environment
        ))
        await waitUntilAsync { stdout.text.contains("ready") }

        sidecar.stop()

        XCTAssertFalse(sidecar.hasProcess)
        XCTAssertFalse(sidecar.isProcessRunning)
        // Give a detached (buggy) termination handler a chance to fire.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(exits.statuses.isEmpty, "a deliberate stop must not invoke onExit")
    }

    func testStopBeforeLaunchIsANoOp() {
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        let exits = ExitRecorder()
        let sidecar = makeSidecar(stdout: stdout, stderr: stderr, exits: exits)

        sidecar.stop()
        sidecar.clearProcessAfterExit()

        XCTAssertFalse(sidecar.hasProcess)
        XCTAssertFalse(sidecar.isProcessRunning)
        XCTAssertTrue(exits.statuses.isEmpty)
    }

    /// The proxy's configured teardown order (pipes first) must also stop the
    /// process cleanly.
    func testStopWithPipeMonitoringTornDownFirst() async throws {
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        let exits = ExitRecorder()
        let sidecar = makeSidecar(
            stdout: stdout,
            stderr: stderr,
            exits: exits,
            stopsPipeMonitoringBeforeTerminate: true
        )
        let (script, dir) = try makeScript("echo ready; sleep 30")

        try sidecar.launch(ManagedGoSidecar.LaunchSpec(
            binaryURL: script,
            currentDirectoryURL: dir,
            environment: ProcessInfo.processInfo.environment
        ))
        await waitUntilAsync { stdout.text.contains("ready") }

        sidecar.stop()

        XCTAssertFalse(sidecar.hasProcess)
        XCTAssertFalse(sidecar.isProcessRunning)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(exits.statuses.isEmpty)
    }

    // MARK: - Unexpected exit

    func testExitHandlerReceivesStatusWhenProcessDies() async throws {
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        let exits = ExitRecorder()
        let sidecar = makeSidecar(stdout: stdout, stderr: stderr, exits: exits)
        let (script, dir) = try makeScript("exit 3")

        try sidecar.launch(ManagedGoSidecar.LaunchSpec(
            binaryURL: script,
            currentDirectoryURL: dir,
            environment: ProcessInfo.processInfo.environment
        ))

        await waitUntilAsync { exits.statuses == [3] }
        XCTAssertEqual(exits.statuses, [3], "onExit should fire once with the termination status")
        XCTAssertFalse(sidecar.isProcessRunning)
        // Remote-agent semantics: the stale reference survives an unexpected
        // exit until the owner stops or clears it.
        XCTAssertTrue(sidecar.hasProcess)

        sidecar.clearProcessAfterExit()
        XCTAssertFalse(sidecar.hasProcess)
    }
}
