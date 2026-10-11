//! Runtime tools (`runtime_*`, MCP-031 to MCP-038): agent sessions run in
//! tabs (`Runtime/RuntimeControlService.swift`), handled by
//! [`crate::runtime::control`]. The schemas are the Swift ones.

use serde_json::{Map, Value, json};

use super::{ToolContext, tool};

pub fn definitions() -> Vec<Value> {
    vec![
        tool(
            "runtime_session_create",
            "Start an agent session. Creates a tab, launches the backend (claude/codex/shell), and returns a session ID for subsequent operations.",
            json!({
                "type": "object",
                "properties": {
                    "backend": {"type": "string", "description": "Backend to use: 'claude' (default), 'codex', or 'shell'"},
                    "directory": {"type": "string", "description": "Working directory for the session"},
                    "model": {
                        "type": "string",
                        "description": "Model override. Must match the backend: claude accepts 'opus', 'sonnet', 'haiku'; codex accepts 'o3', 'o4-mini', 'gpt-4.1'. Cross-backend models (e.g. 'sonnet' with codex) are rejected."
                    },
                    "resume_session_id": {"type": "string", "description": "Resume an existing agent session by ID"},
                    "env": {"type": "object", "description": "Extra environment variables"},
                    "backend_args": {"type": "array", "items": {"type": "string"}, "description": "Additional CLI arguments"},
                    "initial_prompt": {"type": "string", "description": "Prompt to send immediately after backend starts. Delivered with retry (up to ~4s) to handle backend startup time."},
                    "auto_approve": {"type": "boolean", "description": "Auto-approve safe tool use requests. For claude: --dangerously-skip-permissions. For codex: --full-auto."},
                    "attach_tab_id": {"type": "string", "description": "Attach to existing tab instead of creating new one"}
                }
            }),
        ),
        tool(
            "runtime_session_list",
            "List active runtime sessions.",
            json!({
                "type": "object",
                "properties": {
                    "include_stopped": {"type": "boolean", "description": "Include recently stopped sessions"}
                }
            }),
        ),
        tool(
            "runtime_session_get",
            "Get detailed state of a runtime session.",
            json!({
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Runtime session ID"}
                },
                "required": ["session_id"]
            }),
        ),
        tool(
            "runtime_session_stop",
            "Gracefully stop a runtime session.",
            json!({
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Runtime session ID"},
                    "close_tab": {"type": "boolean", "description": "Also close the tab"},
                    "force": {"type": "boolean", "description": "Send Ctrl+C before stopping"}
                },
                "required": ["session_id"]
            }),
        ),
        tool(
            "runtime_turn_send",
            "Send a prompt to an agent session. Session must be in 'ready' state. Use runtime_turn_status or runtime_events_poll to check readiness first. Returns error with current state if not ready.",
            json!({
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Runtime session ID"},
                    "prompt": {"type": "string", "description": "The prompt to send to the agent"},
                    "context": {"type": "string", "description": "Optional context prepended to the prompt"}
                },
                "required": ["session_id", "prompt"]
            }),
        ),
        tool(
            "runtime_turn_status",
            "Check the current turn state of a session.",
            json!({
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Runtime session ID"},
                    "turn_id": {"type": "string", "description": "Optional specific turn ID"}
                },
                "required": ["session_id"]
            }),
        ),
        tool(
            "runtime_events_poll",
            "Poll for new events from a session using a cursor. Returns events after the cursor position.",
            json!({
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Runtime session ID"},
                    "cursor": {"type": "integer", "description": "Cursor from previous poll (0 for first poll)"},
                    "limit": {"type": "integer", "description": "Max events to return (default 50)"}
                },
                "required": ["session_id"]
            }),
        ),
        tool(
            "runtime_approval_respond",
            "Approve or deny a pending tool use request from the agent.",
            json!({
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Runtime session ID"},
                    "approval_id": {"type": "string", "description": "Approval request ID from approval_needed event"},
                    "approved": {"type": "boolean", "description": "Whether to approve the tool use"},
                    "reason": {"type": "string", "description": "Reason for decision"}
                },
                "required": ["session_id", "approval_id", "approved"]
            }),
        ),
    ]
}

/// `RuntimeControlService.handleToolCall` (`crate::runtime::control`).
pub fn call(name: &str, args: &Map<String, Value>, ctx: &ToolContext) -> String {
    crate::runtime::control::handle_tool_call(name, args, ctx)
}
