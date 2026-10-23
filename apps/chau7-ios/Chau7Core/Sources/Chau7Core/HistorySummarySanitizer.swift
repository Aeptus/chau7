import Foundation

/// Sanitizes upstream history summaries before they are logged or stored.
///
/// Some providers occasionally emit truncated fragments such as `rror` instead of
/// `Error`. Those fragments are not useful in the UI or logs, so we drop them
/// unless the entry is an explicit exit marker.
public enum HistorySummarySanitizer {
    public static func sanitize(_ summary: String, isExit: Bool) -> String {
        let sanitized = EscapeSequenceSanitizer.sanitizeForLogging(summary)
        guard !isExit, !sanitized.isEmpty, sanitized.count <= 4 else {
            return sanitized
        }
        return ""
    }
}
