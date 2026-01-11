import Foundation
import Darwin

enum Log {
    static var sink: ((String) -> Void)?

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fileQueue = DispatchQueue(label: "com.chau7.logfile")
    private static var fileHandle: FileHandle?
    private static var isConfigured = false
    private static var filePathValue = ""

    static let isVerbose: Bool = {
        if EnvVars.get(EnvVars.verbose, legacy: EnvVars.legacyVerbose) == "1" {
            return true
        }
        return isatty(STDOUT_FILENO) == 1
    }()

    static let isTraceEnabled: Bool = {
        if EnvVars.get(EnvVars.trace, legacy: EnvVars.legacyTrace) == "1" {
            return true
        }
        if EnvVars.get(EnvVars.verbose, legacy: EnvVars.legacyVerbose) == "1" {
            return true
        }
        return false
    }()

    static var filePath: String {
        filePathValue
    }

    static func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        let envPath = EnvVars.get(EnvVars.logFile, legacy: EnvVars.legacyLogFile)
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Chau7.log").path
        let path = envPath ?? defaultPath
        filePathValue = path

        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
        } catch {
            fileHandle = nil
        }
    }

    static func info(_ message: String) {
        emit(level: "INFO", message: message)
    }

    static func warn(_ message: String) {
        emit(level: "WARN", message: message)
    }

    static func error(_ message: String) {
        emit(level: "ERROR", message: message)
    }

    static func trace(_ message: String) {
        guard isTraceEnabled else { return }
        emit(level: "TRACE", message: message)
    }

    private static func emit(level: String, message: String) {
        let ts = formatter.string(from: Date())
        let line = "[Chau7][\(level)] \(ts) \(message)"
        sink?(line)
        if isVerbose {
            print(line)
        }
        writeToFile(line)
    }

    private static func writeToFile(_ line: String) {
        guard let handle = fileHandle else { return }
        let data = (line + "\n").data(using: .utf8) ?? Data()
        fileQueue.async {
            try? handle.write(contentsOf: data)
        }
    }
}
