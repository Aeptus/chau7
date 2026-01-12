import Foundation

// MARK: - Terminal Output Capture

/// Captures raw PTY (pseudo-terminal) data for debugging and analysis.
///
/// This class logs all terminal I/O to a file when enabled via environment variables.
/// Useful for debugging terminal emulation issues, ANSI parsing bugs, or understanding
/// raw terminal data flow.
///
/// ## Environment Variables
/// - `CHAU7_PTY_DUMP=1` or `CHAU7_TRACE_PTY=true`: Enable capture
/// - `CHAU7_PTY_DUMP_PATH`: Custom log file path (default: ~/Library/Logs/Chau7/pty-capture.log)
///
/// ## Log Format
/// ```
/// 2024-01-15T10:30:45Z | PTY | read | bytes=128 | \x1b[31mHello\x1b[0m\n
/// ```
final class TerminalOutputCapture {
    static let shared = TerminalOutputCapture()

    private let isEnabled: Bool
    private let logPath: String
    private let queue = DispatchQueue(label: "com.chau7.ptycapture")
    private var handle: FileHandle?
    private let formatter = ISO8601DateFormatter()
    private var writeCount = 0
    private let maxBytes: Int = {
        if let raw = EnvVars.get(EnvVars.ptyDumpMaxBytes),
           let value = Int(raw), value > 0 {
            return value
        }
        return 20 * 1024 * 1024
    }()

    private init() {
        let env = ProcessInfo.processInfo.environment
        let raw = env["CHAU7_PTY_DUMP"] ?? env["CHAU7_TRACE_PTY"]
        let enabled = raw == "1" || raw?.lowercased() == "true"
        self.isEnabled = enabled

        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Chau7").path
        let defaultPath = "\(defaultDir)/pty-capture.log"
        self.logPath = env["CHAU7_PTY_DUMP_PATH"] ?? defaultPath

        if isEnabled {
            openHandle()
        }
    }

    /// Records terminal data to the capture log.
    ///
    /// - Parameters:
    ///   - data: Raw bytes from PTY read/write
    ///   - source: Label for the data source (e.g., "read", "write")
    func record(data: Data, source: String) {
        guard isEnabled else { return }
        let escaped = Self.escape(data: data)
        let timestamp = formatter.string(from: Date())

        queue.async { [weak self] in
            guard let self else { return }
            if self.handle == nil {
                self.openHandle()
            }
            guard let handle = self.handle else { return }
            let line = "\(timestamp) | PTY | \(source) | bytes=\(data.count) | \(escaped)\n"
            if let payload = line.data(using: .utf8) {
                handle.write(payload)
            }
            self.writeCount += 1
            if self.writeCount % 200 == 0 {
                self.trimLogIfNeeded()
            }
        }
    }

    private func openHandle() {
        let url = URL(fileURLWithPath: logPath)
        let dir = url.deletingLastPathComponent()
        FileOperations.createDirectory(at: dir)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func trimLogIfNeeded() {
        guard maxBytes > 0 else { return }
        let url = URL(fileURLWithPath: logPath)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64 else {
            return
        }
        let max = UInt64(maxBytes)
        guard size > max else { return }

        let keepBytes = max / 2
        guard let readHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? readHandle.close() }

        let start = size > keepBytes ? size - keepBytes : 0
        try? readHandle.seek(toOffset: start)
        guard let tail = try? readHandle.readToEnd() else { return }

        try? handle?.close()
        guard let writeHandle = try? FileHandle(forWritingTo: url) else { return }
        try? writeHandle.truncate(atOffset: 0)
        try? writeHandle.write(contentsOf: tail)
        _ = try? writeHandle.seekToEnd()
        handle = writeHandle
    }

    private static func escape(data: Data) -> String {
        var result = String()
        result.reserveCapacity(data.count * 2)

        for byte in data {
            switch byte {
            case 0x1b:
                result.append("\\x1b")
            case 0x0a:
                result.append("\\n")
            case 0x0d:
                result.append("\\r")
            case 0x09:
                result.append("\\t")
            case 0x20...0x7e:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result.append(String(format: "\\x%02X", byte))
            }
        }
        return result
    }
}
