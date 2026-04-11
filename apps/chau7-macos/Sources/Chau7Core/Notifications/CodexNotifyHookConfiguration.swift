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
        let desiredLine = renderNotifyLine(
            entries: mergedNotifyEntries(in: content, helperPath: helperPath)
        )
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

    public static func notifyIncludesHelper(in content: String, helperPath: String) -> Bool {
        mergedNotifyEntries(in: content, helperPath: nil).contains(helperPath)
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

    private static func renderNotifyLine(entries: [String]) -> String {
        let renderedEntries = entries.map { "\"\(escapeTomlString($0))\"" }.joined(separator: ", ")
        return "notify = [\(renderedEntries)]"
    }

    private static func mergedNotifyEntries(in content: String, helperPath: String?) -> [String] {
        var entries = existingNotifyEntries(in: content)
        if let helperPath, !entries.contains(helperPath) {
            entries.append(helperPath)
        }
        return entries
    }

    private static func existingNotifyEntries(in content: String) -> [String] {
        let lines = content.components(separatedBy: .newlines)
        var collecting = false
        var bracketDepth = 0
        var buffer = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !collecting, isTopLevelNotifyLine(trimmed) {
                collecting = true
            } else if !collecting {
                continue
            }

            if !buffer.isEmpty {
                buffer.append("\n")
            }
            buffer.append(line)
            bracketDepth += bracketDelta(in: line)
            if bracketDepth <= 0 {
                break
            }
        }

        guard !buffer.isEmpty,
              let regex = try? NSRegularExpression(pattern: #""((?:\\.|[^"])*)""#) else {
            return []
        }
        let nsBuffer = buffer as NSString
        let range = NSRange(location: 0, length: nsBuffer.length)
        return regex.matches(in: buffer, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let raw = nsBuffer.substring(with: match.range(at: 1))
            return raw
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
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

    // MARK: - TUI notification settings

    //
    // Codex's TUI writes desktop notifications to stdout as `ESC]9;<message>BEL`
    // (OSC 9 sequences) for EVERY notification kind — agent-turn-complete,
    // exec/edit approval requests, plan-mode prompts, user-input requests,
    // elicitations. That's a strictly larger set than the external `notify`
    // program, which only fires for `agent-turn-complete`.
    //
    // Two conditions have to be true for Codex to emit OSC 9 in the first place:
    //
    //   1. `notification_method = "osc9"`. Otherwise the default is `auto`, which
    //      falls back to a bare BEL (\x07) when the terminal isn't one of a short
    //      allow-list (iTerm, WezTerm, ghostty, kitty). Chau7 sets
    //      `TERM_PROGRAM=Chau7` so the auto-detect fails — we must pin explicitly.
    //
    //   2. `notification_condition = "always"`. Otherwise the default is
    //      `unfocused`, and Codex suppresses notifications whenever the terminal
    //      is focused. Chau7 IS the terminal, so "focused" is the normal state;
    //      we'd silence almost every notification in practice.
    //
    // This helper upserts both settings under a `[tui]` section so that Codex's
    // OSC 9 stream is fully live. We parse it back downstream from the PTY.
    public static let tuiNotificationMethod = "osc9"
    public static let tuiNotificationCondition = "always"

    /// Upsert `[tui]` with `notification_method = "osc9"` and
    /// `notification_condition = "always"` into the given config.toml content.
    /// Preserves any other keys already present in a `[tui]` section.
    public static func upsertTuiNotificationSettings(in content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var result: [String] = []
        var inTuiSection = false
        var seenSection = false
        var sawMethod = false
        var sawCondition = false

        func emitDesiredKeysIfNeeded() {
            if !sawMethod {
                result.append("notification_method = \"\(tuiNotificationMethod)\"")
                sawMethod = true
            }
            if !sawCondition {
                result.append("notification_condition = \"\(tuiNotificationCondition)\"")
                sawCondition = true
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Start of a new top-level section
            if trimmed.hasPrefix("[") {
                if inTuiSection {
                    // Leaving [tui] — make sure both keys were written before the next section
                    emitDesiredKeysIfNeeded()
                }
                inTuiSection = (trimmed == "[tui]")
                if inTuiSection {
                    seenSection = true
                }
                result.append(line)
                continue
            }

            if inTuiSection {
                // Replace existing notification_method / notification_condition lines
                if trimmed.hasPrefix("notification_method") {
                    result.append("notification_method = \"\(tuiNotificationMethod)\"")
                    sawMethod = true
                    continue
                }
                if trimmed.hasPrefix("notification_condition") {
                    result.append("notification_condition = \"\(tuiNotificationCondition)\"")
                    sawCondition = true
                    continue
                }
            }

            result.append(line)
        }

        // File ended while still inside [tui] — flush any missing keys
        if inTuiSection {
            emitDesiredKeysIfNeeded()
        }

        // No [tui] section at all — append one
        if !seenSection {
            if !result.isEmpty, !(result.last?.isEmpty ?? true) {
                result.append("")
            }
            result.append("[tui]")
            result.append("notification_method = \"\(tuiNotificationMethod)\"")
            result.append("notification_condition = \"\(tuiNotificationCondition)\"")
        }

        return result.joined(separator: "\n")
    }
}
