import Foundation

// MARK: - Shared Formatters (Code Optimization)
// Consolidates DateFormatter instances to avoid repeated initialization

enum Formatters {
    /// Short time format (e.g., "3:45 PM")
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Medium time format (e.g., "3:45:30 PM")
    static let mediumTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    /// Terminal login timestamp (e.g., "Mon Jan 12 14:30:00")
    static let terminalLogin: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss"
        return f
    }()

    /// Log timestamp with date and time (e.g., "2024-01-12 14:30:00")
    static let logTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// ISO8601 formatter for machine-readable timestamps
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    /// Time with milliseconds for debug logs (e.g., "14:30:00.123")
    static let debugTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
