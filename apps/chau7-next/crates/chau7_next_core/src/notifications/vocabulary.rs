//! Current Swift TriggerVocabulary: one presentation table, canonical kind
//! mapping remains authoritative in adapters. No duplicate provider switches.
use super::canonical::{self, NotificationSemanticKind as Kind};
#[derive(Debug, Clone, Copy)]
pub struct Entry {
    pub event_type: &'static str,
    pub semantic_kind: Option<Kind>,
    pub title: Option<(&'static str, &'static str)>,
    pub body: Option<(&'static str, &'static str)>,
    pub style: Option<&'static str>,
}
pub const ENTRIES: [Entry; 20] = [
    Entry {
        event_type: "finished",
        semantic_kind: Some(Kind::TaskFinished),
        title: Some(("aiEvent.title.finished", "Finished")),
        body: Some(("aiEvent.body.finished", "Done.")),
        style: Some("success"),
    },
    Entry {
        event_type: "failed",
        semantic_kind: Some(Kind::TaskFailed),
        title: Some(("aiEvent.title.failed", "Failed")),
        body: Some(("aiEvent.body.failed", "Check the logs.")),
        style: Some("error"),
    },
    Entry {
        event_type: "script_succeeded",
        semantic_kind: Some(Kind::TaskFinished),
        title: Some(("aiEvent.title.scriptSucceeded", "Script succeeded")),
        body: Some((
            "aiEvent.body.scriptSucceeded",
            "The shell script completed successfully.",
        )),
        style: Some("success"),
    },
    Entry {
        event_type: "script_failed",
        semantic_kind: Some(Kind::TaskFailed),
        title: Some(("aiEvent.title.scriptFailed", "Script failed")),
        body: Some((
            "aiEvent.body.scriptFailed",
            "The shell script exited with an error.",
        )),
        style: Some("error"),
    },
    Entry {
        event_type: "dev_server_started",
        semantic_kind: Some(Kind::Informational),
        title: Some(("aiEvent.title.devServerStarted", "Dev server started")),
        body: Some((
            "aiEvent.body.devServerStarted",
            "The development server is ready.",
        )),
        style: Some("success"),
    },
    Entry {
        event_type: "tool_failed",
        semantic_kind: Some(Kind::ToolFailed),
        title: Some(("aiEvent.title.toolFailed", "Tool failed")),
        body: None,
        style: Some("error"),
    },
    Entry {
        event_type: "response_failed",
        semantic_kind: Some(Kind::TaskFailed),
        title: None,
        body: None,
        style: Some("error"),
    },
    Entry {
        event_type: "permission",
        semantic_kind: Some(Kind::PermissionRequired),
        title: Some(("aiEvent.title.permission", "Permission needed")),
        body: Some((
            "aiEvent.body.permission",
            "Needs your permission to continue.",
        )),
        style: Some("attention"),
    },
    Entry {
        event_type: "waiting_input",
        semantic_kind: Some(Kind::WaitingForInput),
        title: Some(("aiEvent.title.waitingInput", "Waiting for input")),
        body: Some(("aiEvent.body.waitingInput", "Ready for your input.")),
        style: Some("waiting"),
    },
    Entry {
        event_type: "idle",
        semantic_kind: Some(Kind::Idle),
        title: Some(("aiEvent.title.waitingInput", "Waiting for input")),
        body: Some(("aiEvent.body.idle", "No new history entries for a while.")),
        style: Some("waiting"),
    },
    Entry {
        event_type: "attention_required",
        semantic_kind: Some(Kind::AttentionRequired),
        title: Some(("aiEvent.title.attention", "Needs attention")),
        body: Some(("aiEvent.body.attention", "Needs your attention.")),
        style: Some("attention"),
    },
    Entry {
        event_type: "elicitation",
        semantic_kind: Some(Kind::AttentionRequired),
        title: None,
        body: None,
        style: Some("attention"),
    },
    Entry {
        event_type: "needs_validation",
        semantic_kind: None,
        title: Some(("aiEvent.title.needsValidation", "Needs review")),
        body: Some(("aiEvent.body.needsValidation", "Your input is required.")),
        style: None,
    },
    Entry {
        event_type: "error",
        semantic_kind: Some(Kind::TaskFailed),
        title: Some(("aiEvent.title.error", "Error")),
        body: Some(("aiEvent.body.error", "An error occurred.")),
        style: Some("error"),
    },
    Entry {
        event_type: "context_limit",
        semantic_kind: Some(Kind::TaskFailed),
        title: Some(("aiEvent.title.contextLimit", "Context limit reached")),
        body: Some((
            "aiEvent.body.contextLimit",
            "Approaching context window limit.",
        )),
        style: Some("error"),
    },
    Entry {
        event_type: "file_conflict",
        semantic_kind: None,
        title: Some(("aiEvent.title.fileConflict", "File conflict")),
        body: None,
        style: None,
    },
    Entry {
        event_type: "tool_called",
        semantic_kind: None,
        title: Some(("aiEvent.title.toolCalled", "Tool called")),
        body: None,
        style: None,
    },
    Entry {
        event_type: "file_edited",
        semantic_kind: None,
        title: Some(("aiEvent.title.fileEdited", "File edited")),
        body: None,
        style: None,
    },
    Entry {
        event_type: "token_threshold",
        semantic_kind: None,
        title: Some(("aiEvent.title.tokenThreshold", "Token threshold")),
        body: Some(("aiEvent.body.usageThreshold", "Usage threshold exceeded.")),
        style: None,
    },
    Entry {
        event_type: "cost_threshold",
        semantic_kind: None,
        title: Some(("aiEvent.title.costThreshold", "Cost threshold")),
        body: Some(("aiEvent.body.usageThreshold", "Usage threshold exceeded.")),
        style: None,
    },
];
pub fn entry(raw: &str) -> Option<&'static Entry> {
    let normalized = canonical::normalize(raw);
    ENTRIES.iter().find(|e| e.event_type == normalized)
}
pub fn semantic_trigger(kind: Kind) -> Option<&'static str> {
    match kind {
        Kind::TaskFinished => Some("finished"),
        Kind::TaskFailed => Some("failed"),
        Kind::ToolFailed => Some("tool_failed"),
        Kind::PermissionRequired => Some("permission"),
        Kind::WaitingForInput => Some("waiting_input"),
        Kind::AttentionRequired => Some("attention_required"),
        Kind::Idle => Some("idle"),
        _ => None,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn declared_kinds_cannot_drift_from_canonical_mapping() {
        let mut seen = std::collections::BTreeSet::new();
        for e in ENTRIES {
            assert!(seen.insert(e.event_type));
            if let Some(kind) = e.semantic_kind {
                assert_eq!(
                    canonical::kind(Some(e.event_type), None),
                    kind,
                    "{}",
                    e.event_type
                );
            }
        }
    }
    #[test]
    fn presentation_rows_and_semantic_aliases_share_exact_defaults() {
        assert_eq!(entry("waiting-input").unwrap().style, Some("waiting"));
        assert_eq!(entry("finished").unwrap().style, Some("success"));
        assert_eq!(entry("script_succeeded").unwrap().style, Some("success"));
        assert_eq!(entry("dev-server-started").unwrap().style, Some("success"));
        assert_eq!(entry("tool_failed").unwrap().style, Some("error"));
        assert_eq!(
            entry("idle").unwrap().title,
            entry("waiting_input").unwrap().title
        );
        assert_eq!(semantic_trigger(Kind::Informational), None);
    }
}
