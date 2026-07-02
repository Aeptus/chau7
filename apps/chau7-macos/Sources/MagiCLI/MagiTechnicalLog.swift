import Chau7Core
import Foundation

struct MagiTechnicalLog {
    let path: String
    let runID: String
    var fileManager: FileManager = .default

    func record(
        _ event: String,
        stage: String? = nil,
        level: String = "info",
        memberID: MagiMemberID? = nil,
        tabID: String? = nil,
        message: String? = nil,
        fields: [String: String] = [:]
    ) {
        var payload = fields
        payload["event"] = event
        payload["level"] = level
        payload["run_id"] = runID
        payload["timestamp"] = Self.isoDate(Date())
        if let stage { payload["stage"] = stage }
        if let memberID { payload["member_id"] = memberID.rawValue }
        if let tabID { payload["tab_id"] = tabID }
        if let message { payload["message"] = message }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0A)

        let url = URL(fileURLWithPath: path)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: path) {
                _ = fileManager.createFile(atPath: path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            return
        }
    }

    private static func isoDate(_ date: Date) -> String {
        return DateFormatters.iso8601.string(from: date)
    }
}
