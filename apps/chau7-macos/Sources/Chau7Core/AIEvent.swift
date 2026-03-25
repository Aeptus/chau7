import Foundation

// MARK: - Tool-Agnostic Event System

//
// Chau7 strives to be fully backend-agnostic: every AI coding tool — Claude,
// Codex, Gemini, Copilot, Aider, etc. — flows through the same event pipeline.
//
// AIEvent is the canonical event type for ALL monitored tools and sources.
// It is produced by every monitor (file tailer, terminal sessions, Claude Code hooks,
// Codex session files, API proxy, etc.) and consumed by:
//   - `AppModel.recentEvents` — the unified event stream for UI
//   - `NotificationPipeline` / `NotificationManager` — the notification decision engine
//   - `TabResolver` — tool-agnostic tab routing (derives aliases from AIToolRegistry)
//   - `NotificationHistory` — audit trail of fired notifications
//   - Command center timeline — the unified activity feed in the menu bar panel
//
// If you are building UI or logic that processes events, use AIEvent.
// Do NOT use `ClaudeCodeEvent` (in Monitoring/ClaudeCodeEvent.swift) unless you
// specifically need Claude Code hook-level detail — it excludes all other tools.
// Never hardcode tool names in event consumers; use AIToolRegistry for lookups.

/// Identifies which tool or subsystem produced an event.
/// Extensible via RawRepresentable — new sources can be added without enum changes.
public struct AIEventSource: RawRepresentable, Equatable, Hashable, Codable, Sendable {
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

    // MARK: - Runtime

    public static let runtime = AIEventSource(rawValue: "runtime")

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

/// A tool-agnostic event from any monitored source.
///
/// This is the **primary event type** for the entire app. All monitors produce AIEvents,
/// and all cross-tool UI (notifications, timeline, badge counts) should consume AIEvents.
///
/// Fields:
/// - `source`: Which tool/app produced this event (`.claudeCode`, `.cursor`, `.apiProxy`, etc.)
/// - `type`: Event category as a string (`"finished"`, `"permission"`, `"tool_called"`, etc.)
/// - `tool`: Tool or app name for display (varies by source — Claude Code uses internal names
///   like `"Write"`, `"Bash"`; other sources may use different conventions)
/// - `message`: Human-readable detail from the source
/// - `ts`: ISO8601 timestamp string
/// - `directory`: Optional working directory for tab disambiguation
/// - `tabID`: Optional tab UUID for deterministic routing (set by in-app event sources)
public struct AIEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: AIEventSource
    public let type: String
    public let tool: String
    public let message: String
    public let ts: String
    public let directory: String?
    public let tabID: UUID?
    /// AI session ID (e.g. Claude session ID) for tab disambiguation.
    public let sessionID: String?

    public init(source: AIEventSource = .unknown, type: String, tool: String, message: String, ts: String, directory: String? = nil, tabID: UUID? = nil, sessionID: String? = nil) {
        self.id = UUID()
        self.source = source
        self.type = type
        self.tool = tool
        self.message = message
        self.ts = ts
        self.directory = directory
        self.tabID = tabID
        self.sessionID = sessionID
    }

    public init(id: UUID, source: AIEventSource = .unknown, type: String, tool: String, message: String, ts: String, directory: String? = nil, tabID: UUID? = nil, sessionID: String? = nil) {
        self.id = id
        self.source = source
        self.type = type
        self.tool = tool
        self.message = message
        self.ts = ts
        self.directory = directory
        self.tabID = tabID
        self.sessionID = sessionID
    }

    /// Returns a copy with `tabID` filled in, if it was previously nil.
    public func resolvingTabID(_ tabID: UUID?) -> AIEvent {
        guard let tabID, self.tabID == nil else { return self }
        return AIEvent(
            id: id,
            source: source,
            type: type,
            tool: tool,
            message: message,
            ts: ts,
            directory: directory,
            tabID: tabID,
            sessionID: sessionID
        )
    }

    /// Returns the routing target for tab resolution from this event's fields.
    public var tabTarget: TabTarget {
        TabTarget(tool: tool, directory: directory, tabID: tabID, sessionID: sessionID)
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
        case "permission":
            return "\(name): Permission required"
        case "error":
            return "\(name): Error occurred"
        case "context_limit":
            return "\(name): Context limit"
        case "tool_called":
            return "\(name): Tool called"
        case "file_edited":
            return "\(name): File edited"
        case "token_threshold":
            return "\(name): Token threshold"
        case "cost_threshold":
            return "\(name): Cost threshold"
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
        case "permission":
            return message.isEmpty ? "Needs your permission to continue." : message
        case "error":
            return message.isEmpty ? "An error occurred." : message
        case "context_limit":
            return message.isEmpty ? "Approaching context window limit." : message
        case "token_threshold", "cost_threshold":
            return message.isEmpty ? "Usage threshold exceeded." : message
        default:
            return message.isEmpty ? type : "\(type): \(message)"
        }
    }
}

public enum AIEventParseError: Error, Sendable {
    case notJSONObject
    case missingField(String)
    case invalidFieldType(String)
}

extension AIEventParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notJSONObject:
            return "AI event data is not a JSON object"
        case .missingField(let field):
            return "AI event missing required field: \(field)"
        case .invalidFieldType(let field):
            return "AI event field has invalid type: \(field)"
        }
    }
}

public enum AIEventParser {
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

        let directory = dict["directory"] as? String ?? dict["cwd"] as? String
        let rawTabID = dict["tabID"] as? String
            ?? dict["tabId"] as? String
            ?? dict["tab_id"] as? String
        let tabID = rawTabID.flatMap(UUID.init(uuidString:))
        let rawSessionID = dict["sessionID"] as? String
            ?? dict["sessionId"] as? String
            ?? dict["session_id"] as? String
        let sessionID: String?
        if let rawSessionID {
            let trimmedSessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionID = AIResumeParser.isValidSessionId(trimmedSessionID) ? trimmedSessionID : nil
        } else {
            sessionID = nil
        }

        return AIEvent(
            source: source,
            type: type,
            tool: tool,
            message: message,
            ts: ts,
            directory: directory,
            tabID: tabID,
            sessionID: sessionID
        )
    }
}
