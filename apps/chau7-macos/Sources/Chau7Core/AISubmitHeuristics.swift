import Foundation

public struct AISubmitSnapshot: Equatable, Sendable {
    public let toolName: String
    public let status: String
    public let isAtPrompt: Bool
    public let transcript: String

    public init(toolName: String, status: String, isAtPrompt: Bool, transcript: String) {
        self.toolName = toolName
        self.status = status
        self.isAtPrompt = isAtPrompt
        self.transcript = transcript
    }
}

public enum AISubmitHeuristics {
    public static func shouldObserveAfterFirstEnter(_ snapshot: AISubmitSnapshot) -> Bool {
        supports(toolName: snapshot.toolName) && (
            draftedPromptLine(in: snapshot.transcript) != nil
                || InteractivePromptDetector.detect(in: snapshot.transcript, toolName: snapshot.toolName) != nil
                || snapshot.isAtPrompt
        )
    }

    public static func workStarted(initial: AISubmitSnapshot, current: AISubmitSnapshot) -> Bool {
        if !current.isAtPrompt {
            return true
        }

        if responseStartedMarker(in: current.transcript) {
            return true
        }

        let initialDraft = draftedPromptLine(in: initial.transcript)
        let currentDraft = draftedPromptLine(in: current.transcript)
        if initialDraft != nil, currentDraft == nil,
           InteractivePromptDetector.detect(in: current.transcript, toolName: current.toolName) == nil {
            return true
        }

        return false
    }

    public static func shouldSendSecondEnter(initial: AISubmitSnapshot, current: AISubmitSnapshot) -> Bool {
        guard supports(toolName: initial.toolName), !workStarted(initial: initial, current: current) else {
            return false
        }

        guard current.isAtPrompt else { return false }

        let initialDraft = draftedPromptLine(in: initial.transcript)
        let currentDraft = draftedPromptLine(in: current.transcript)
        let hadInteractivePrompt = InteractivePromptDetector.detect(in: initial.transcript, toolName: initial.toolName) != nil
        let hasInteractivePromptNow = InteractivePromptDetector.detect(in: current.transcript, toolName: current.toolName) != nil

        if let initialDraft, currentDraft == initialDraft {
            return true
        }

        if hadInteractivePrompt, !hasInteractivePromptNow, currentDraft != nil {
            return true
        }

        return false
    }

    public static func draftedPromptLine(in transcript: String) -> String? {
        let lines = normalize(transcript)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() {
            guard line.hasPrefix("› ") || line.hasPrefix("> ") || line.hasPrefix("❯ ") else {
                continue
            }

            let content = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty {
                continue
            }

            if content.hasPrefix("Working")
                || content.lowercased().contains("esc to interrupt")
                || content.hasPrefix("1.")
                || content.hasPrefix("2.") {
                continue
            }

            return content
        }

        return nil
    }

    private static func responseStartedMarker(in transcript: String) -> Bool {
        let normalized = normalize(transcript).lowercased()
        return normalized.contains("working...")
            || normalized.contains("esc to interrupt")
            || normalized.contains("__chau7_review_json_begin__")
    }

    private static func supports(toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("codex") || normalized.contains("claude")
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
