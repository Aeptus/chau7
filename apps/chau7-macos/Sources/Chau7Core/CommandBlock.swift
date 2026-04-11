import Foundation

// MARK: - Command Block Data Model

/// Represents a single command execution block in the terminal.
/// Tracks the command text, line range, timing, and exit status.
/// Placed in Chau7Core for testability without AppKit dependencies.
public struct CommandBlock: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let command: String
    public let startLine: Int
    public var endLine: Int?
    public let startTime: Date
    public var endTime: Date?
    public var exitCode: Int?
    public var directory: String?

    /// Files changed during this command execution (populated via git diff snapshot).
    /// Empty if not a git repo, or if the command hasn't finished yet.
    public var changedFiles: [String] = []
    /// Whether change detection completed but could not determine the diff reliably.
    public var changedFilesUnavailable: Bool = false

    /// Whether the command is still executing (neither end line nor end time recorded)
    public var isRunning: Bool {
        endLine == nil && endTime == nil
    }

    /// Whether the command completed successfully (exit code 0)
    public var isSuccess: Bool {
        exitCode == 0
    }

    /// Whether the command completed with a non-zero exit code
    public var isFailed: Bool {
        exitCode != nil && exitCode != 0
    }

    /// The wall-clock duration of the command, if it has finished
    public var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    /// Human-readable duration string
    public var durationString: String {
        guard let d = duration else { return "" }
        if d < 1 {
            return String(format: "%.0fms", d * 1000)
        } else if d < 60 {
            return String(format: "%.1fs", d)
        } else if d < 3600 {
            let mins = Int(d) / 60
            let secs = Int(d) % 60
            return "\(mins)m \(secs)s"
        } else {
            let hours = Int(d) / 3600
            let mins = (Int(d) % 3600) / 60
            return "\(hours)h \(mins)m"
        }
    }

    /// The number of terminal lines this block spans (nil if still running)
    public var lineCount: Int? {
        guard let end = endLine else { return nil }
        return end - startLine + 1
    }

    public init(
        id: UUID = UUID(),
        command: String,
        startLine: Int,
        endLine: Int? = nil,
        startTime: Date = Date(),
        endTime: Date? = nil,
        exitCode: Int? = nil,
        directory: String? = nil
    ) {
        self.id = id
        self.command = command
        self.startLine = startLine
        self.endLine = endLine
        self.startTime = startTime
        self.endTime = endTime
        self.exitCode = exitCode
        self.directory = directory
    }
}
