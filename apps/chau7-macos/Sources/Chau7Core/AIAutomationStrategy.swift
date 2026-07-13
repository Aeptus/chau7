import Foundation

public enum AIAutomationInsertMode: Equatable {
    case rawText
    case pasteText
}

public enum AIAutomationSubmitMode: Equatable {
    case none
    case rawNewline
    case enterKey
}

public struct AIAutomationInputPlan: Equatable {
    public let insertText: String
    public let insertMode: AIAutomationInsertMode
    public let submitMode: AIAutomationSubmitMode
    public let submitDelayMs: Int

    public init(
        insertText: String,
        insertMode: AIAutomationInsertMode,
        submitMode: AIAutomationSubmitMode,
        submitDelayMs: Int
    ) {
        self.insertText = insertText
        self.insertMode = insertMode
        self.submitMode = submitMode
        self.submitDelayMs = submitDelayMs
    }
}

public struct AIAutomationSubmitPlan: Equatable {
    public let submitMode: AIAutomationSubmitMode
    public let submitDelayMs: Int

    public init(submitMode: AIAutomationSubmitMode, submitDelayMs: Int) {
        self.submitMode = submitMode
        self.submitDelayMs = submitDelayMs
    }
}

public enum AIAutomationStrategy {
    private static let codexSubmitDelayMs = 120
    private static let recentAutomationWindowMs = 1000
    private static let remoteSubmitDelayMs = 60

    public static func inputPlan(for input: String, provider: String?) -> AIAutomationInputPlan {
        let normalizedProvider = normalizedProviderKey(provider)
        guard normalizedProvider == "codex" else {
            return AIAutomationInputPlan(
                insertText: input,
                insertMode: .rawText,
                submitMode: .none,
                submitDelayMs: 0
            )
        }

        let (body, wantsSubmit) = splitTrailingSubmit(from: input)
        return AIAutomationInputPlan(
            insertText: body,
            insertMode: .pasteText,
            submitMode: wantsSubmit ? .rawNewline : .none,
            submitDelayMs: wantsSubmit && !body.isEmpty ? codexSubmitDelayMs : 0
        )
    }

    /// Plan for remote (iOS) keyboard input. The submit terminator must NOT
    /// travel in the same PTY write as the body: TUI composers (Claude Code,
    /// Codex) treat a single stdin chunk containing text + trailing CR as a
    /// paste and insert it into the input field, whereas a real Enter arrives
    /// as its own read. Split the trailing terminator into a separate, delayed
    /// submit so remote sends behave like typed-then-Enter input.
    public static func remoteInputPlan(for input: String, provider: String?) -> AIAutomationInputPlan {
        let (body, wantsSubmit) = splitTrailingSubmit(from: input)
        let isCodex = normalizedProviderKey(provider) == "codex"
        guard wantsSubmit else {
            // No submit terminator — pass through untouched. This branch also
            // carries keyboard-bar control sequences (ESC, ^C, arrows), which
            // must never be paste-wrapped or reordered.
            return AIAutomationInputPlan(
                insertText: input,
                insertMode: .rawText,
                submitMode: .none,
                submitDelayMs: 0
            )
        }
        return AIAutomationInputPlan(
            insertText: body,
            insertMode: isCodex ? .pasteText : .rawText,
            submitMode: isCodex ? .rawNewline : .enterKey,
            submitDelayMs: body.isEmpty ? 0 : (isCodex ? codexSubmitDelayMs : remoteSubmitDelayMs)
        )
    }

    public static func submitPlan(provider: String?, recentAutomationInputAgeMs: Int?) -> AIAutomationSubmitPlan {
        let normalizedProvider = normalizedProviderKey(provider)
        guard normalizedProvider == "codex" else {
            return AIAutomationSubmitPlan(submitMode: .enterKey, submitDelayMs: 0)
        }

        let shouldDelay = recentAutomationInputAgeMs.map { $0 >= 0 && $0 <= recentAutomationWindowMs } ?? false
        return AIAutomationSubmitPlan(
            submitMode: .rawNewline,
            submitDelayMs: shouldDelay ? codexSubmitDelayMs : 0
        )
    }

    private static func splitTrailingSubmit(from input: String) -> (String, Bool) {
        guard !input.isEmpty else { return ("", false) }
        var body = input
        var trimmedAny = false
        while true {
            if let range = body.range(of: "\r\n", options: [.anchored, .backwards]) {
                body.removeSubrange(range)
                trimmedAny = true
                continue
            }
            if let range = body.range(of: "\n", options: [.anchored, .backwards]) {
                body.removeSubrange(range)
                trimmedAny = true
                continue
            }
            if let range = body.range(of: "\r", options: [.anchored, .backwards]) {
                body.removeSubrange(range)
                trimmedAny = true
                continue
            }
            break
        }
        return (body, trimmedAny)
    }

    private static func normalizedProviderKey(_ provider: String?) -> String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let normalized = AIResumeParser.normalizeProviderName(trimmed) {
            return normalized.lowercased()
        }
        return trimmed.lowercased()
    }
}
