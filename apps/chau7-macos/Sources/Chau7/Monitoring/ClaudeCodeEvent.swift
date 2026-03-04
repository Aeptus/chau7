import Foundation

// MARK: - Claude Code Hook Events
//
// ⚠️  SCOPE: These types are specific to Claude Code's hook system.
// They only capture events from Claude Code hook scripts (PreToolUse, PostToolUse, etc.).
// Events from other monitored tools (Cursor, Codex, Copilot, Aider, etc.) do NOT
// flow through these types.
//
// For tool-agnostic event handling, use `AIEvent` (in Chau7Core/AIEvent.swift) which
// is fed by ALL monitors via `AppModel.recentEvents`. The notification system, command
// center timeline, and any new UI should consume `AIEvent`, not `ClaudeCodeEvent`.
//
// `ClaudeCodeEvent` is consumed by:
// - `AppModel.claudeCodeEvents` — Claude Code-specific raw event log
// - `ClaudeCodeMonitor` — the monitor that produces these events
//
// It is NOT consumed by (and should not be added to):
// - Command center timeline (uses `AIEvent` via `model.recentEvents`)
// - Notification pipeline (uses `AIEvent`)
// - Any cross-tool UI

/// Event types from Claude Code hooks.
/// See `AIEvent.type` (String) for the tool-agnostic equivalent used across all sources.
enum ClaudeEventType: String, Codable {
    case userPrompt = "user_prompt"           // User submitted a prompt
    case toolStart = "tool_start"             // Tool about to execute
    case toolComplete = "tool_complete"       // Tool execution completed
    case permissionRequest = "permission_request"  // Claude waiting for permission
    case responseComplete = "response_complete"    // Claude finished responding
    case notification = "notification"        // Custom notification
    case sessionEnd = "session_end"           // Session terminated
    case unknown = "unknown"
}

/// Event received from Claude Code hook script.
///
/// ⚠️  This is a **Claude Code-specific** type. For cross-tool event handling,
/// use `AIEvent` (Chau7Core) instead. See file header comment for details.
struct ClaudeCodeEvent: Identifiable, Equatable {
    let id = UUID()
    let type: ClaudeEventType
    let hook: String
    let sessionId: String
    let transcriptPath: String
    let toolName: String
    let message: String
    let cwd: String
    let timestamp: Date

    /// Project name extracted from cwd
    var projectName: String {
        guard !cwd.isEmpty else { return "Unknown" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "Unknown" : name
    }

    /// Short session ID for display
    var shortSessionId: String {
        String(sessionId.prefix(8))
    }
}

// MARK: - Parser

enum ClaudeCodeEventParser {
    enum ParseError: Error {
        case invalidJSON
        case missingFields
    }

    /// Parse a JSON line from the hook events file
    static func parse(line: String) throws -> ClaudeCodeEvent {
        guard let data = line.data(using: .utf8) else {
            throw ParseError.invalidJSON
        }

        guard let json = JSONOperations.parseJSON(from: data, context: "ClaudeCodeEvent") else {
            throw ParseError.invalidJSON
        }

        // Extract fields with defaults
        let typeStr = json["type"] as? String ?? "unknown"
        let type = ClaudeEventType(rawValue: typeStr) ?? .unknown
        let hook = json["hook"] as? String ?? ""
        let sessionId = json["sessionId"] as? String ?? ""
        let transcriptPath = json["transcriptPath"] as? String ?? ""
        let toolName = json["toolName"] as? String ?? ""
        let message = json["message"] as? String ?? ""
        let cwd = json["cwd"] as? String ?? ""
        let timestampStr = json["timestamp"] as? String ?? ""

        // Parse timestamp
        let timestamp = DateFormatters.iso8601.date(from: timestampStr) ?? Date()

        return ClaudeCodeEvent(
            type: type,
            hook: hook,
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            toolName: toolName,
            message: message,
            cwd: cwd,
            timestamp: timestamp
        )
    }
}

// MARK: - Transcript Message Types

/// Role in a Claude Code conversation
enum ClaudeMessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// Type of content in a message
enum ClaudeContentType: String {
    case text
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case thinking
}

/// A message from a Claude Code transcript
struct ClaudeTranscriptMessage: Identifiable, Equatable {
    let id: String  // uuid from transcript
    let role: ClaudeMessageRole
    let contentType: ClaudeContentType
    let content: String  // Text content or tool name
    let toolName: String?  // For tool_use messages
    let timestamp: Date
    let sessionId: String

    /// Display classification for UI
    var displayCategory: String {
        switch (role, contentType) {
        case (.user, _):
            return "INPUT"
        case (.assistant, .text):
            return "OUTPUT"
        case (.assistant, .toolUse):
            return "TOOL"
        case (.assistant, .thinking):
            return "THINKING"
        case (_, .toolResult):
            return "RESULT"
        default:
            return "OTHER"
        }
    }

    /// Icon for display
    var displayIcon: String {
        switch displayCategory {
        case "INPUT": return "person.fill"
        case "OUTPUT": return "bubble.left.fill"
        case "TOOL": return "wrench.fill"
        case "RESULT": return "doc.text.fill"
        case "THINKING": return "brain"
        default: return "circle.fill"
        }
    }
}

// MARK: - Transcript Parser

enum ClaudeTranscriptParser {
    /// Parse a transcript JSONL file and extract messages
    static func parseTranscript(at path: String) -> [ClaudeTranscriptMessage] {
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            Log.warn("Failed to read transcript at \(path): \(error.localizedDescription)")
            return []
        }

        var messages: [ClaudeTranscriptMessage] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = JSONOperations.parseJSON(from: data, context: "transcript line") else {
                continue
            }

            // Only process user and assistant messages
            guard let type = json["type"] as? String,
                  (type == "user" || type == "assistant") else {
                continue
            }

            guard let uuid = json["uuid"] as? String,
                  let messageDict = json["message"] as? [String: Any],
                  let roleStr = messageDict["role"] as? String,
                  let role = ClaudeMessageRole(rawValue: roleStr),
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            let sessionId = json["sessionId"] as? String ?? ""
            let timestampStr = json["timestamp"] as? String ?? ""
            let timestamp = DateFormatters.iso8601.date(from: timestampStr) ?? Date()

            // Process each content block
            for contentBlock in contentArray {
                guard let blockType = contentBlock["type"] as? String else { continue }

                let contentType: ClaudeContentType
                var content = ""
                var toolName: String? = nil

                switch blockType {
                case "text":
                    contentType = .text
                    content = contentBlock["text"] as? String ?? ""
                    // Skip IDE notifications and empty text
                    if content.hasPrefix("<ide_") || content.isEmpty {
                        continue
                    }
                case "tool_use":
                    contentType = .toolUse
                    toolName = contentBlock["name"] as? String
                    content = toolName ?? "Unknown tool"
                case "tool_result":
                    contentType = .toolResult
                    content = contentBlock["content"] as? String ?? ""
                    // Truncate long tool results
                    if content.count > 200 {
                        content = String(content.prefix(200)) + "..."
                    }
                case "thinking":
                    contentType = .thinking
                    content = contentBlock["thinking"] as? String ?? ""
                default:
                    continue
                }

                let message = ClaudeTranscriptMessage(
                    id: "\(uuid)-\(blockType)",
                    role: role,
                    contentType: contentType,
                    content: content,
                    toolName: toolName,
                    timestamp: timestamp,
                    sessionId: sessionId
                )
                messages.append(message)
            }
        }

        return messages
    }

    /// Get the latest N messages from a transcript
    static func latestMessages(from path: String, count: Int = 20) -> [ClaudeTranscriptMessage] {
        let all = parseTranscript(at: path)
        return Array(all.suffix(count))
    }
}
