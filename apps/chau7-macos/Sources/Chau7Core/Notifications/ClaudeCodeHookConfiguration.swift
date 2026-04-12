import Foundation

/// Self-installing Claude Code hook configuration.
///
/// Mirrors `CodexNotifyHookConfiguration`: generates a helper script from
/// Swift constants and upserts hook entries into `~/.claude/settings.json`
/// so Chau7 captures all user-facing Claude Code events automatically.
public enum ClaudeCodeHookConfiguration {
    public static let helperName = "chau7-claude-hook"

    /// All hook events Chau7 registers for, with their event type mapping.
    public static let hookEvents: [(hookName: String, eventType: String)] = [
        ("UserPromptSubmit", "user_prompt"),
        ("PreToolUse", "tool_start"),
        ("PostToolUse", "tool_complete"),
        ("PostToolUseFailure", "tool_failed"),
        ("PermissionRequest", "permission_request"),
        ("Notification", "notification"),
        ("Stop", "response_complete"),
        ("StopFailure", "response_failed"),
        ("SubagentStop", "tool_complete"),
        ("SessionStart", "session_start"),
        ("SessionEnd", "session_end"),
        ("Elicitation", "elicitation"),
    ]

    /// Generates the hook helper script (Python).
    ///
    /// Claude Code pipes JSON to stdin on each hook event. The script:
    /// 1. Reads stdin JSON
    /// 2. Maps `hook_event_name` → Chau7 event type
    /// 3. Writes a single JSONL line to `eventsFilePath`
    /// 4. Exits 0 always (never blocks Claude Code)
    public static func helperScript(eventsFilePath: String) -> String {
        let mappingLines = hookEvents.map { "    \(quotedPythonString($0.hookName)): \(quotedPythonString($0.eventType))," }
            .joined(separator: "\n")

        return """
        #!/usr/bin/python3
        import datetime
        import json
        import os
        import sys

        EVENTS_FILE = \(quotedPythonString(eventsFilePath))

        HOOK_TYPE_MAP = {
        \(mappingLines)
        }

        def iso_now():
            return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")

        def main():
            try:
                raw = sys.stdin.read()
                payload = json.loads(raw) if raw.strip() else {}
            except Exception:
                payload = {}

            hook = payload.get("hook_event_name", "")
            event_type = HOOK_TYPE_MAP.get(hook, "unknown")

            # For Notification events, infer permission from message text
            if hook == "Notification" and event_type == "notification":
                msg = (payload.get("message") or "").lower()
                if "permission" in msg or "approval" in msg:
                    event_type = "permission_request"

            event = {
                "type": event_type,
                "hook": hook,
                "sessionId": payload.get("session_id", ""),
                "transcriptPath": payload.get("transcript_path", ""),
                "toolName": payload.get("tool_name", ""),
                "message": payload.get("message") or payload.get("prompt") or "",
                "cwd": payload.get("cwd", ""),
                "timestamp": iso_now(),
            }

            os.makedirs(os.path.dirname(os.path.expanduser(EVENTS_FILE)), exist_ok=True)
            with open(os.path.expanduser(EVENTS_FILE), "a", encoding="utf-8") as f:
                json.dump(event, f, ensure_ascii=True)
                f.write("\\n")

        if __name__ == "__main__":
            try:
                main()
            except Exception:
                pass  # Never block Claude Code
        """
    }

    // MARK: - settings.json Hook Upsert

    /// Upserts Chau7 hook entries into Claude Code's settings.json content.
    /// Preserves all existing hooks (including user's own). Only adds/updates
    /// the chau7 helper command for each registered hook event.
    public static func upsertHooks(in jsonData: Data, helperPath: String) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for (hookName, _) in hookEvents {
            let chau7Entry: [String: Any] = [
                "matcher": "",
                "hooks": [["type": "command", "command": helperPath] as [String: Any]]
            ]

            if var existingArray = hooks[hookName] as? [[String: Any]] {
                // Check if chau7 hook already present
                let hasChau7 = existingArray.contains { entry in
                    guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { ($0["command"] as? String)?.contains("chau7") == true }
                }
                if hasChau7 {
                    // Update existing chau7 entry's command path
                    existingArray = existingArray.map { entry in
                        guard let innerHooks = entry["hooks"] as? [[String: Any]],
                              innerHooks.contains(where: { ($0["command"] as? String)?.contains("chau7") == true })
                        else { return entry }
                        return chau7Entry
                    }
                    hooks[hookName] = existingArray
                } else {
                    existingArray.append(chau7Entry)
                    hooks[hookName] = existingArray
                }
            } else {
                hooks[hookName] = [chau7Entry]
            }
        }

        root["hooks"] = hooks
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Returns true if all required hooks are already registered with the chau7 helper.
    public static func allHooksInstalled(in jsonData: Data, helperPath: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        for (hookName, _) in hookEvents {
            guard let entries = hooks[hookName] as? [[String: Any]] else { return false }
            let hasChau7 = entries.contains { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { ($0["command"] as? String) == helperPath }
            }
            if !hasChau7 { return false }
        }
        return true
    }

    private static func quotedPythonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
