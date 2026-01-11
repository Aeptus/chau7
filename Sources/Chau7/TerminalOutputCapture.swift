import Foundation

final class TerminalOutputCapture {
    static let shared = TerminalOutputCapture()

    private let isEnabled: Bool
    private let logPath: String
    private let queue = DispatchQueue(label: "com.chau7.ptycapture")
    private var handle: FileHandle?
    private let formatter = ISO8601DateFormatter()

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
        }
    }

    private func openHandle() {
        let url = URL(fileURLWithPath: logPath)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
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
