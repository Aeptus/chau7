import Foundation

/// Resolves additional routing context for history-monitor events.
///
/// History entries only carry a tool name and session ID. To route notifications
/// to the correct tab, the app needs a working directory hint when available.
/// This helper keeps the provider-to-session-metadata lookup logic pure and testable.
public enum HistoryEventContextResolver {
    public static func directory(
        forToolName toolName: String,
        sessionID: String?,
        claudeDirectoryProvider: (String) -> String?,
        codexDirectoryProvider: (String) -> String?
    ) -> String? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              AIResumeParser.isValidSessionId(sessionID),
              let provider = AIResumeParser.normalizeProviderName(toolName) else {
            return nil
        }

        switch provider {
        case "claude":
            return claudeDirectoryProvider(sessionID)
        case "codex":
            return codexDirectoryProvider(sessionID)
        default:
            return nil
        }
    }
}
