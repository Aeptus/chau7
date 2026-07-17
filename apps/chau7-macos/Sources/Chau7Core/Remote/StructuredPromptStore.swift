import CryptoKit
import Foundation

/// A live interactive question captured structurally from a Claude Code hook
/// (PreToolUse of AskUserQuestion), ready to surface as a remote prompt card
/// with exact question text and option labels — no TUI scraping involved.
public struct StructuredPromptEntry: Equatable, Sendable {
    public let runtimeTabID: UUID
    public let sessionID: String
    public let toolUseID: String
    /// Which interactive tool produced this entry — lifecycle clears are
    /// scoped to it so e.g. AskUserQuestion completing never clears a plan
    /// review still on screen.
    public let toolName: String
    public let prompt: String
    public let detail: String?
    /// Empty for tools whose on-screen menu labels aren't in tool_input
    /// (ExitPlanMode): those entries drive the waiting-status projection but
    /// emit no card themselves — the scrape reads the real menu instead.
    public let options: [RemoteInteractivePromptOption]
    public let createdAt: Date
    /// Stable identity basis for the wire prompt ID: hashes the session,
    /// tool use, question, and option labels — never cursor state.
    public let signature: String
}

/// Holds the structured questions Claude Code sessions are currently blocked
/// on. Pure logic with an injected clock; NOT thread-safe — the app confines
/// it to the main actor (fed from AppModel's hook funnel, read by
/// RemoteControlManager), tests drive it synchronously.
///
/// Lifecycle: an entry appears on PreToolUse(AskUserQuestion) and is cleared
/// by the same session's PostToolUse/PostToolUseFailure of that tool (fires
/// the moment the question is answered from ANY surface — Mac keyboard or
/// phone), by the session's Stop/StopFailure/SessionEnd, or by a safety TTL.
/// v1 surfaces only single-question payloads: multi-question advance-tracking
/// desyncs when the Mac answers mid-sequence, and the scrape path covers it.
public final class StructuredPromptStore {
    public static let askUserQuestionToolName = "AskUserQuestion"
    public static let exitPlanModeToolName = "ExitPlanMode"
    static let interactiveToolNames: Set<String> = [askUserQuestionToolName, exitPlanModeToolName]
    /// Deliberately generous: a question legitimately sits unanswered for a
    /// long time, and the scrape path remains as backstop after expiry.
    public static let defaultTTL: TimeInterval = 3600
    static let maxPlanExcerptLength = 500

    private struct Key: Hashable {
        let runtimeTabID: UUID
        let sessionID: String
    }

    private let ttl: TimeInterval
    private let now: () -> Date
    private var entries: [Key: StructuredPromptEntry] = [:]

    public init(ttl: TimeInterval = StructuredPromptStore.defaultTTL, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    // MARK: - Intake

    /// PreToolUse. Returns true when the visible prompt set changed.
    @discardableResult
    public func applyToolStart(
        toolName: String,
        toolInputJSON: String?,
        toolUseID: String,
        runtimeTabID: UUID,
        sessionID: String
    ) -> Bool {
        purgeExpired()
        let parsed: StructuredPromptEntry?
        switch toolName {
        case Self.askUserQuestionToolName:
            parsed = Self.parseAskUserQuestion(
                toolInputJSON: toolInputJSON,
                toolUseID: toolUseID,
                runtimeTabID: runtimeTabID,
                sessionID: sessionID,
                createdAt: now()
            )
        case Self.exitPlanModeToolName:
            parsed = Self.parseExitPlanMode(
                toolInputJSON: toolInputJSON,
                toolUseID: toolUseID,
                runtimeTabID: runtimeTabID,
                sessionID: sessionID,
                createdAt: now()
            )
        default:
            parsed = nil
        }
        guard let entry = parsed else { return false }
        let key = Key(runtimeTabID: runtimeTabID, sessionID: sessionID)
        guard entries[key] != entry else { return false }
        entries[key] = entry
        return true
    }

    /// PostToolUse / PostToolUseFailure — authoritative clear: the tool
    /// finishing means the question was answered, from whichever surface.
    /// Scoped to the entry's own tool so one interactive tool completing
    /// never clears another's still-visible prompt.
    @discardableResult
    public func applyToolEnd(toolName: String, sessionID: String) -> Bool {
        purgeExpired()
        guard Self.interactiveToolNames.contains(toolName) else { return false }
        return removeAll { $0.sessionID == sessionID && $0.toolName == toolName }
    }

    /// Stop / StopFailure / SessionEnd — the turn or session is over, so no
    /// question can still be blocking it.
    @discardableResult
    public func applySessionTerminal(sessionID: String) -> Bool {
        purgeExpired()
        return removeAll { $0.sessionID == sessionID }
    }

    // MARK: - Reads

    public func entry(forRuntimeTabID runtimeTabID: UUID) -> StructuredPromptEntry? {
        purgeExpired()
        return entries.values
            .filter { $0.runtimeTabID == runtimeTabID }
            .max { $0.createdAt < $1.createdAt }
    }

    public var isEmpty: Bool {
        purgeExpired()
        return entries.isEmpty
    }

    // MARK: - Internals

    private func purgeExpired() {
        let cutoff = now().addingTimeInterval(-ttl)
        entries = entries.filter { $0.value.createdAt > cutoff }
    }

    @discardableResult
    private func removeAll(where predicate: (StructuredPromptEntry) -> Bool) -> Bool {
        let before = entries.count
        entries = entries.filter { !predicate($0.value) }
        return entries.count != before
    }

    /// Parses Claude Code's AskUserQuestion tool_input:
    /// `{"questions":[{"question","header","options":[{"label",...}],"multiSelect"}]}`.
    /// Returns nil for anything but a well-formed single-question payload
    /// with ≥2 labeled options.
    static func parseAskUserQuestion(
        toolInputJSON: String?,
        toolUseID: String,
        runtimeTabID: UUID,
        sessionID: String,
        createdAt: Date
    ) -> StructuredPromptEntry? {
        guard let toolInputJSON,
              let data = toolInputJSON.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let questions = root["questions"] as? [[String: Any]],
              questions.count == 1,
              let question = questions.first,
              let questionText = (question["question"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !questionText.isEmpty,
              let rawOptions = question["options"] as? [[String: Any]] else {
            return nil
        }

        let labels = rawOptions.compactMap { option in
            (option["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard labels.count >= 2, labels.count == rawOptions.count else { return nil }

        let multiSelect = question["multiSelect"] as? Bool ?? false
        let options = labels.enumerated().map { index, label -> RemoteInteractivePromptOption in
            let digit = "\(index + 1)"
            // Single-select: digit only — digits activate directly in Claude
            // Code, and a trailing Enter would arrive as a separate delayed
            // keypress landing on whatever renders next. Multi-select: the
            // digit toggles, so Enter is required to submit ("answer with
            // exactly this option").
            return RemoteInteractivePromptOption(
                id: digit,
                label: label,
                response: multiSelect ? digit + "\r" : digit,
                isDestructive: InteractivePromptDetector.isDestructiveLabel(label)
            )
        }

        let header = (question["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var detailParts: [String] = []
        if let header, !header.isEmpty {
            detailParts.append(header)
        }
        if multiSelect {
            detailParts.append("Multi-select on the Mac; tapping an option here picks exactly that option.")
        }

        let signatureBasis = ([sessionID, toolUseID, questionText] + labels).joined(separator: "\n")
        let signature = Data(SHA256.hash(data: Data(signatureBasis.utf8)).prefix(12)).base64EncodedString()

        return StructuredPromptEntry(
            runtimeTabID: runtimeTabID,
            sessionID: sessionID,
            toolUseID: toolUseID,
            toolName: askUserQuestionToolName,
            prompt: questionText,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: "\n"),
            options: options,
            createdAt: createdAt,
            signature: signature
        )
    }

    /// Parses ExitPlanMode's tool_input: `{"plan": "<markdown>"}`. The menu
    /// labels the TUI renders for plan approval are NOT part of tool_input
    /// and change across Claude versions, so no options are synthesized —
    /// the entry drives the waiting-status projection (and its push) while
    /// the scrape supplies the card with the real on-screen choices.
    static func parseExitPlanMode(
        toolInputJSON: String?,
        toolUseID: String,
        runtimeTabID: UUID,
        sessionID: String,
        createdAt: Date
    ) -> StructuredPromptEntry? {
        guard let toolInputJSON,
              let data = toolInputJSON.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = (root["plan"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else {
            return nil
        }

        var excerpt = plan
        if excerpt.count > maxPlanExcerptLength {
            excerpt = String(excerpt.prefix(maxPlanExcerptLength)) + "…"
        }

        let signatureBasis = [sessionID, toolUseID, exitPlanModeToolName].joined(separator: "\n")
        let signature = Data(SHA256.hash(data: Data(signatureBasis.utf8)).prefix(12)).base64EncodedString()

        return StructuredPromptEntry(
            runtimeTabID: runtimeTabID,
            sessionID: sessionID,
            toolUseID: toolUseID,
            toolName: exitPlanModeToolName,
            prompt: "Claude finished a plan and is waiting for review",
            detail: excerpt,
            options: [],
            createdAt: createdAt,
            signature: signature
        )
    }
}
