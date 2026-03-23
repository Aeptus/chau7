import Foundation
import Chau7Core

final class AITerminalLogSession {
    let toolName: String
    private let logPath: String
    private let queue = DispatchQueue(label: "com.chau7.ptylog.\(UUID().uuidString)")
    private var inputBuffer = Data()
    private var writeCount = 0
    private let maxBytes: Int = {
        if let raw = EnvVars.get(EnvVars.ptyLogMaxBytes),
           let value = Int(raw), value > 0 {
            return value
        }
        return 10 * 1024 * 1024 // 10 MB
    }()

    init(toolName: String, logPath: String) {
        self.toolName = toolName
        self.logPath = RuntimeIsolation.expandTilde(in: logPath)
    }

    func recordOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let ok = appendLocked(data)
            writeCount += 1
            // Trim every 200 writes, or immediately on write failure (disk full)
            if !ok || writeCount.isMultiple(of: 200) {
                trimLogIfNeeded()
            }
        }
    }

    func recordInput(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            inputBuffer.append(data)
            if data.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
                flushInputLocked()
            }
        }
    }

    func close() {
        queue.sync { [weak self] in
            guard let self else { return }
            flushInputLocked()
        }
    }

    @discardableResult
    private func appendLocked(_ data: Data) -> Bool {
        FileOperations.appendData(data, to: URL(fileURLWithPath: logPath))
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
        do {
            let data = try Data(contentsOf: url)
            let start = data.count > keepBytes ? data.count - Int(keepBytes) : 0
            let tail = data.subdata(in: start ..< data.count)
            // Atomic write avoids truncate-then-write race.
            try tail.write(to: url, options: .atomic)
        } catch {
            Log.error("AITerminalLogSession trim failed: \(error)")
        }
    }

    private func flushInputLocked() {
        guard !inputBuffer.isEmpty else { return }
        let text = String(decoding: inputBuffer, as: UTF8.self)
        inputBuffer.removeAll(keepingCapacity: true)
        guard let sanitized = SensitiveInputGuard.sanitizedInputLineForPersistence(text) else { return }
        let line = "[INPUT] \(sanitized)\n"
        if let payload = line.data(using: .utf8) {
            _ = appendLocked(payload)
        }
    }
}

enum AIEventLogWriter {
    private static let queue = DispatchQueue(label: "com.chau7.ai-event-log")

    static func appendEvent(type: String, tool: String, message: String, source: AIEventSource, logPath: String) {
        let trimmed = logPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = RuntimeIsolation.expandTilde(in: trimmed)
        let payload: [String: Any] = [
            "source": source.rawValue,
            "type": type,
            "tool": tool,
            "message": message,
            "ts": Chau7Core.DateFormatters.nowISO8601()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }

        queue.async {
            let url = URL(fileURLWithPath: expanded)
            var line = data
            line.append(0x0A)
            guard FileOperations.appendData(line, to: url) else {
                Log.warn("Failed to append AI events log at \(expanded)")
                return
            }
        }
    }
}
