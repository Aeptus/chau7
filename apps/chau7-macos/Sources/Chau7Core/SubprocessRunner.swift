import Darwin
import Foundation

public enum SubprocessRunner {
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
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var status: Int32 = 0
        waitpid(process.processIdentifier, &status, WNOHANG)

        return String(decoding: data, as: UTF8.self)
    }
}
