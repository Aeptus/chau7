import Foundation

// MARK: - HistoryRecord

/// A persistent command history record with rich metadata.
///
/// Unlike `HistoryEntry` (which models real-time session events from JSON streams),
/// `HistoryRecord` represents a completed command stored in the SQLite database
/// with full context: working directory, exit code, shell type, duration, etc.
public struct HistoryRecord: Codable, Identifiable, Equatable, Sendable {
    /// SQLite row ID. `nil` for records not yet inserted.
    public let id: Int64?
    /// The command string that was executed.
    public let command: String
    /// Working directory when the command was run.
    public let directory: String?
    /// Process exit code (0 = success).
    public let exitCode: Int?
    /// Shell that ran the command (e.g. "zsh", "bash", "fish").
    public let shell: String?
    /// Identifier of the tab where the command was executed.
    public let tabID: String?
    /// Session identifier grouping commands from a single app launch.
    public let sessionID: String?
    /// When the command was executed.
    public let timestamp: Date
    /// How long the command took to complete, in seconds.
    public let duration: TimeInterval?

    public init(
        id: Int64? = nil,
        command: String,
        directory: String? = nil,
        exitCode: Int? = nil,
        shell: String? = nil,
        tabID: String? = nil,
        sessionID: String? = nil,
        timestamp: Date = Date(),
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.command = command
        self.directory = directory
        self.exitCode = exitCode
        self.shell = shell
        self.tabID = tabID
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.duration = duration
    }
}

// MARK: - FrequentCommand

/// Aggregated frequency data for a command, combining count and recency.
public struct FrequentCommand: Codable, Identifiable, Equatable, Sendable {
    public var id: String {
        command
    }

    /// The command string.
    public let command: String
    /// How many times the command has been executed.
    public let count: Int
    /// When the command was most recently executed.
    public let lastUsed: Date

    public init(command: String, count: Int, lastUsed: Date) {
        self.command = command
        self.count = count
        self.lastUsed = lastUsed
    }

    /// Frecency score combining frequency and recency.
    /// Higher scores indicate commands that are both frequently used and recently used.
    public var frecencyScore: Double {
        let ageHours = max(Date().timeIntervalSince(lastUsed) / 3600.0, 0.1)
        // Logarithmic decay: recent commands get a strong boost
        return Double(count) / log2(ageHours + 1.0)
    }
}
