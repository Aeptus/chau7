import Foundation
import SwiftUI
import Chau7Core

// MARK: - Unified Timeline Entry

struct UnifiedTimelineEntry: Identifiable {
    let id: UUID
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    let timestamp: Date
    let isRateLimited: Bool
}

private struct TimelineEventIdentity {
    let id: UUID?
    let source: String
    let type: String
    let tool: String?
    let message: String?
    let tabID: String?
    let sessionID: String?
    let timestamp: Date

    func matches(_ other: TimelineEventIdentity, timestampTolerance: TimeInterval) -> Bool {
        if let id, let otherID = other.id {
            return id == otherID
        }

        guard abs(timestamp.timeIntervalSince(other.timestamp)) <= timestampTolerance else {
            return false
        }

        return source == other.source
            && type == other.type
            && tool == other.tool
            && message == other.message
            && tabID == other.tabID
            && sessionID == other.sessionID
    }

    static func history(_ entry: NotificationHistory.Entry) -> TimelineEventIdentity {
        TimelineEventIdentity(
            id: entry.id,
            source: normalizedSource(entry.source),
            type: NotificationSemanticMapping.normalize(entry.type),
            tool: normalizedLookup(entry.tool),
            message: normalizedMessage(entry.message),
            tabID: normalizedLookup(entry.resolvedTabID),
            sessionID: nil,
            timestamp: entry.timestamp
        )
    }

    static func raw(_ event: AIEvent, timestamp: Date) -> TimelineEventIdentity {
        TimelineEventIdentity(
            id: event.id,
            source: normalizedSource(event.source.rawValue),
            type: NotificationSemanticMapping.normalize(event.type),
            tool: normalizedLookup(event.tool),
            message: normalizedMessage(event.message),
            tabID: normalizedLookup(event.tabID?.uuidString),
            sessionID: normalizedLookup(event.sessionID),
            timestamp: timestamp
        )
    }

    private static func normalizedSource(_ value: String) -> String {
        NotificationSemanticMapping.normalize(value)
    }

    private static func normalizedLookup(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func normalizedMessage(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Command Center Timeline

extension CommandCenterViewModel {
    private static let timelineDedupTolerance: TimeInterval = 2

    func unifiedTimeline() -> [UnifiedTimelineEntry] {
        unifiedTimeline(historyEntries: environment.notificationHistorySource())
    }

    /// Merged feed of notification history + recent tool-agnostic events, deduplicated, max 8.
    ///
    /// Uses `model.recentEvents` (`[AIEvent]`) — the **tool-agnostic** event stream that
    /// includes events from all monitored tools (Claude Code, Cursor, Codex, Copilot, etc.).
    /// NOT `model.claudeCodeEvents` which is Claude Code hook-specific.
    ///
    /// Accepts history entries as parameter since NotificationHistory is @MainActor-isolated
    /// and this view model is not. Callers in SwiftUI views can pass the snapshot directly.
    func unifiedTimeline(historyEntries: [NotificationHistory.Entry]) -> [UnifiedTimelineEntry] {
        // Use recentEvents (AIEvent) — tool-agnostic stream from all monitors
        let rawEvents = Array(model.recentEvents.suffix(8))
        let historyIdentities = historyEntries.map { TimelineEventIdentity.history($0) }

        // Convert notification history entries (these win in dedup)
        var entries: [UnifiedTimelineEntry] = historyEntries.map { entry in
            let event = Self.timelineEvent(from: entry)

            return UnifiedTimelineEntry(
                id: entry.id,
                icon: entry.wasRateLimited ? "bell.slash" : "bell.fill",
                iconColor: entry.wasRateLimited ? .gray : .orange,
                title: Self.timelineTitle(for: event),
                detail: Self.timelineDetail(for: event),
                timestamp: entry.timestamp,
                isRateLimited: entry.wasRateLimited
            )
        }

        // Add raw events that don't match a notification history entry
        for event in rawEvents {
            let ts = DateFormatters.parseISO8601(event.ts) ?? Date()
            let eventIdentity = TimelineEventIdentity.raw(event, timestamp: ts)
            let isDuplicate = historyIdentities.contains {
                $0.matches(eventIdentity, timestampTolerance: Self.timelineDedupTolerance)
            }
            if !isDuplicate {
                entries.append(UnifiedTimelineEntry(
                    id: event.id,
                    icon: Self.eventIcon(for: event),
                    iconColor: Self.eventColor(for: event),
                    title: Self.timelineTitle(for: event),
                    detail: Self.timelineDetail(for: event),
                    timestamp: ts,
                    isRateLimited: false
                ))
            }
        }

        return Array(entries
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(8))
    }

    // MARK: - Canonical Timeline Presentation (AIEvent — tool-agnostic)

    //
    // These helpers render AIEvent fields through the same vocabulary used by
    // notifications and settings. The status bar keeps only presentation-specific
    // icon/color choices here; source labels, title text, and fallback bodies come
    // from Chau7Core's canonical notification surfaces.
    // AIEvent is the tool-agnostic event model (from Chau7Core) used by ALL monitors —
    // Claude Code, Cursor, Codex, Copilot, Aider, shell sessions, API proxy, etc.
    //
    // Key AIEvent fields:
    //   source: AIEventSource  — which tool/app produced the event (.claudeCode, .cursor, etc.)
    //   type: String           — event category ("finished", "permission", "tool_called", etc.)
    //   tool: String           — tool/app name for display (e.g. "Claude Code", "Write", "Bash")
    //   message: String        — human-readable detail from the source
    //   ts: String             — ISO8601 timestamp
    //
    // ⚠️  Do NOT use ClaudeCodeEvent here. ClaudeCodeEvent is a Claude Code hook-specific
    //     type (see Monitoring/ClaudeCodeEvent.swift) that only captures events from Claude
    //     Code's hook scripts. Using it would silently exclude events from all other tools.

    private static func timelineEvent(from entry: NotificationHistory.Entry) -> AIEvent {
        AIEvent(
            id: entry.id,
            source: AIEventSource(rawValue: entry.source),
            type: entry.type,
            rawType: entry.rawType,
            tool: entry.tool,
            message: entry.message,
            notificationType: entry.notificationType,
            ts: DateFormatters.iso8601.string(from: entry.timestamp),
            tabID: entry.resolvedTabID.flatMap(UUID.init(uuidString:)),
            producer: entry.producer,
            reliability: AIEventReliability(rawValue: entry.reliability)
        )
    }

    private static func eventSemanticKind(for event: AIEvent) -> NotificationSemanticKind {
        NotificationSemanticMapping.kind(
            rawType: event.rawType ?? event.type,
            notificationType: event.notificationType
        )
    }

    /// Icon for an AIEvent, chosen by canonical semantic kind first, then by
    /// source family for non-semantic events.
    private static func eventIcon(for event: AIEvent) -> String {
        switch eventSemanticKind(for: event) {
        case .taskFinished: return "text.bubble"
        case .taskFailed: return "exclamationmark.circle"
        case .toolFailed: return "wrench.and.screwdriver"
        case .permissionRequired: return "exclamationmark.triangle"
        case .waitingForInput: return "keyboard"
        case .attentionRequired: return "bell"
        case .authenticationSucceeded: return "checkmark.shield"
        case .idle: return "moon"
        case .informational, .unknown: break
        }

        if TriggerVocabulary.entry(forType: event.type) != nil {
            return "bell"
        }

        switch event.source {
        case .terminalSession: return "terminal.fill"
        case .shell: return "terminal"
        case .historyMonitor, .eventsLog: return "clock.arrow.circlepath"
        case .app: return "app.badge"
        case .apiProxy: return "arrow.up.arrow.down"
        default: return "circle"
        }
    }

    /// Color for an AIEvent based on canonical semantic kind.
    private static func eventColor(for event: AIEvent) -> Color {
        switch eventSemanticKind(for: event) {
        case .taskFinished: return .blue
        case .taskFailed: return .red
        case .toolFailed: return .orange
        case .permissionRequired: return .yellow
        case .waitingForInput, .attentionRequired: return .orange
        case .authenticationSucceeded: return .green
        case .idle: return .gray
        case .informational, .unknown: break
        }

        return .secondary
    }

    private static func timelineTitle(for event: AIEvent) -> String {
        let sourceName = sourceDisplayName(for: event)

        if TriggerVocabulary.entry(forType: event.type) == nil,
           let trigger = NotificationTriggerCatalog.trigger(for: event),
           !trigger.isWildcard {
            return "\(sourceName): \(trigger.localizedLabel)"
        }

        return NotificationContentFormatter.title(for: event, toolOverride: sourceName)
    }

    private static func timelineDetail(for event: AIEvent) -> String {
        if let message = cleanTimelinePart(event.message) {
            return compactDetail(message)
        }

        if let subtitle = cleanTimelinePart(NotificationContentFormatter.subtitle(for: event)) {
            return subtitle
        }

        let body = NotificationContentFormatter.body(for: event)
        if let cleanBody = cleanTimelinePart(body),
           NotificationSemanticMapping.normalize(cleanBody) != NotificationSemanticMapping.normalize(event.type) {
            return compactDetail(cleanBody)
        }

        return sourceDisplayName(for: event)
    }

    private static func sourceDisplayName(for event: AIEvent) -> String {
        if let registeredSourceName = registeredDisplayName(forSource: event.source) {
            return registeredSourceName
        }

        if let registeredTool = AIToolRegistry.tool(matching: event.tool) {
            return registeredTool.notificationDisplayName
        }

        if event.source == .unknown,
           let tool = cleanTimelinePart(event.tool) {
            return tool
        }

        if let sourceInfo = NotificationTriggerCatalog.sources.first(where: { $0.id == event.source }) {
            return sourceInfo.localizedLabel
        }

        if let tool = cleanTimelinePart(event.tool) {
            return tool
        }

        return humanizedRawValue(event.source.rawValue)
    }

    private static func registeredDisplayName(forSource source: AIEventSource) -> String? {
        AIToolRegistry.allTools.first { $0.eventSource == source }?.notificationDisplayName
    }

    private static func humanizedRawValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: "_")
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func cleanTimelinePart(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func compactDetail(_ value: String) -> String {
        if let file = extractFileName(from: value) {
            return file
        }
        if value.count > 60 {
            return String(value.prefix(57)) + "..."
        }
        return value
    }

    /// Extract a filename from a message string (e.g. "/path/to/config.json" → "config.json").
    private static func extractFileName(from message: String) -> String? {
        if message.contains("/") {
            let components = message.components(separatedBy: "/")
            if let last = components.last, !last.isEmpty, last.contains(".") {
                return last
            }
        }
        return nil
    }
}
