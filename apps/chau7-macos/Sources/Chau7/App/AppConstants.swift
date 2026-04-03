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

        /// Maximum clipboard history items
        static let maxClipboardItems = 50

        /// Maximum bookmarks per tab
        static let maxBookmarksPerTab = 100

        /// Maximum file tailer buffer size (1MB)
        static let maxTailerBufferSize = 1024 * 1024

        /// Default scrollback lines
        static let defaultScrollbackLines = 10000

        /// Maximum font cache entries
        static let maxFontCacheSize = 10

        /// Maximum search matches to return
        static let maxSearchMatches = 400

        /// Maximum search preview lines
        static let maxSearchPreviewLines = 12
    }

    // MARK: - Time Intervals

    enum Intervals {
        /// Idle check interval (seconds)
        static let idleCheck: TimeInterval = 1.0

        /// Clipboard poll interval (seconds)
        static let clipboardPoll: TimeInterval = 1.0

        /// Session cleanup interval (seconds)
        static let sessionCleanup: TimeInterval = 60.0

        /// File tailer poll interval (milliseconds)
        static let tailerPollMs = 500

        /// Default idle timeout (seconds)
        static let defaultIdleTimeout: TimeInterval = 3.0

        /// Stale session timeout (seconds)
        static let staleSessionTimeout: TimeInterval = 300.0

        /// Partial line update throttle (seconds)
        static let partialLineThrottle: TimeInterval = 0.1

        /// Search debounce delay (seconds)
        static let searchDebounce: TimeInterval = 0.2

        /// Animation durations
        static let animationFast: TimeInterval = 0.15
        static let animationNormal: TimeInterval = 0.2
        static let animationSlow: TimeInterval = 0.3
    }

    // MARK: - UI Dimensions

    enum UI {
        /// Default font size
        static let defaultFontSize: CGFloat = 13

        /// Minimum font size
        static let minFontSize: CGFloat = 9

        /// Maximum font size
        static let maxFontSize: CGFloat = 22

        /// Tab bar height
        static let tabBarHeight: CGFloat = 32

        /// Minimum split pane ratio
        static let minSplitRatio: CGFloat = 0.1

        /// Maximum split pane ratio
        static let maxSplitRatio: CGFloat = 0.9
    }

    // MARK: - Networking

    enum Network {
        /// Default port for the API analytics proxy
        static let defaultProxyPort = 18080
    }

    // MARK: - Event Retention

    enum Retention {
        /// Days to keep history events
        static let historyDays = 7

        /// Cleanup interval (seconds) - 1 hour
        static let cleanupInterval: TimeInterval = 3600
    }
}
