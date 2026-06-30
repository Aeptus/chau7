import Foundation

// MARK: - Centralized Application Constants (Code Optimization)

// All magic numbers and configuration values in one place

enum AppConstants {

    // MARK: - Buffer & Collection Limits

    enum Limits {
        /// Maximum log lines to keep in memory
        static let maxLogLines = 300

        /// Maximum history entries per stream
        static let maxHistoryEntries = 200

        /// Maximum terminal lines to display
        static let maxTerminalLines = 250

        /// Terminal lines to prefill on startup
        static let terminalPrefillLines = 200

        /// Maximum closed sessions to track before cleanup
        static let maxClosedSessions = 100

        /// Maximum font cache entries
        static let maxFontCacheSize = 10
    }

    // MARK: - Time Intervals

    enum Intervals {
        /// Clipboard poll interval when app is frontmost (seconds)
        static let clipboardPoll: TimeInterval = 1.0

        /// Clipboard poll interval when app is in the background (seconds)
        static let clipboardPollBackground: TimeInterval = 5.0
    }

    // MARK: - Networking

    enum Network {
        /// Default port for the API analytics proxy
        static let defaultProxyPort = 18080
    }
}
