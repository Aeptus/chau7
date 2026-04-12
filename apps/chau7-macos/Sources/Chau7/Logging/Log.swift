import Foundation
import Darwin
import Chau7Core

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
        let defaultPath = RuntimeIsolation.logsDirectory()
            .appendingPathComponent("Chau7.log").path
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
            fputs("[Chau7] WARNING: Failed to open log file at \(path): \(error)\n", stderr)
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

    static func debug(_ message: String) {
        emit(level: "DEBUG", message: message)
    }

    static func trace(_ message: String) {
        guard isTraceEnabled else { return }
        emit(level: "TRACE", message: message)
    }

    // MARK: - Wakeup Tracking

    private static var wakeupCounts: [String: Int] = [:]
    private static var wakeupFlushTimer: DispatchSourceTimer?
    private static let wakeupFlushInterval: TimeInterval = 300 // 5 minutes
    private static let wakeupQueue = DispatchQueue(label: "com.chau7.wakeup", qos: .utility)

    /// Increment a named wakeup counter. Call from any timer/poll callback.
    /// Summaries are logged every 5 minutes.
    static func wakeup(_ source: String) {
        wakeupQueue.async {
            wakeupCounts[source, default: 0] += 1
            if wakeupFlushTimer == nil {
                startWakeupFlushTimer()
            }
        }
    }

    private static func startWakeupFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: wakeupQueue)
        timer.schedule(
            deadline: .now() + wakeupFlushInterval,
            repeating: wakeupFlushInterval,
            leeway: .seconds(30)
        )
        timer.setEventHandler {
            flushWakeupStats()
        }
        timer.resume()
        wakeupFlushTimer = timer
    }

    private static func flushWakeupStats() {
        guard !wakeupCounts.isEmpty else {
            // No activity since last flush — stop the timer to avoid idle wakeups
            wakeupFlushTimer?.cancel()
            wakeupFlushTimer = nil
            return
        }
        let snapshot = wakeupCounts
        wakeupCounts.removeAll(keepingCapacity: true)
        let total = snapshot.values.reduce(0, +)
        let breakdown = snapshot.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        info("Wakeup stats (5m): \(breakdown) total=\(total)")
    }

    private static func emit(level: String, message: String) {
        let ts = formatter.string(from: Date())
        let line = "[Chau7][\(level)] \(ts) \(message)"
        sink?(line)
        if isVerbose {
            print(line) // swiftlint:disable:this no_print_statements
        }
        writeToFile(line)
    }

    private static func writeToFile(_ line: String) {
        writeRaw(line)
    }

    static func writeRaw(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        fileQueue.async {
            // Lazy recovery: if fileHandle is nil (configure failed or trim broke it), retry once
            if fileHandle == nil, !filePathValue.isEmpty {
                let url = URL(fileURLWithPath: filePathValue)
                if let h = try? FileHandle(forWritingTo: url) {
                    _ = try? h.seekToEnd()
                    fileHandle = h
                }
            }
            guard let handle = fileHandle else { return }
            try? handle.write(contentsOf: data)
            writeCount += 1
            if writeCount.isMultiple(of: 200) {
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
        fileHandle = nil
        guard let writeHandle = try? FileHandle(forWritingTo: url) else {
            fputs("[Chau7] WARNING: Failed to reopen log after trim\n", stderr)
            return
        }
        try? writeHandle.truncate(atOffset: 0)
        try? writeHandle.write(contentsOf: tailData)
        _ = try? writeHandle.seekToEnd()
        fileHandle = writeHandle
    }
}
