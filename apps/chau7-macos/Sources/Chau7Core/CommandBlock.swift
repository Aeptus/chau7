import Foundation

// MARK: - Command Block Data Model

public enum CommandBlockChangedFilesStatus: String, Codable, Sendable {
    case loading
    case loaded
    case failed
    case notGitRepo
}

/// Represents a single command execution block in the terminal.
/// Tracks the command text, line range, timing, and exit status.
/// Placed in Chau7Core for testability without AppKit dependencies.
public struct CommandBlock: Identifiable, Codable, Equatable, Sendable {
    public static let syntheticTimeoutExitCode = -1001

    public let id: UUID
    public let command: String
    public let startLine: Int
    public var endLine: Int?
    public let startTime: Date
    public var endTime: Date?
    public var exitCode: Int?
    public var directory: String?
    public var turnID: String?

    /// Files changed during this command execution (populated via git diff snapshot).
    /// Empty if not a git repo, or if the command hasn't finished yet.
    public var changedFiles: [String] = []
    /// Whether change detection completed but could not determine the diff reliably.
    public var changedFilesUnavailable = false
    public var changedFilesStatus: CommandBlockChangedFilesStatus = .loading

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
        directory: String? = nil,
        turnID: String? = nil,
        changedFiles: [String] = [],
        changedFilesUnavailable: Bool = false,
        changedFilesStatus: CommandBlockChangedFilesStatus = .loading
    ) {
        self.id = id
        self.command = command
        self.startLine = startLine
        self.endLine = endLine
        self.startTime = startTime
        self.endTime = endTime
        self.exitCode = exitCode
        self.directory = directory
        self.turnID = turnID
        self.changedFiles = changedFiles
        self.changedFilesUnavailable = changedFilesUnavailable
        self.changedFilesStatus = changedFilesStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case startLine
        case endLine
        case startTime
        case endTime
        case exitCode
        case directory
        case turnID
        case changedFiles
        case changedFilesUnavailable
        case changedFilesStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.command = try container.decode(String.self, forKey: .command)
        self.startLine = try container.decode(Int.self, forKey: .startLine)
        self.endLine = try container.decodeIfPresent(Int.self, forKey: .endLine)
        self.startTime = try container.decode(Date.self, forKey: .startTime)
        self.endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        self.exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        self.directory = try container.decodeIfPresent(String.self, forKey: .directory)
        self.turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        self.changedFiles = try container.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
        self.changedFilesUnavailable = try container.decodeIfPresent(Bool.self, forKey: .changedFilesUnavailable) ?? false
        if let decodedStatus = try container.decodeIfPresent(CommandBlockChangedFilesStatus.self, forKey: .changedFilesStatus) {
            self.changedFilesStatus = decodedStatus
        } else if changedFilesUnavailable {
            self.changedFilesStatus = .failed
        } else if endLine != nil || endTime != nil {
            self.changedFilesStatus = .loaded
        } else {
            self.changedFilesStatus = .loading
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(command, forKey: .command)
        try container.encode(startLine, forKey: .startLine)
        try container.encodeIfPresent(endLine, forKey: .endLine)
        try container.encode(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(directory, forKey: .directory)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(changedFiles, forKey: .changedFiles)
        try container.encode(changedFilesUnavailable, forKey: .changedFilesUnavailable)
        try container.encode(changedFilesStatus, forKey: .changedFilesStatus)
    }
}
