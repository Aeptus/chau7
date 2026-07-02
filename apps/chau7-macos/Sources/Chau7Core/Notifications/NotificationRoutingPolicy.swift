import Foundation

/// The delivery surfaces a notification can target.
public enum NotificationSurface: String, CaseIterable, Codable, Sendable {
    case macLocal
    case tabStyle
    case iosPush
    case liveActivity
    case mcpSubscribers
}

/// User-configurable surface routing knobs.
public struct NotificationSurfaceSettings: Equatable, Sendable {
    /// Route accepted task-finished/failed notifications to iOS as pushes.
    public var pushTaskCompletions: Bool

    public init(pushTaskCompletions: Bool = false) {
        self.pushTaskCompletions = pushTaskCompletions
    }
}

/// Declarative per-kind surface routing — the single answer to "which
/// surfaces does this event class target". Previously this policy was
/// implicit and inconsistent: `.app`-source events reached local
/// notifications but were silently excluded from MCP observability by a
/// buried guard, and pushes covered only approvals/prompts with no way to
/// opt completions in.
///
/// Downstream gates still apply per surface (trigger catalog + conditions
/// for macLocal/tabStyle, the agent's deliverability gate for iosPush,
/// acceptance for mcpSubscribers) — this table decides *eligibility*.
public enum NotificationRoutingPolicy {

    public static func surfaces(
        kind: NotificationSemanticKind,
        settings: NotificationSurfaceSettings = NotificationSurfaceSettings()
    ) -> Set<NotificationSurface> {
        switch kind {
        case .permissionRequired, .waitingForInput, .attentionRequired:
            return [.macLocal, .tabStyle, .iosPush, .liveActivity, .mcpSubscribers]

        case .taskFinished, .taskFailed:
            var surfaces: Set<NotificationSurface> = [.macLocal, .tabStyle, .liveActivity, .mcpSubscribers]
            if settings.pushTaskCompletions {
                surfaces.insert(.iosPush)
            }
            return surfaces

        case .idle, .authenticationSucceeded:
            return [.macLocal, .tabStyle, .mcpSubscribers]

        case .informational:
            // Includes `.app`-source events: they are MCP-visible by policy
            // now (the old implicit behavior dropped them from observability
            // while still allowing local delivery — an undeclared asymmetry).
            return [.macLocal, .mcpSubscribers]

        case .unknown:
            // Adapters drop unknown kinds before routing; defensive empty.
            return []
        }
    }
}
