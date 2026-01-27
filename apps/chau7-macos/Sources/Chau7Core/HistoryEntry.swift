import Foundation

public struct HistoryEntry: Equatable {
    public let sessionId: String
    public let timestamp: TimeInterval
    public let summary: String
    public let isExit: Bool

    public init(sessionId: String, timestamp: TimeInterval, summary: String, isExit: Bool) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.summary = summary
        self.isExit = isExit
    }
}

public enum HistoryEntryParseError: Error {
    case notJSONObject
    case missingField(String)
    case invalidFieldType(String)
}

public final class HistoryEntryParser {
    public static func parse(line: String) throws -> HistoryEntry {
        guard let data = line.data(using: .utf8) else {
            throw HistoryEntryParseError.notJSONObject
        }

        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw HistoryEntryParseError.notJSONObject
        }

        func getString(_ key: String) -> String? {
            guard let value = dict[key] else { return nil }
            if let stringValue = value as? String {
                return stringValue
            }
            return String(describing: value)
        }

        func getNumber(_ key: String) -> Double? {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? Int { return Double(value) }
            if let value = dict[key] as? Int64 { return Double(value) }
            if let value = dict[key] as? NSNumber { return value.doubleValue }
            return nil
        }

        guard let sessionId = getString("session_id") ?? getString("sessionId") else {
            throw HistoryEntryParseError.missingField("session_id")
        }

        guard let rawTimestamp = getNumber("ts") ?? getNumber("timestamp") else {
            throw HistoryEntryParseError.missingField("ts")
        }

        let rawText = getString("text") ?? ""
        let rawDisplay = getString("display") ?? ""
        let summary = rawText.isEmpty ? rawDisplay : rawText
        let timestamp = normalizeTimestamp(rawTimestamp)
        let isExit = isExitMarker(rawText: rawText, rawDisplay: rawDisplay)

        return HistoryEntry(sessionId: sessionId, timestamp: timestamp, summary: summary, isExit: isExit)
    }

    private static func normalizeTimestamp(_ value: Double) -> TimeInterval {
        if value > 1_000_000_000_000 {
            return value / 1000.0
        }
        return value
    }

    private static func isExitMarker(rawText: String, rawDisplay: String) -> Bool {
        let candidate = rawDisplay.isEmpty ? rawText : rawDisplay
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "exit", "/exit", "quit", "/quit":
            return true
        default:
            return false
        }
    }
}
