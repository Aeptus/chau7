import Foundation

/// Tracks a single tool's usage during a turn.
public struct ToolTally: Codable, Sendable {
    public let name: String
    public internal(set) var count: Int
    public internal(set) var files: [String]   // deduplicated paths

    public init(name: String, count: Int = 0, files: [String] = []) {
        self.name = name
        self.count = count
        self.files = files
    }
}

/// Accumulates tool calls and token usage during a single agent turn.
///
/// Pure value type in Chau7Core — no app dependencies, fully testable.
/// The `summary()` method returns a flat `[String: String]` dict that maps
/// directly into `RuntimeEvent.data` for the `turn_completed` event.
public struct TurnStats: Codable, Sendable {
    public private(set) var toolTallies: [String: ToolTally] = [:]
    public private(set) var inputTokens: Int = 0
    public private(set) var outputTokens: Int = 0
    public private(set) var cacheCreationTokens: Int = 0
    public private(set) var cacheReadTokens: Int = 0

    public var totalTokens: Int { inputTokens + outputTokens }

    public init() {}

    /// Record a tool invocation, optionally with a file path.
    public mutating func recordToolUse(name: String, file: String?) {
        var tally = toolTallies[name] ?? ToolTally(name: name)
        tally.count += 1
        if let file, !file.isEmpty, !tally.files.contains(file) {
            tally.files.append(file)
        }
        toolTallies[name] = tally
    }

    /// Add token counts (cumulative — call once per API response chunk).
    public mutating func addTokens(input: Int, output: Int, cacheCreation: Int, cacheRead: Int) {
        inputTokens += input
        outputTokens += output
        cacheCreationTokens += cacheCreation
        cacheReadTokens += cacheRead
    }

    /// Flat dictionary suitable for `RuntimeEvent.data`.
    public func summary() -> [String: String] {
        let allFiles = toolTallies.values.flatMap(\.files)
        let uniqueFiles = Set(allFiles)
        let toolNames = toolTallies.keys.sorted().joined(separator: ",")
        let totalCalls = toolTallies.values.reduce(0) { $0 + $1.count }

        return [
            "tool_count": "\(totalCalls)",
            "tools_used": toolNames,
            "input_tokens": "\(inputTokens)",
            "output_tokens": "\(outputTokens)",
            "cache_creation_tokens": "\(cacheCreationTokens)",
            "cache_read_tokens": "\(cacheReadTokens)",
            "total_tokens": "\(totalTokens)",
            "files_touched": "\(uniqueFiles.count)"
        ]
    }
}
