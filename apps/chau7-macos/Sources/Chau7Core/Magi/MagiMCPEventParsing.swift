import Foundation

public enum MagiMCPEventParsing {
    public static func runtimeEventMessages(
        from events: [MagiMCPRuntimeEvent],
        tabID: String,
        eventTypes: [String]
    ) -> [String] {
        let requestedTypes = Set(eventTypes.map { $0.lowercased() })
        return events.compactMap { event -> String? in
            guard event.tabID == tabID else { return nil }
            let eventType = event.detail.eventType.isEmpty
                ? event.type
                : event.detail.eventType
            guard requestedTypes.contains(eventType.lowercased()) else { return nil }
            let message = event.detail.message
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }
    }

    public static func tabStatusIsIdleForRepair(_ status: MagiMCPTabStatus) -> Bool {
        if status.hasActiveRun {
            return false
        }
        if status.canAcceptExec || status.readyForExec {
            return true
        }
        if status.isAtPrompt || status.rawIsAtPrompt {
            return true
        }

        let terminalStates = ["idle", "done", "exited"]
        return terminalStates.contains(status.status.lowercased())
            || terminalStates.contains(status.rawStatus.lowercased())
    }
}
