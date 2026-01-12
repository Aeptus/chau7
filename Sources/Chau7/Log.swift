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
    private static var writeCount = 0
    private static let maxLogBytes: Int = {
        if let raw = EnvVars.get(EnvVars.logMaxBytes),
           let value = Int(raw), value > 0 {
            return value
        }
        return 10 * 1024 * 1024
    }()

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
        // Note: Can't use FileOperations here to avoid circular dependency with Log
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
            writeCount += 1
            if writeCount % 200 == 0 {
                trimLogFileIfNeeded()
            }
        }
    }

    private static func trimLogFileIfNeeded() {
        guard maxLogBytes > 0 else { return }
        let url = URL(fileURLWithPath: filePathValue)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64 else {
            return
        }
        let maxBytes = UInt64(maxLogBytes)
        guard size > maxBytes else { return }

        let keepBytes = maxBytes / 2
        guard let readHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? readHandle.close() }

        let start = size > keepBytes ? size - keepBytes : 0
        try? readHandle.seek(toOffset: start)
        guard let tailData = try? readHandle.readToEnd() else { return }

        try? fileHandle?.close()
        guard let writeHandle = try? FileHandle(forWritingTo: url) else { return }
        try? writeHandle.truncate(atOffset: 0)
        try? writeHandle.write(contentsOf: tailData)
        try? writeHandle.seekToEnd()
        fileHandle = writeHandle
    }
}
