import Foundation

/// The single declarative table for the shared trigger-type vocabulary.
///
/// The same normalized type strings ("finished", "failed", "permission",
/// "waiting_input", …) used to be switched on independently by
/// `NotificationContentFormatter` (title suffix + body) and
/// `NotificationStylePlanner` (tab style preset), with
/// `NotificationSemanticMapping` deriving the semantic kind from the same
/// strings in yet another switch. This table declares, per type, everything
/// the presentation layer needs; the formatter and style planner are lookups
/// into it.
///
/// `NotificationSemanticMapping` remains authoritative for kind derivation in
/// the adapter layer — the `semanticKind` column here is documentation plus a
/// drift guard: `TriggerVocabularyTests` fails if a row's kind disagrees with
/// `NotificationSemanticMapping.kind(forRawType:)`.
public enum TriggerVocabulary {
    public struct Entry: Equatable, Sendable {
        /// Normalized trigger-type string (`NotificationSemanticMapping.normalize` form).
        public let type: String
        /// The kind `NotificationSemanticMapping.kind(forRawType:)` derives for
        /// this type — nil for presentation-only types the mapping doesn't know.
        public let semanticKind: NotificationSemanticKind?
        /// Notification title suffix; nil falls back to the formatter's
        /// generic "Update" title.
        public let titleKey: String?
        public let titleFallback: String?
        /// Notification body default (used when the producer supplied no
        /// message); nil falls back to "<type>: <message>".
        public let bodyKey: String?
        public let bodyFallback: String?
        /// Tab style preset applied by `NotificationStylePlanner`
        /// ("error" / "attention" / "waiting"); nil means no default styling.
        public let stylePreset: String?

        init(
            type: String,
            semanticKind: NotificationSemanticKind?,
            title: (key: String, fallback: String)? = nil,
            body: (key: String, fallback: String)? = nil,
            stylePreset: String? = nil
        ) {
            self.type = type
            self.semanticKind = semanticKind
            self.titleKey = title?.key
            self.titleFallback = title?.fallback
            self.bodyKey = body?.key
            self.bodyFallback = body?.fallback
            self.stylePreset = stylePreset
        }
    }

    public static let entries: [Entry] = [
        Entry(
            type: "finished",
            semanticKind: .taskFinished,
            title: ("aiEvent.title.finished", "Finished"),
            body: ("aiEvent.body.finished", "Done."),
            stylePreset: "waiting"
        ),
        Entry(
            type: "failed",
            semanticKind: .taskFailed,
            title: ("aiEvent.title.failed", "Failed"),
            body: ("aiEvent.body.failed", "Check the logs."),
            stylePreset: "error"
        ),
        Entry(
            type: "tool_failed",
            semanticKind: .toolFailed,
            title: ("aiEvent.title.toolFailed", "Tool failed"),
            stylePreset: "error"
        ),
        Entry(
            type: "response_failed",
            semanticKind: .taskFailed,
            stylePreset: "error"
        ),
        Entry(
            type: "permission",
            semanticKind: .permissionRequired,
            title: ("aiEvent.title.permission", "Permission needed"),
            body: ("aiEvent.body.permission", "Needs your permission to continue."),
            stylePreset: "attention"
        ),
        Entry(
            type: "waiting_input",
            semanticKind: .waitingForInput,
            title: ("aiEvent.title.waitingInput", "Waiting for input"),
            body: ("aiEvent.body.waitingInput", "Ready for your input."),
            stylePreset: "waiting"
        ),
        Entry(
            // Idle shares the waiting_input title (the actionable framing is
            // the same) but keeps its own body wording.
            type: "idle",
            semanticKind: .idle,
            title: ("aiEvent.title.waitingInput", "Waiting for input"),
            body: ("aiEvent.body.idle", "No new history entries for a while."),
            stylePreset: "waiting"
        ),
        Entry(
            type: "attention_required",
            semanticKind: .attentionRequired,
            title: ("aiEvent.title.attention", "Needs attention"),
            body: ("aiEvent.body.attention", "Needs your attention."),
            stylePreset: "attention"
        ),
        Entry(
            type: "elicitation",
            semanticKind: .attentionRequired,
            stylePreset: "attention"
        ),
        Entry(
            type: "needs_validation",
            semanticKind: nil,
            title: ("aiEvent.title.needsValidation", "Needs review"),
            body: ("aiEvent.body.needsValidation", "Your input is required.")
        ),
        Entry(
            type: "error",
            semanticKind: .taskFailed,
            title: ("aiEvent.title.error", "Error"),
            body: ("aiEvent.body.error", "An error occurred."),
            stylePreset: "error"
        ),
        Entry(
            type: "context_limit",
            semanticKind: .taskFailed,
            title: ("aiEvent.title.contextLimit", "Context limit reached"),
            body: ("aiEvent.body.contextLimit", "Approaching context window limit."),
            stylePreset: "error"
        ),
        Entry(
            type: "file_conflict",
            semanticKind: nil,
            title: ("aiEvent.title.fileConflict", "File conflict")
        ),
        Entry(
            type: "tool_called",
            semanticKind: nil,
            title: ("aiEvent.title.toolCalled", "Tool called")
        ),
        Entry(
            type: "file_edited",
            semanticKind: nil,
            title: ("aiEvent.title.fileEdited", "File edited")
        ),
        Entry(
            type: "token_threshold",
            semanticKind: nil,
            title: ("aiEvent.title.tokenThreshold", "Token threshold"),
            body: ("aiEvent.body.usageThreshold", "Usage threshold exceeded.")
        ),
        Entry(
            type: "cost_threshold",
            semanticKind: nil,
            title: ("aiEvent.title.costThreshold", "Cost threshold"),
            body: ("aiEvent.body.usageThreshold", "Usage threshold exceeded.")
        )
    ]

    private static let byType: [String: Entry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.type, $0) })

    /// Looks up an entry for an already-normalized type string.
    public static func entry(forNormalizedType type: String) -> Entry? {
        byType[type]
    }

    /// Looks up an entry for a raw type string (normalizes first).
    public static func entry(forType type: String) -> Entry? {
        byType[NotificationSemanticMapping.normalize(type)]
    }
}
