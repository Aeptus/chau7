import Foundation

// MARK: - Shared Date Formatter

enum DateFormatters {
    /// Shared ISO8601 formatter with fractional seconds.
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Formats current date as ISO8601 string.
    static func nowISO8601() -> String {
        iso8601.string(from: Date())
    }
}

// MARK: - Array Extensions

extension Array {
    /// Trims the array to keep only the last `count` elements.
    /// More efficient than removeFirst() for large removals.
    mutating func trimToLast(_ count: Int) {
        guard self.count > count else { return }
        removeFirst(self.count - count)
    }
}

// MARK: - Environment Variables

/// Centralized environment variable names for the app.
/// Standardized on CHAU7_ prefix for consistency.
enum EnvVars {
    // Logging
    static let logFile = "CHAU7_LOG_FILE"
    static let logMaxBytes = "CHAU7_LOG_MAX_BYTES"
    static let verbose = "CHAU7_VERBOSE"
    static let trace = "CHAU7_TRACE"

    // Event monitoring
    static let eventsLog = "CHAU7_EVENTS_LOG"

    // History monitoring
    static let codexHistoryLog = "CHAU7_CODEX_HISTORY_LOG"
    static let claudeHistoryLog = "CHAU7_CLAUDE_HISTORY_LOG"
    static let idleStaleSeconds = "CHAU7_IDLE_STALE_SECONDS"

    // Terminal monitoring
    static let codexTerminalLog = "CHAU7_CODEX_TERMINAL_LOG"
    static let claudeTerminalLog = "CHAU7_CLAUDE_TERMINAL_LOG"
    static let terminalNormalize = "CHAU7_TERMINAL_NORMALIZE"
    static let terminalAnsi = "CHAU7_TERMINAL_ANSI"

    // Terminal session
    static let idleSeconds = "CHAU7_IDLE_SECONDS"
    static let commandFallbackSeconds = "CHAU7_COMMAND_FALLBACK_SECONDS"
    static let clearOnLaunch = "CHAU7_CLEAR_ON_LAUNCH"

    // Debug output capture
    static let ptyDumpMaxBytes = "CHAU7_PTY_DUMP_MAX_BYTES"
    static let remoteOutputBatch = "CHAU7_REMOTE_OUTPUT_BATCH"

    // Legacy env var support (for backwards compatibility)
    static let legacyEventsLog = "AI_EVENTS_LOG"
    static let legacyCodexHistoryLog = "AI_CODEX_HISTORY_LOG"
    static let legacyClaudeHistoryLog = "AI_CLAUDE_HISTORY_LOG"
    static let legacyStaleSeconds = "AI_IDLE_STALE_SECONDS"
    static let legacyCodexTerminalLog = "AI_CODEX_TTY_LOG"
    static let legacyClaudeTerminalLog = "AI_CLAUDE_TTY_LOG"
    static let legacyTerminalNormalize = "AI_TTY_NORMALIZE"
    static let legacyTerminalAnsi = "AI_TTY_ANSI"
    static let legacyVerbose = "AI_NOTIFIER_VERBOSE"
    static let legacyTrace = "AI_NOTIFIER_TRACE"
    static let legacyLogFile = "AI_NOTIFIER_LOG_FILE"
    static let legacyIdleSeconds = "SMART_OVERLAY_IDLE_SECONDS"
    static let legacyCommandFallbackSeconds = "SMART_OVERLAY_COMMAND_FALLBACK_SECONDS"
    static let legacyClearOnLaunch = "SMART_OVERLAY_CLEAR_ON_LAUNCH"

    /// Gets an environment variable, trying new name first then legacy.
    static func get(_ newName: String, legacy: String? = nil) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let value = env[newName], !value.isEmpty {
            return value
        }
        if let legacy, let value = env[legacy], !value.isEmpty {
            return value
        }
        return nil
    }
}
