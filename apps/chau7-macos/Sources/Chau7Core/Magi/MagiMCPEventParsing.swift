import Foundation

public enum MagiMCPEventParsing {
    public static func runtimeEventMessages(
        from events: [[String: Any]],
        tabID: String,
        eventTypes: [String]
    ) -> [String] {
        let requestedTypes = Set(eventTypes.map { $0.lowercased() })
        return events.compactMap { event -> String? in
            guard stringField(event["tab_id"]) == tabID else { return nil }
            let detail = event["detail"] as? [String: Any] ?? [:]
            let eventType = stringField(detail["event_type"]).isEmpty
                ? stringField(event["type"])
                : stringField(detail["event_type"])
            guard requestedTypes.contains(eventType.lowercased()) else { return nil }
            let message = stringField(detail["message"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }
    }

    public static func tabStatusIsIdleForRepair(_ status: [String: Any]) -> Bool {
        if status["active_run"] is [String: Any] {
            return false
        }
        if boolField(status["can_accept_exec"]) || boolField(status["ready_for_exec"]) {
            return true
        }
        if boolField(status["is_at_prompt"]) || boolField(status["raw_is_at_prompt"]) {
            return true
        }

        let terminalStates = ["idle", "done", "exited"]
        return ["status", "raw_status"].contains { key in
            terminalStates.contains(stringField(status[key]).lowercased())
        }
    }

    private static func stringField(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return String(bool) }
        if let int = value as? Int { return String(int) }
        return "\(value)"
    }

    private static func boolField(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            return ["true", "yes", "1"].contains(string.lowercased())
        }
        if let int = value as? Int { return int != 0 }
        return false
    }
}
