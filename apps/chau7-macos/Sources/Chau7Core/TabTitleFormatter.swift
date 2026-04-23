import Foundation

/// Resolves the displayed title for a tab's chrome (tab bar chip, status
/// bar menu, accessibility label).
///
/// Input priority when `customTitleOnly` is false:
///   1. `customTitle` — user-renamed or MCP-set
///   2. `<aiDisplayAppName> - <customTitle>` — composed when both present
///   3. `aiDisplayAppName` — detected AI tool (Codex, Claude, …)
///   4. `devServerName` — limited to Vite (case-insensitive)
///   5. `shellFallback` — localized "Shell" by default
///
/// Notably absent: `TerminalSessionModel.title`, which is populated from
/// the shell's OSC 0/1/2 escape sequence. That value is deliberately
/// excluded from tab chrome because it is shell-controlled — an
/// untrusted process could spoof arbitrary titles. Notifications have
/// their own resolver (`TerminalSessionModel.notificationTabName`) that
/// DOES use `session.title` as its final fallback, because there the
/// source is already trust-bounded to the target tab's own session.
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
