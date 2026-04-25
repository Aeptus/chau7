import Foundation

/// Resolves the displayed title for a tab's chrome (tab bar chip, status
/// bar menu, accessibility label).
///
/// Input priority:
///   1. `customTitle` — user-renamed or MCP-set. **When set, it wins
///      unconditionally.** The AI tool name is *never* prefixed onto a
///      custom title; the tab chip's logo carries the tool identity
///      visually, so prepending "Codex - " would be redundant chrome.
///   2. `aiDisplayAppName` — detected AI tool (Codex, Claude, …) when no
///      custom title is set.
///   3. `devServerName` — limited to Vite (case-insensitive).
///   4. `shellFallback` — localized "Shell" by default.
///
/// The `customTitleOnly` parameter is retained for back-compatibility
/// with callers that pass it, but is no longer load-bearing for title
/// resolution: a non-empty custom title now always returns just the
/// custom title regardless of the setting. The `customTitleOnly` setting
/// continues to control the **chip's** minimal-display mode (hiding
/// icons / path / indicators) at the call sites that respect it; this
/// formatter only resolves text.
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
        customTitleOnly: Bool = false,
        shellFallback: String = "Shell"
    ) -> String {
        // `customTitleOnly` is no longer load-bearing here (kept in the
        // signature for back-compat with existing call sites that pass it).
        // The chip's minimal-display mode is handled in the chip view, not
        // in this text resolver.
        _ = customTitleOnly

        if let custom = trimmedNonEmpty(customTitle) {
            return custom
        }

        if let aiName = trimmedNonEmpty(aiDisplayAppName) {
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
}
