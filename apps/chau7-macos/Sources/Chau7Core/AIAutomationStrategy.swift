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
    /// Kill the current input line (^U, its own PTY write) before inserting
    /// the body. Set for remote submitted sends: a phone send is a complete
    /// message, and without this it concatenates onto whatever already sits
    /// on the line — a restore prefill awaiting confirmation, or a stale
    /// draft from an earlier send whose Enter was lost.
    public let clearLineFirst: Bool

    public init(
        insertText: String,
        insertMode: AIAutomationInsertMode,
        submitMode: AIAutomationSubmitMode,
        submitDelayMs: Int,
        clearLineFirst: Bool = false
    ) {
        self.insertText = insertText
        self.insertMode = insertMode
        self.submitMode = submitMode
        self.submitDelayMs = submitDelayMs
        self.clearLineFirst = clearLineFirst
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

public struct AIAutomationKeyStep: Equatable {
    public let key: RemoteKeyInputPayload.Key
    public let delayMs: Int

    public init(key: RemoteKeyInputPayload.Key, delayMs: Int) {
        self.key = key
        self.delayMs = delayMs
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
            // Enter key (CR), not raw LF: current Codex TUIs parse 0x0A as
            // Ctrl-J rather than Enter, so a rawNewline submit silently does
            // nothing — text sits in the composer forever. The insertion
            // delay below is what made automated submits reliable, not the
            // byte choice.
            submitMode: wantsSubmit ? .enterKey : .none,
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
            // Enter key for every provider: raw LF no longer submits in
            // current Codex TUIs (0x0A parses as Ctrl-J, not Enter).
            submitMode: .enterKey,
            submitDelayMs: body.isEmpty ? 0 : (isCodex ? codexSubmitDelayMs : remoteSubmitDelayMs),
            // A submitted body is a complete message: replace the line rather
            // than append to it. Bare Enter (empty body) deliberately does NOT
            // clear — it confirms whatever is on the line, which is how a
            // pending resume prefill gets run from the phone.
            clearLineFirst: !body.isEmpty
        )
    }

    /// Schedule for a remote semantic key sequence (KEY_INPUT frame). Keys
    /// are written sequentially as separate PTY writes; a trailing Enter that
    /// follows other keys is delayed like remote submits so the TUI re-renders
    /// the selection before it is confirmed — the same rationale as
    /// `remoteInputPlan`'s split body/terminator. Capped at
    /// `RemoteKeyInputPayload.maxKeys`; excess keys are dropped.
    public static func keyInputSchedule(for keys: [RemoteKeyInputPayload.Key]) -> [AIAutomationKeyStep] {
        let capped = Array(keys.prefix(RemoteKeyInputPayload.maxKeys))
        return capped.enumerated().map { index, key in
            let isPlainEnter = ["enter", "return"]
                .contains(key.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                && (key.modifiers ?? []).isEmpty
            let isTrailing = index == capped.count - 1
            let delayMs = isPlainEnter && isTrailing && index > 0 ? remoteSubmitDelayMs : 0
            return AIAutomationKeyStep(key: key, delayMs: delayMs)
        }
    }

    public static func submitPlan(provider: String?, recentAutomationInputAgeMs: Int?) -> AIAutomationSubmitPlan {
        let normalizedProvider = normalizedProviderKey(provider)
        guard normalizedProvider == "codex" else {
            return AIAutomationSubmitPlan(submitMode: .enterKey, submitDelayMs: 0)
        }

        let shouldDelay = recentAutomationInputAgeMs.map { $0 >= 0 && $0 <= recentAutomationWindowMs } ?? false
        return AIAutomationSubmitPlan(
            // Enter key (CR): raw LF parses as Ctrl-J in current Codex TUIs
            // and never submits.
            submitMode: .enterKey,
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
