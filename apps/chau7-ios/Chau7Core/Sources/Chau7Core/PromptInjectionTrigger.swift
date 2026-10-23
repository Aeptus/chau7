import Foundation

public enum PromptInjectionTrigger: String, Codable, CaseIterable, Hashable, Sendable {
    case everyPrompt = "every_prompt"
    case firstSessionPrompt = "first_session_prompt"
    case afterCompact = "after_compact"
    case afterClear = "after_clear"

    public static let defaultSet: Set<PromptInjectionTrigger> = [.everyPrompt]

    public static func normalized(_ triggers: Set<PromptInjectionTrigger>) -> Set<PromptInjectionTrigger> {
        triggers.isEmpty ? defaultSet : triggers
    }

    public func matches(event: PromptInjectionSessionEvent) -> Bool {
        switch (self, event) {
        case (.afterCompact, .afterCompact), (.afterClear, .afterClear):
            return true
        default:
            return false
        }
    }
}

public enum PromptInjectionSessionEvent: String, Codable, CaseIterable, Sendable {
    case afterCompact = "after_compact"
    case afterClear = "after_clear"

    public static func detect(in line: String) -> PromptInjectionSessionEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let command = trimmed.split(whereSeparator: \.isWhitespace).first?.lowercased()
        switch command {
        case "/compact":
            return .afterCompact
        case "/clear":
            return .afterClear
        default:
            return nil
        }
    }
}
