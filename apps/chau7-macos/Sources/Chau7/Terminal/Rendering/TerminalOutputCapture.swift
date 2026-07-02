import Foundation
import Chau7Core

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
    private let formatter = DateFormatters.iso8601NoFractional
    private var writeCount = 0
    /// Set to `true` after a write error fails non-recoverably (typically
    /// ENOSPC). All further writes for this session short-circuit. Reset only
    /// by an app relaunch — debug capture isn't worth retrying forever on a
    /// full disk and definitely isn't worth crashing the app over.
    /// Read/written only on `queue`, so no synchronization needed.
    private var isCaptureSuspended = false
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

        let defaultDir = RuntimeIsolation.logsDirectory()
            .appendingPathComponent("Chau7", isDirectory: true).path
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
            guard let self, !self.isCaptureSuspended else { return }
            let line = "\(timestamp) | PTY | \(source) | bytes=\(data.count) | \(escaped)\n"
            guard let payload = line.data(using: .utf8) else { return }
            appendOrDisable(payload)
            writeCount += 1
            if !isCaptureSuspended, writeCount.isMultiple(of: 200) {
                trimLogIfNeeded()
            }
        }
    }

    /// Records a non-data marker line into the capture log so an anomaly
    /// detector elsewhere (e.g. render-side diagnostic) can flag a position
    /// in the PTY byte stream worth re-reading. Search the log for `ANOMALY`
    /// to land on these. No-op when `isEnabled` is false (so this stays free
    /// of cost when the user hasn't opted into capture).
    func recordMarker(_ message: String) {
        guard isEnabled else { return }
        let timestamp = formatter.string(from: Date())

        queue.async { [weak self] in
            guard let self, !self.isCaptureSuspended else { return }
            let line = "\(timestamp) | ANOMALY | \(message)\n"
            guard let payload = line.data(using: .utf8) else { return }
            appendOrDisable(payload)
            writeCount += 1
        }
    }

    /// Append `payload` to the capture log via the throwing `write(contentsOf:)`
    /// API. Must be called on `queue`. Returning `Bool` is intentionally avoided
    /// — failures are non-recoverable for this debug-only path:
    ///
    ///   - `write(contentsOf:)` throws Swift errors (catchable), unlike the
    ///     legacy `write(_: Data)` overload that bridges to
    ///     `-[NSFileHandle writeData:]` and raises `NSFileHandleOperationException`
    ///     on ENOSPC / EIO / EBADF / EPIPE. Swift cannot catch ObjC exceptions,
    ///     so the legacy overload aborts the process — exactly the crash we
    ///     hit on 2026-05-10 at TerminalOutputCapture.swift:71 (disk 97 % full,
    ///     writeData: raised, app abort()ed in Thread 10 / com.chau7.ptycapture).
    ///   - On error we drop the line, close the handle, and disable capture
    ///     for the rest of the session. Reopening would just reproduce the
    ///     same disk-full error on the next write; the user has already opted
    ///     into capture being a debug-only feature, so failing closed beats
    ///     either crashing the app or quietly retrying forever.
    private func appendOrDisable(_ payload: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        if handle == nil {
            openHandle()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: payload)
        } catch {
            Log.warn("PTY capture write failed: \(error). Disabling capture for the rest of this session.")
            try? handle.close()
            self.handle = nil
            isCaptureSuspended = true
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
            case 0x1B:
                result.append("\\x1b")
            case 0x0A:
                result.append("\\n")
            case 0x0D:
                result.append("\\r")
            case 0x09:
                result.append("\\t")
            case 0x20 ... 0x7E:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result.append(String(format: "\\x%02X", byte))
            }
        }
        return result
    }
}
