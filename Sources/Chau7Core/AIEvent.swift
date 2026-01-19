import Foundation

public struct AIEventSource: RawRepresentable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: - Core Sources
    public static let eventsLog = AIEventSource(rawValue: "events_log")
    public static let terminalSession = AIEventSource(rawValue: "terminal_session")
    public static let historyMonitor = AIEventSource(rawValue: "history_monitor")
    public static let app = AIEventSource(rawValue: "app")
    public static let apiProxy = AIEventSource(rawValue: "api_proxy")
    public static let unknown = AIEventSource(rawValue: "unknown")

    // MARK: - Shell Sources
    public static let shell = AIEventSource(rawValue: "shell")

    // MARK: - AI Coding Apps
    public static let claudeCode = AIEventSource(rawValue: "claude_code")
    public static let codex = AIEventSource(rawValue: "codex")
    public static let cursor = AIEventSource(rawValue: "cursor")
    public static let windsurf = AIEventSource(rawValue: "windsurf")
    public static let copilot = AIEventSource(rawValue: "copilot")
    public static let aider = AIEventSource(rawValue: "aider")
    public static let cline = AIEventSource(rawValue: "cline")
    public static let continueAI = AIEventSource(rawValue: "continue_ai")
}

public struct AIEvent: Identifiable, Equatable {
    public let id: UUID
    public let source: AIEventSource
    public let type: String
    public let tool: String
    public let message: String
    public let ts: String

    public init(source: AIEventSource = .unknown, type: String, tool: String, message: String, ts: String) {
        self.id = UUID()
        self.source = source
        self.type = type
        self.tool = tool
        self.message = message
        self.ts = ts
    }

    public init(id: UUID, source: AIEventSource = .unknown, type: String, tool: String, message: String, ts: String) {
        self.id = id
        self.source = source
        self.type = type
        self.tool = tool
        self.message = message
        self.ts = ts
    }

    /// Returns the notification title for this event.
    public var notificationTitle: String {
        notificationTitle(toolOverride: nil)
    }

    /// Returns the notification title for this event with an optional tool override.
    public func notificationTitle(toolOverride: String?) -> String {
        let toolName = (toolOverride ?? tool).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = toolName.isEmpty ? tool : toolName
        switch type.lowercased() {
        case "needs_validation":
            return "\(name): Validation needed"
        case "idle":
            return "\(name): Possibly waiting for you"
        case "finished":
            return "\(name): Task finished"
        case "failed":
            return "\(name): Task failed"
        default:
            return "\(name): Update"
        }
    }

    /// Returns the notification body for this event.
    public var notificationBody: String {
        switch type.lowercased() {
        case "needs_validation":
            return message.isEmpty ? "Your input is required." : message
        case "idle":
            return message.isEmpty ? "No new history entries for a while." : message
        case "finished":
            return message.isEmpty ? "Done." : message
        case "failed":
            return message.isEmpty ? "Check the logs." : message
        default:
            return message.isEmpty ? type : "\(type): \(message)"
        }
    }
}

public enum AIEventParseError: Error {
    case notJSONObject
    case missingField(String)
    case invalidFieldType(String)
}

public final class AIEventParser {
    public static func parse(line: String) throws -> AIEvent {
        guard let data = line.data(using: .utf8) else {
            throw AIEventParseError.notJSONObject
        }

        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw AIEventParseError.notJSONObject
        }

        func getString(_ key: String, default defaultValue: String? = nil) throws -> String {
            if let value = dict[key] {
                guard let stringValue = value as? String else {
                    throw AIEventParseError.invalidFieldType(key)
                }
                return stringValue
            }
            if let defaultValue {
                return defaultValue
            }
            throw AIEventParseError.missingField(key)
        }

        let sourceRaw = try getString("source", default: AIEventSource.eventsLog.rawValue)
        let source = AIEventSource(rawValue: sourceRaw)
        let type = try getString("type")
        let tool = try getString("tool", default: "CLI")
        let message = try getString("message", default: "")
        let ts = try getString("ts", default: DateFormatters.nowISO8601())

        return AIEvent(source: source, type: type, tool: tool, message: message, ts: ts)
    }
}
