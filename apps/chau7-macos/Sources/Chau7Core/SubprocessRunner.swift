import Darwin
import Foundation
import os.log

public enum SubprocessRunner {
    /// Logger for subprocess launch failures. Chau7Core can't depend on the
    /// Chau7 app target's `Log` utility, so this uses os.Logger directly with
    /// an explicit privacy annotation so the error text is visible in
    /// `log show --subsystem com.chau7.core`.
    private static let logger = Logger(subsystem: "com.chau7.core", category: "SubprocessRunner")

    /// Runs a subprocess and returns stdout as UTF-8 text.
    /// Explicitly calls `waitpid` after `waitUntilExit` to avoid leaving zombie
    /// children behind on background queues.
    public static func run(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logger.error(
                "failed to launch \(executablePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var status: Int32 = 0
        waitpid(process.processIdentifier, &status, WNOHANG)

        return String(decoding: data, as: UTF8.self)
    }
}
