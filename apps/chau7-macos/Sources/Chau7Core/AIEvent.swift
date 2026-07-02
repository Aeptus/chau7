import Foundation

// MARK: - Localization Hook

/// Localization hook for strings generated inside Chau7Core. The Core module
/// cannot depend on the Chau7 app target (where the full `L()` helper and
/// custom-bundle logic live), so it exposes an injectable closure that Chau7
/// wires at startup. The default is identity — when Core is used in isolation
/// (tests, CLIs), it falls back to the English defaults baked into the call.
public enum Chau7CoreLocalization {
    /// Closure: `(key, englishDefault) -> String`.
    /// Chau7 overrides this in its app init to forward to its `L()` helper.
    public static var localize: @Sendable (_ key: String, _ defaultValue: String) -> String = { _, defaultValue in
        defaultValue
    }
}

/// Short helper used inside Core to call the injected localizer.
func LCore(_ key: String, _ defaultValue: String) -> String {
    Chau7CoreLocalization.localize(key, defaultValue)
}

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

    // Sources with active event producers (hooks, OSC 9 parser, or runtime)
    public static let claudeCode = AIEventSource(rawValue: "claude_code")
    public static let codex = AIEventSource(rawValue: "codex")

    // MARK: - Detection-Only Sources (no active event producers)

    // Referenced by AIToolRegistry for tab detection, auto-theming, and UI labels.
    // No code currently creates AIEvents with these sources. They become active
    // when a history monitor, hook, or OSC 9 parser is wired for the tool.
    // The aiEventSource(for:) lookup in AppModel uses these via the registry,
    // so they must remain defined even without active producers.
    public static let gemini = AIEventSource(rawValue: "gemini")
    public static let chatgpt = AIEventSource(rawValue: "chatgpt")
    public static let cursor = AIEventSource(rawValue: "cursor")
    public static let windsurf = AIEventSource(rawValue: "windsurf")
    public static let copilot = AIEventSource(rawValue: "copilot")
    public static let aider = AIEventSource(rawValue: "aider")
    public static let cline = AIEventSource(rawValue: "cline")
    public static let cody = AIEventSource(rawValue: "cody")
    public static let amazonQ = AIEventSource(rawValue: "amazon_q")
    public static let devin = AIEventSource(rawValue: "devin")
    public static let goose = AIEventSource(rawValue: "goose")
    public static let mentat = AIEventSource(rawValue: "mentat")
    public static let amp = AIEventSource(rawValue: "amp")
    public static let continueAI = AIEventSource(rawValue: "continue_ai")

    /// Sources that route through the "generic AI" notification adapter —
    /// tool-level sources that emit `AIEvent` payloads but don't have a
    /// dedicated adapter like ClaudeCode or Codex. When adding a new
    /// tool-level source, include it here so `NotificationProviderAdapter
    /// Registry.adapt(_:)` routes it through the generic path. A source
    /// that's declared-but-omitted from this set will fall through the
    /// registry's `default:` branch to `.unknown`-style handling.
    public static let genericAIAdapterSources: Set<AIEventSource> = [
        .runtime,
        .gemini,
        .chatgpt,
        .cursor,
        .windsurf,
        .copilot,
        .aider,
        .cline,
        .cody,
        .amazonQ,
        .devin,
        .goose,
        .mentat,
        .amp,
        .continueAI
    ]

    public static func forProvider(_ provider: String?) -> AIEventSource? {
        guard let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        guard let tool = AIToolRegistry.allTools.first(where: {
            $0.resumeProviderKey?.lowercased() == trimmed
                || $0.displayName.lowercased() == trimmed
                || $0.commandNames.contains(trimmed)
        }),
            let rawValue = tool.eventSourceRawValue else {
            return nil
        }
        return AIEventSource(rawValue: rawValue)
    }
}

public enum AIEventReliability: String, Codable, Sendable {
    case authoritative
    case fallback
    case heuristic
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
    /// Optional provider-native type before canonical notification mapping.
    public let rawType: String?
    public let tool: String
    /// Optional provider-supplied title for notification-like payloads.
    public let title: String?
    public let message: String
    /// Optional provider-supplied notification subtype (for example Claude
    /// `permission_prompt` / `idle_prompt`).
    public let notificationType: String?
    public let ts: String
    public let directory: String?
    /// Git repository root path derived from `directory`. Enables per-repo
    /// event filtering, notification routing, and MCP event queries.
    public let repoPath: String?
    public let tabID: UUID?
    /// AI session ID (e.g. Claude session ID) for tab disambiguation.
    public let sessionID: String?
    /// Which subsystem emitted the event (for audit/debugging).
    public let producer: String?
    /// Confidence class used for routing and fallback suppression.
    public let reliability: AIEventReliability

    /// Single initializer covering both "mint a fresh event" and "reconstruct
    /// with a preserved identity" call sites. Pass `id: nil` (or omit the
    /// argument) to auto-generate; pass an explicit `UUID` to preserve
    /// identity across copies or deserialization.
    public init(
        id: UUID? = nil,
        source: AIEventSource = .unknown,
        type: String,
        rawType: String? = nil,
        tool: String,
        title: String? = nil,
        message: String,
        notificationType: String? = nil,
        ts: String,
        directory: String? = nil,
        repoPath: String? = nil,
        tabID: UUID? = nil,
        sessionID: String? = nil,
        producer: String? = nil,
        reliability: AIEventReliability? = nil
    ) {
        self.id = id ?? UUID()
        self.source = source
        self.type = type
        self.rawType = rawType
        self.tool = tool
        self.title = title
        self.message = message
        self.notificationType = notificationType
        self.ts = ts
        self.directory = directory
        self.repoPath = repoPath
        self.tabID = tabID
        self.sessionID = sessionID
        self.producer = producer
        self.reliability = reliability ?? Self.defaultReliability(for: source)
    }

    /// Returns a copy with `tabID` filled in, if it was previously nil.
    /// Use `replacingTabID(_:)` when you need to overwrite an existing
    /// tabID (the "explicit-tab rebound via session" path in
    /// `NotificationEventPreparation`).
    public func resolvingTabID(_ tabID: UUID?) -> AIEvent {
        guard let tabID, self.tabID == nil else { return self }
        return replacingTabID(tabID)
    }

    /// Returns a copy with `tabID` unconditionally replaced. Distinct
    /// from `resolvingTabID(_:)` which preserves an existing tabID; this
    /// is the helper to use when correcting a wrong explicit tab routing.
    /// Preserves every other field — notably `repoPath`, which a
    /// hand-rolled re-construction is easy to forget.
    public func replacingTabID(_ newTabID: UUID) -> AIEvent {
        AIEvent(
            id: id,
            source: source,
            type: type,
            rawType: rawType,
            tool: tool,
            title: title,
            message: message,
            notificationType: notificationType,
            ts: ts,
            directory: directory,
            repoPath: repoPath,
            tabID: newTabID,
            sessionID: sessionID,
            producer: producer,
            reliability: reliability
        )
    }

    /// Returns the routing target for tab resolution from this event's fields.
    public var tabTarget: TabTarget {
        TabTarget(tool: tool, directory: directory, tabID: tabID, sessionID: sessionID)
    }

    public var normalizedType: String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func defaultReliability(for source: AIEventSource) -> AIEventReliability {
        switch source {
        case .runtime, .claudeCode, .terminalSession, .shell, .app:
            return .authoritative
        case .historyMonitor:
            return .fallback
        default:
            return .heuristic
        }
    }

    /// Returns the notification title for this event.
    public var notificationTitle: String {
        notificationTitle(toolOverride: nil)
    }

    /// Returns the notification title for this event with optional tool and
    /// repo overrides. Delegates to `NotificationContentFormatter`, the single
    /// source of notification text across all surfaces.
    public func notificationTitle(toolOverride: String?, repoName: String? = nil) -> String {
        NotificationContentFormatter.title(for: self, toolOverride: toolOverride, repoName: repoName)
    }

    /// Returns a short routing context suitable for a native notification
    /// subtitle. The title already carries the tool and state, so this keeps
    /// project/tab identity visually separate and avoids duplicating obvious
    /// values like `Tab: Claude` on a `Claude: Finished` notification.
    public func notificationSubtitle(tabTitle: String? = nil, repoName: String? = nil) -> String {
        NotificationContentFormatter.subtitle(for: self, tabTitle: tabTitle, repoName: repoName)
    }

    /// Returns the notification body for this event.
    /// For known event types, an explicit `message` supplied by the producer
    /// takes precedence over the localized default. For unknown types, the
    /// fallback is `"<type>: <message>"` or just `<type>` when message is empty.
    public var notificationBody: String {
        NotificationContentFormatter.body(for: self)
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
        let rawType = dict["rawType"] as? String
            ?? dict["raw_type"] as? String
        let tool = try getString("tool", default: "CLI")
        let title = dict["title"] as? String
        let message = try getString("message", default: "")
        let notificationType = dict["notificationType"] as? String
            ?? dict["notification_type"] as? String
        let ts = try getString("ts", default: DateFormatters.nowISO8601())

        let directory = dict["directory"] as? String ?? dict["cwd"] as? String
        let repoPath = dict["repoPath"] as? String ?? dict["repo_path"] as? String
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

        let producer = dict["producer"] as? String
        let reliability: AIEventReliability?
        if let rawReliability = dict["reliability"] as? String {
            reliability = AIEventReliability(rawValue: rawReliability)
        } else {
            reliability = nil
        }
        let preservesOpaqueSessionIdentity =
            source == .codex && producer == "codex_notify_hook" && reliability == .authoritative

        return AIEvent(
            source: source,
            type: type,
            rawType: rawType,
            tool: tool,
            title: title,
            message: message,
            notificationType: notificationType,
            ts: ts,
            directory: directory,
            repoPath: repoPath,
            tabID: tabID,
            sessionID: preservesOpaqueSessionIdentity
                ? sanitizeOpaqueSessionIdentifier(rawSessionID)
                : sessionID,
            producer: producer,
            reliability: reliability
        )
    }

    private static func sanitizeOpaqueSessionIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256 else { return nil }
        return trimmed
    }
}
