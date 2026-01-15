import Foundation
import Chau7Core

final class AITerminalLogSession {
    private let toolName: String
    private let logPath: String
    private let queue = DispatchQueue(label: "com.chau7.ptylog.\(UUID().uuidString)")
    private var handle: FileHandle?
    private var inputBuffer = Data()

    init(toolName: String, logPath: String) {
        self.toolName = toolName
        self.logPath = (logPath as NSString).expandingTildeInPath
        openHandle()
    }

    func recordOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.handle == nil {
                self.openHandle()
            }
            self.handle?.write(data)
        }
    }

    func recordInput(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.inputBuffer.append(data)
            if data.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
                self.flushInputLocked()
            }
        }
    }

    func close() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.flushInputLocked()
            try? self.handle?.close()
            self.handle = nil
        }
    }

    private func openHandle() {
        let url = URL(fileURLWithPath: logPath)
        FileOperations.createDirectory(at: url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func flushInputLocked() {
        guard !inputBuffer.isEmpty else { return }
        let text = String(decoding: inputBuffer, as: UTF8.self)
        inputBuffer.removeAll(keepingCapacity: true)
        let sanitized = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !sanitized.isEmpty else { return }
        if handle == nil {
            openHandle()
        }
        let line = "[INPUT] \(sanitized)\n"
        if let payload = line.data(using: .utf8) {
            handle?.write(payload)
        }
    }
}

enum AIEventLogWriter {
    private static let queue = DispatchQueue(label: "com.chau7.ai-event-log")

    static func appendEvent(type: String, tool: String, message: String, source: AIEventSource, logPath: String) {
        let trimmed = logPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
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
            FileOperations.createDirectory(at: url.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                Log.warn("Failed to open AI events log at \(expanded)")
                return
            }
            _ = try? handle.seekToEnd()
            handle.write(data)
            handle.write(Data([0x0A]))
            try? handle.close()
        }
    }
}
