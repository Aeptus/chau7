import Foundation

public enum TabTitleFormatter {
    public static func resolvedTitle(
        customTitle: String?,
        aiDisplayAppName: String?,
        devServerName: String?,
        customTitleOnly: Bool,
        shellFallback: String = "Shell"
    ) -> String {
        let custom = trimmedNonEmpty(customTitle)
        let aiName = trimmedNonEmpty(aiDisplayAppName)

        if let custom {
            if customTitleOnly {
                return custom
            }
            if let aiName {
                // Skip the "<aiName> - " prefix if the custom title already
                // contains aiName as a *word* (not just a substring). The
                // previous `.range(of:)` substring check would incorrectly
                // match e.g. aiName="Co" against custom="Command deploy",
                // or aiName="codex" against custom="Codexport", etc. Use
                // word-boundary regex matching so only whole-word
                // occurrences count. Case-insensitive; diacritics are
                // non-issue for real AI tool names (Codex/Claude/Gemini
                // are all ASCII).
                if containsAINameAsWord(in: custom, aiName: aiName) {
                    return custom
                }
                return "\(aiName) - \(custom)"
            }
            return custom
        }

        if let aiName {
            return aiName
        }

        if let devServerName = trimmedNonEmpty(devServerName),
           devServerName.compare("Vite", options: .caseInsensitive) == .orderedSame {
            return devServerName
        }

        return shellFallback
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func containsAINameAsWord(in custom: String, aiName: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: aiName)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            // Fallback to case-insensitive substring if the regex can't
            // compile for some reason. This is the pre-fix behavior, so
            // worst-case we preserve it rather than misbehave.
            return custom.range(of: aiName, options: [.caseInsensitive]) != nil
        }
        let range = NSRange(custom.startIndex..., in: custom)
        return regex.firstMatch(in: custom, options: [], range: range) != nil
    }
}
