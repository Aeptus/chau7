import Foundation

public enum CodexNotifyHookConfiguration {
    public static let helperName = "chau7-codex-notify"

    public static func helperScript(defaultEventsLogPath: String) -> String {
        """
        #!/usr/bin/python3
        import datetime
        import json
        import os
        import sys

        DEFAULT_EVENTS_LOG = \(quotedPythonString(defaultEventsLogPath))

        def iso_now():
            return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")

        def payload_arg():
            if len(sys.argv) > 1:
                return sys.argv[-1]
            return "{}"

        def first_nonempty(*values):
            for value in values:
                if isinstance(value, str):
                    trimmed = value.strip()
                    if trimmed:
                        return trimmed
            return None

        def build_event(payload):
            raw_type = first_nonempty(payload.get("type")) or "notification"
            turn_id = first_nonempty(payload.get("turn-id"), payload.get("turn_id"))
            thread_id = first_nonempty(payload.get("thread-id"), payload.get("thread_id"))
            cwd = first_nonempty(payload.get("cwd"), os.environ.get("CHAU7_PROJECT"))
            last_message = first_nonempty(
                payload.get("last-assistant-message"),
                payload.get("last_assistant_message"),
                payload.get("message"),
            )
            title = None
            message = last_message or "Codex emitted a notification event."
            notification_type = None

            if raw_type == "agent-turn-complete":
                title = "Codex finished"
                if not last_message:
                    message = "Codex finished the current turn."
            elif raw_type == "approval-requested":
                title = "Codex needs your approval"
                notification_type = "permission_prompt"
                if not last_message:
                    message = "Codex requested your approval."
            elif raw_type == "user-input-requested":
                title = "Codex is waiting for input"
                notification_type = "idle_prompt"
                if not last_message:
                    message = "Codex is waiting for your input."

            event = {
                "source": "codex",
                "type": raw_type,
                "rawType": raw_type,
                "tool": "Codex",
                "message": message,
                "ts": iso_now(),
                "directory": cwd,
                "sessionID": thread_id,
                "tabID": first_nonempty(os.environ.get("CHAU7_TAB_ID")),
                "producer": "codex_notify_hook",
                "reliability": "authoritative",
            }
            if title:
                event["title"] = title
            if notification_type:
                event["notificationType"] = notification_type
            if turn_id:
                event["turnID"] = turn_id
            return event

        def main():
            raw = payload_arg()
            try:
                payload = json.loads(raw)
            except Exception as exc:
                payload = {
                    "type": "notification",
                    "message": f"Failed to decode Codex notify payload: {exc}",
                }
            event = build_event(payload if isinstance(payload, dict) else {})
            log_path = os.environ.get("CHAU7_AI_EVENTS_LOG") or DEFAULT_EVENTS_LOG
            os.makedirs(os.path.dirname(os.path.expanduser(log_path)), exist_ok=True)
            with open(os.path.expanduser(log_path), "a", encoding="utf-8") as handle:
                json.dump(event, handle, ensure_ascii=True)
                handle.write("\\n")

        if __name__ == "__main__":
            main()
        """
    }

    public static func upsertNotify(in content: String, helperPath: String) -> String {
        let desiredLine = "notify = [\"\(escapeTomlString(helperPath))\"]"
        let lines = content.components(separatedBy: .newlines)
        var updated: [String] = []
        var foundNotify = false
        var skippingExisting = false
        var notifyBracketDepth = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if skippingExisting {
                notifyBracketDepth += bracketDelta(in: line)
                if notifyBracketDepth <= 0 {
                    skippingExisting = false
                }
                continue
            }

            if !foundNotify, isTopLevelNotifyLine(trimmed) {
                foundNotify = true
                updated.append(desiredLine)
                notifyBracketDepth = bracketDelta(in: line)
                if notifyBracketDepth > 0 {
                    skippingExisting = true
                }
                continue
            }

            if !foundNotify, trimmed.hasPrefix("[") {
                updated.append(desiredLine)
                foundNotify = true
            }

            updated.append(line)
        }

        if !foundNotify {
            if !updated.isEmpty, !(updated.last?.isEmpty ?? true) {
                updated.append("")
            }
            updated.append(desiredLine)
        }

        return updated.joined(separator: "\n")
    }

    private static func quotedPythonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func escapeTomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func isTopLevelNotifyLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("notify") && trimmed.contains("=")
    }

    private static func bracketDelta(in line: String) -> Int {
        let rhs: Substring
        if let range = line.range(of: "=") {
            rhs = line[range.upperBound...]
        } else {
            rhs = Substring(line)
        }
        let opens = rhs.filter { $0 == "[" }.count
        let closes = rhs.filter { $0 == "]" }.count
        return opens - closes
    }
}
