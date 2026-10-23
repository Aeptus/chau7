import Foundation

public enum HistoryEntryActivityKind: String, Equatable, Sendable {
    case prompt
    case response
    case unknown

    public var supportsFinishedEvent: Bool {
        self == .response
    }
}

public struct HistoryEntry: Equatable, Sendable {
    public let sessionId: String
    public let timestamp: TimeInterval
    public let summary: String
    public let isExit: Bool
    public let activityKind: HistoryEntryActivityKind

    public init(
        sessionId: String,
        timestamp: TimeInterval,
        summary: String,
        isExit: Bool,
        activityKind: HistoryEntryActivityKind = .prompt
    ) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.summary = summary
        self.isExit = isExit
        self.activityKind = activityKind
    }
}

public enum HistoryEntryParseError: Error, Sendable {
    case notJSONObject
    case missingField(String)
    case invalidFieldType(String)
}

extension HistoryEntryParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notJSONObject:
            return "History entry data is not a JSON object"
        case .missingField(let field):
            return "History entry missing required field: \(field)"
        case .invalidFieldType(let field):
            return "History entry field has invalid type: \(field)"
        }
    }
}

public enum HistoryEntryParser {
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
        let activityKind = inferActivityKind(dict: dict)

        return HistoryEntry(
            sessionId: sessionId,
            timestamp: timestamp,
            summary: summary,
            isExit: isExit,
            activityKind: activityKind
        )
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

    private static func inferActivityKind(dict: [String: Any]) -> HistoryEntryActivityKind {
        func normalizeRole(_ role: String?) -> String? {
            role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        let topLevelRole = normalizeRole(dict["role"] as? String)
        let messageRole = normalizeRole((dict["message"] as? [String: Any])?["role"] as? String)
        let role = topLevelRole ?? messageRole

        switch role {
        case "assistant":
            return .response
        case "user":
            return .prompt
        default:
            break
        }

        // Current Codex and Claude history files only record user prompts.
        // Untyped text/display entries should therefore default to prompt
        // rather than synthesizing false "finished" events on idle.
        if dict["text"] != nil || dict["display"] != nil {
            return .prompt
        }

        return .unknown
    }
}
