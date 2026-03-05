import Foundation

/// Pure parsing and matching helpers for AI session resume.
///
/// Extracted from `TerminalSessionModel` and `OverlayTabsModel` so the
/// logic can be unit-tested via `Chau7Core` without app dependencies.
public enum AIResumeParser {

    public struct ResumeMetadata: Equatable {
        public let provider: String
        public let sessionId: String

        public init(provider: String, sessionId: String) {
            self.provider = provider
            self.sessionId = sessionId
        }
    }

    /// Extracts AI resume metadata from a command line like
    /// `claude --resume abc123` or `codex resume xyz`.
    public static func extractMetadata(from commandLine: String) -> ResumeMetadata? {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = CommandDetection.tokenize(trimmed)
        guard tokens.count >= 3 else { return nil }
        let normalizedTokens = tokens.map { CommandDetection.normalizeToken($0).lowercased() }

        guard let first = normalizedTokens.first else { return nil }
        switch first {
        case "claude":
            if normalizedTokens[1] == "--resume",
               isValidSessionId(normalizedTokens[2]) {
                return ResumeMetadata(provider: "claude", sessionId: normalizedTokens[2])
            }
        case "codex":
            if normalizedTokens[1] == "resume",
               isValidSessionId(normalizedTokens[2]) {
                return ResumeMetadata(provider: "codex", sessionId: normalizedTokens[2])
            }
        default:
            break
        }
        return nil
    }

    /// Detects an AI provider name from a command line.
    /// Unlike `extractMetadata`, this doesn't require a resume flag — it just
    /// identifies whether the command invokes a known AI tool.
    public static func detectProvider(from commandLine: String) -> String? {
        guard let appName = CommandDetection.detectApp(from: commandLine) else { return nil }
        return normalizeProviderName(appName)
    }

    /// Normalizes a known app name to a canonical provider key.
    public static func normalizeProviderName(_ value: String) -> String? {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("claude") { return "claude" }
        if lowered.contains("codex") { return "codex" }
        return nil
    }

    /// Validates that a string looks like a plausible session ID
    /// (non-empty, alphanumeric with hyphens/underscores).
    public static func isValidSessionId(_ sessionId: String) -> Bool {
        !sessionId.isEmpty && sessionId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Picks the best session match from multiple candidates using temporal proximity.
    ///
    /// When multiple AI sessions match the same directory, we use `referenceDate`
    /// (typically the terminal's last output time) to find the session whose file
    /// modification time is closest — correlating terminal activity with session activity.
    ///
    /// - Parameters:
    ///   - candidates: Session IDs paired with their file modification dates
    ///   - referenceDate: The terminal's last output time, if available
    /// - Returns: The best-matching session ID, or nil if ambiguous without a reference
    public static func bestSessionMatch(
        candidates: [(sessionId: String, touchedAt: Date)],
        referenceDate: Date?
    ) -> String? {
        if candidates.isEmpty { return nil }
        if candidates.count == 1 { return candidates[0].sessionId }

        guard let referenceDate,
              isUsableReferenceDate(referenceDate) else {
            // Multiple candidates, no way to disambiguate — refuse to guess
            return nil
        }

        let sorted = candidates.sorted {
            let leftDistance = abs($0.touchedAt.timeIntervalSince(referenceDate))
            let rightDistance = abs($1.touchedAt.timeIntervalSince(referenceDate))
            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }
            return $0.touchedAt > $1.touchedAt
        }
        return sorted.first?.sessionId
    }

    private static func isUsableReferenceDate(_ referenceDate: Date) -> Bool {
        let now = Date()
        return referenceDate != .distantPast &&
            referenceDate <= now.addingTimeInterval(60) &&
            referenceDate > .distantPast
    }
}
