import Foundation

/// Parser for tmux control mode output.
/// tmux control mode (tmux -CC) uses a line-based protocol where:
/// - Notifications start with %
/// - Output blocks are wrapped in %begin/%end or %error
/// - Commands are sent as plain text
///
/// Key notifications:
/// %begin <time> <num> <flags>
/// %end <time> <num> <flags>
/// %error <time> <num> <flags>
/// %session-changed $<id> <name>
/// %window-add @<id>
/// %window-close @<id>
/// %output %<pane_id> <data>
/// %layout-change @<window_id> <layout>
/// %exit [reason]
public enum TmuxNotification: Equatable, Sendable {
    case begin(Int, Int) // time, command number
    case end(Int, Int)
    case error(Int, Int, String)
    case sessionChanged(String, String) // id, name
    case windowAdd(String) // window id
    case windowClose(String)
    case output(String, String) // pane id, data
    case layoutChange(String, String) // window id, layout
    case exit(String?) // reason
    case unknown(String)
}

/// - Important: Not thread-safe. Use from a single thread or protect externally.
public final class TmuxControlParser: @unchecked Sendable {
    private var pendingBlock: (commandNumber: Int, lines: [String])?

    public init() {}

    /// Parse a single line from tmux control mode output
    public func parseLine(_ line: String) -> TmuxNotification {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard trimmed.hasPrefix("%") else {
            // Data line inside a block
            if pendingBlock != nil {
                pendingBlock?.lines.append(trimmed)
            }
            return .unknown(trimmed)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 3).map(String.init)
        guard let cmd = parts.first else { return .unknown(trimmed) }

        switch cmd {
        case "%begin":
            let time = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let num = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            pendingBlock = (num, [])
            return .begin(time, num)

        case "%end":
            let time = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let num = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            pendingBlock = nil
            return .end(time, num)

        case "%error":
            let time = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let num = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            let msg = parts.count > 3 ? parts[3] : ""
            pendingBlock = nil
            return .error(time, num, msg)

        case "%session-changed":
            let id = parts.count > 1 ? parts[1] : ""
            let name = parts.count > 2 ? parts[2] : ""
            return .sessionChanged(id, name)

        case "%window-add":
            return .windowAdd(parts.count > 1 ? parts[1] : "")

        case "%window-close":
            return .windowClose(parts.count > 1 ? parts[1] : "")

        case "%output":
            let paneID = parts.count > 1 ? parts[1] : ""
            let data = parts.count > 2 ? parts.dropFirst(2).joined(separator: " ") : ""
            return .output(paneID, data)

        case "%layout-change":
            let windowID = parts.count > 1 ? parts[1] : ""
            let layout = parts.count > 2 ? parts[2] : ""
            return .layoutChange(windowID, layout)

        case "%exit":
            return .exit(parts.count > 1 ? parts[1] : nil)

        default:
            return .unknown(trimmed)
        }
    }

    /// Get the accumulated block content (between %begin and %end)
    public var blockContent: [String]? {
        pendingBlock?.lines
    }
}
