#if os(macOS)
import Darwin
import Foundation
import os.log

/// Bounded capture for short-lived monitoring commands, never interactive shells.
public enum SubprocessRunner {
    public struct Result: Sendable {
        public let status: Int32?
        public let stdout: Data
        public let stderr: Data
        public let timedOut: Bool
        public let outputLimitExceeded: Bool
        public let readFailed: Bool

        public var completed: Bool {
            status != nil && !timedOut && !outputLimitExceeded && !readFailed
        }
    }

    private static let logger = Logger(subsystem: "com.chau7.core", category: "SubprocessRunner")

    /// Never publish partial or unsuccessful command output through the text interface.
    public static func run(executablePath: String, arguments: [String]) -> String? {
        guard let result = capture(executablePath: executablePath, arguments: arguments),
              result.completed, result.status == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Drains both pipes together so a full stderr pipe cannot deadlock stdout.
    /// The deadline also covers children that exit while descendants retain a pipe.
    /// Only the owned command is terminated on a limit; no terminal/process group is signalled.
    public static func capture(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = 4 * 1024 * 1024
    ) -> Result? {
        guard timeout.isFinite, timeout > 0, maximumOutputBytes > 0 else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        defer {
            for handle in handles {
                try? handle.close()
            }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }

        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                return nil
            }
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try process.run()
        } catch {
            logger.error("failed to launch \(executablePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // The parent must not keep the child ends open or EOF never arrives.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        var output = [Data(), Data()]
        var totalBytes = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var timedOut = false
        var outputLimitExceeded = false
        var readFailed = false

        while true {
            // Cap each drain batch so continuous stdout cannot starve stderr or the deadline.
            for index in descriptors.indices where descriptors[index].fd >= 0 {
                for _ in 0 ..< 16 {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptors[index].fd, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        let retained = min(count, maximumOutputBytes - totalBytes)
                        output[index].append(contentsOf: buffer.prefix(retained))
                        totalBytes += retained
                        if retained < count {
                            outputLimitExceeded = true
                            break
                        }
                    } else if count == 0 {
                        descriptors[index].fd = -1
                        break
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else if errno != EINTR {
                        readFailed = true
                        break
                    }
                }
                if outputLimitExceeded || readFailed { break }
            }
            if outputLimitExceeded || readFailed { break }
            if descriptors.allSatisfy({ $0.fd < 0 }), !process.isRunning { break }
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - startedAt)
            if remaining <= 0 {
                timedOut = true
                break
            }
            let waitMilliseconds = Int32(min(50, ceil(remaining * 1000)))
            let pollResult = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), waitMilliseconds)
            }
            if pollResult < 0, errno != EINTR {
                readFailed = true
                break
            }
        }

        if process.isRunning {
            process.terminate()
            waitForExit(process, for: 0.2)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                waitForExit(process, for: 0.3)
            }
        }
        // Foundation owns reaping this Process. A second waitpid can race its
        // termination observer; never wait indefinitely after a failed deadline.
        let status = process.isRunning ? nil : process.terminationStatus
        return Result(
            status: status,
            stdout: output[0],
            stderr: output[1],
            timedOut: timedOut,
            outputLimitExceeded: outputLimitExceeded,
            readFailed: readFailed
        )
    }

    private static func waitForExit(_ process: Process, for grace: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + grace
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
#endif
