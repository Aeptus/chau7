import Foundation
import os.log
import Darwin

enum ManagedProcess {
    static func cleanup(outputPipe: inout Pipe?, errorPipe: inout Pipe?) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
    }

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
