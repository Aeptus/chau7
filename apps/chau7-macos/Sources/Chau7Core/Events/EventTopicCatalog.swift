import Foundation

/// Typed constants for the MCP observer topics.
///
/// Values must stay in sync with `Chau7MCPObserverContract.supportedTopics`
/// (asserted by `EventTopicCatalogTests`).
public enum EventTopic {
    public static let approvalState = "approval-state"
    public static let repoEvents = "repo-events"
    public static let runtimeEvents = "runtime-events"
    public static let sessionState = "session-state"
    public static let tabState = "tab-state"
    public static let telemetryRuns = "telemetry-runs"
    public static let timerInventory = "timer-inventory"
}

/// The identity/context facts topic assignment can depend on, independent of
/// which payload shape carried the event.
public struct EventTopicContext: Equatable, Sendable {
    public let type: String
    public let subsystem: String
    public let hasTab: Bool
    public let hasSession: Bool
    public let hasRun: Bool
    public let hasRepo: Bool

    public init(
        type: String,
        subsystem: String,
        hasTab: Bool = false,
        hasSession: Bool = false,
        hasRun: Bool = false,
        hasRepo: Bool = false
    ) {
        self.type = type
        self.subsystem = subsystem
        self.hasTab = hasTab
        self.hasSession = hasSession
        self.hasRun = hasRun
        self.hasRepo = hasRepo
    }
}

/// Deterministic, declared topic assignment for spine events.
///
/// This replaces the string-prefix heuristics that previously lived in the
/// observability service. Every known event type has an explicit entry in
/// `declaredTopics`; unknown types fall back to a single documented rule
/// (context-derived topics only). Context facts (tab/session/run/repo
/// present) contribute additively for both known and unknown types, matching
/// the semantics MCP subscribers already rely on.
public enum EventTopicCatalog {

    /// Explicit type→topics table. Types not listed here are *unknown* and
    /// receive only the base + context-derived topics.
    ///
    /// Keep this exhaustive: `EventTopicCatalogTests` asserts every runtime,
    /// structural, and AI event type in the codebase has an entry.
    static let declaredTopics: [String: Set<String>] = {
        var table: [String: Set<String>] = [:]

        // AI events (recorded via the unified pipeline).
        table["ai_event"] = [EventTopic.repoEvents]

        // Tab lifecycle (subsystem "tabs" / native tab events).
        for type in ["tab_created", "tab_closed", "tab_opened", "tab_switched"] {
            table[type] = [EventTopic.tabState]
        }

        // MCP approvals.
        for type in ["approval_waiting", "approval_resolved", "approval_needed"] {
            table[type] = [EventTopic.approvalState]
        }

        // Telemetry run lifecycle.
        for type in ["telemetry_run_started", "telemetry_run_updated", "telemetry_run_completed"] {
            table[type] = [EventTopic.telemetryRuns]
        }

        // App/window lifecycle — base topic only.
        for type in [
            "app_launched",
            "build_activated",
            "window_focused",
            "window_unfocused",
            "file_conflict",
            "finished",
            "waiting_input"
        ] {
            table[type] = []
        }

        // Runtime session events (RuntimeEventType constants) — base topic
        // only; session/tab context adds the rest.
        for type in [
            "session_starting",
            "session_ready",
            "session_stopped",
            "session_error",
            "state_changed",
            "turn_started",
            "turn_completed",
            "turn_failed",
            "turn_reconciled",
            "turn_result",
            "user_input",
            "agent_responding",
            "notification",
            "tool_use",
            "tool_result",
            "output_chunk",
            "stall_detected",
            "token_threshold",
            "cost_threshold",
            "exit_classified",
            "policy_blocked"
        ] {
            table[type] = []
        }
        table["approval_needed"] = [EventTopic.approvalState]
        table["approval_resolved"] = [EventTopic.approvalState]

        // Timer inventory changes.
        for type in ["timer_registered", "timer_updated", "timer_scope_updated"] {
            table[type] = [EventTopic.timerInventory]
        }

        return table
    }()

    /// Subsystems whose events always carry an extra topic regardless of type.
    static let subsystemTopics: [String: String] = [
        "tabs": EventTopic.tabState,
        "mcp_approvals": EventTopic.approvalState
    ]

    /// Compute the topics for an event. Deterministic: same context in, same
    /// sorted topic list out.
    public static func topics(for context: EventTopicContext) -> [String] {
        var topics: Set<String> = [EventTopic.runtimeEvents]

        if let declared = declaredTopics[context.type] {
            topics.formUnion(declared)
        }
        if let subsystemTopic = subsystemTopics[context.subsystem] {
            topics.insert(subsystemTopic)
        }

        // Context facts contribute additively (same for known and unknown types).
        if context.hasTab { topics.insert(EventTopic.tabState) }
        if context.hasSession { topics.insert(EventTopic.sessionState) }
        if context.hasRun { topics.insert(EventTopic.telemetryRuns) }
        if context.hasRepo { topics.insert(EventTopic.repoEvents) }

        return topics.sorted()
    }

    /// Topic context for an AI event, matching how the observability service
    /// records AI events (type "ai_event", subsystem = source).
    public static func context(for event: AIEvent) -> EventTopicContext {
        EventTopicContext(
            type: "ai_event",
            subsystem: event.source.rawValue,
            hasTab: event.tabID != nil,
            hasSession: event.sessionID != nil,
            hasRun: false,
            hasRepo: event.repoPath != nil
        )
    }

    /// Topic context for a structural event.
    public static func context(for event: StructuralEvent) -> EventTopicContext {
        EventTopicContext(
            type: event.type,
            subsystem: event.subsystem,
            hasTab: event.tabID != nil,
            hasSession: event.sessionID != nil,
            hasRun: event.runID != nil,
            hasRepo: event.repoPath != nil
        )
    }

    /// Topics for an envelope payload.
    public static func topics(for payload: EventPayload) -> [String] {
        switch payload {
        case let .ai(event):
            return topics(for: context(for: event))
        case let .structural(event):
            return topics(for: context(for: event))
        }
    }
}
