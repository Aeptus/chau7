import Foundation
import os.log
import Darwin

enum ManagedProcess {

    // MARK: - Pipe Output Monitoring

    /// Installs a `readabilityHandler` on a pipe's reading end that forwards
    /// non-empty output to `onData` and **automatically stops monitoring on
    /// EOF** (empty `availableData`). This prevents the 100%-CPU spin loop
    /// that occurs when a readabilityHandler keeps firing on a closed fd.
    ///
    /// - Parameters:
    ///   - pipe: The `Pipe` whose reading end to monitor.
    ///   - onData: Called on a background queue with each chunk of output.
    ///             Receives the raw `Data`; the caller is responsible for
    ///             decoding and dispatching to the appropriate thread.
    static func monitorOutput(of pipe: Pipe, onData: @escaping (Data) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — the write end was closed (process exited or pipe torn
                // down). Stop the dispatch source immediately to prevent a
                // spin loop. After this assignment the handler will never fire
                // again for this file handle.
                handle.readabilityHandler = nil
                return
            }
            onData(data)
        }
    }

    // MARK: - Cleanup

    static func cleanup(outputPipe: inout Pipe?, errorPipe: inout Pipe?) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
    }

    // MARK: - Termination

    static func terminate(_ process: Process, name: String, logger: Logger) {
        guard process.isRunning else { return }

        process.terminate()
        if waitForExit(of: process, timeout: 1.0) {
            return
        }

        logger.warning("\(name) did not exit after SIGTERM; sending SIGINT")
        process.interrupt()
        if waitForExit(of: process, timeout: 0.5) {
            return
        }

        let pid = process.processIdentifier
        logger.error("\(name) still running after SIGINT; sending SIGKILL to pid \(pid)")
        _ = Darwin.kill(pid, SIGKILL)
        _ = waitForExit(of: process, timeout: 0.5)
    }

    private static func waitForExit(of process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50000)
        }
        return !process.isRunning
    }
}
