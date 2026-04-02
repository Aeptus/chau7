import Foundation
import Chau7Core

// MARK: - Command Block Manager

/// Manages command blocks across all terminal tabs.
/// Tracks active and completed command executions with their line ranges,
/// timing, and exit status for visual grouping in the terminal overlay.
@MainActor
@Observable
final class CommandBlockManager {
    static let shared = CommandBlockManager()

    /// Maximum number of blocks retained per tab
    static let maxBlocksPerTab = 200

    /// Blocks indexed by tab ID, ordered oldest-first
    private(set) var blocksByTab: [String: [CommandBlock]] = [:]

    private init() {
        Log.info("CommandBlockManager initialized")
    }

    // MARK: - Command Lifecycle

    /// Records the start of a new command execution in a tab.
    /// - Parameters:
    ///   - tabID: The identifier of the terminal tab
    ///   - command: The command text being executed
    ///   - line: The terminal line number where the command starts
    ///   - directory: The working directory at the time of execution
    func commandStarted(tabID: String, command: String, line: Int, directory: String?) {
        let block = CommandBlock(
            command: command,
            startLine: line,
            startTime: Date(),
            directory: directory
        )

        if blocksByTab[tabID] == nil {
            blocksByTab[tabID] = []
        }
        blocksByTab[tabID]?.append(block)

        // Trim oldest blocks if over capacity
        trimBlocksIfNeeded(tabID: tabID)

        Log.trace("CommandBlock started: '\(command)' at line \(line) in tab \(tabID)")
    }

    /// Records the completion of a command execution in a tab.
    /// Matches the most recent running block for the given tab.
    /// - Parameters:
    ///   - tabID: The identifier of the terminal tab
    ///   - line: The terminal line number where the command output ends
    ///   - exitCode: The exit code of the completed command
    func commandFinished(tabID: String, line: Int, exitCode: Int) {
        guard var blocks = blocksByTab[tabID] else {
            Log.warn("CommandBlock finish called for unknown tab: \(tabID)")
            return
        }

        // Find the last running block (most recent command without an end line)
        guard let index = blocks.lastIndex(where: { $0.isRunning }) else {
            Log.warn("CommandBlock finish called but no running block in tab: \(tabID)")
            return
        }

        blocks[index].endLine = line
        blocks[index].endTime = Date()
        blocks[index].exitCode = exitCode
        blocksByTab[tabID] = blocks

        let block = blocks[index]
        let durationStr = block.durationString
        Log.info("CommandBlock finished: '\(block.command)' exit=\(exitCode) duration=\(durationStr) in tab \(tabID)")
    }

    /// Attach the list of changed files to the most recently finished block in a tab.
    func setChangedFiles(_ files: [String], forLastBlockIn tabID: String) {
        guard var blocks = blocksByTab[tabID],
              let index = blocks.lastIndex(where: { !$0.isRunning }) else { return }
        blocks[index].changedFiles = files
        blocksByTab[tabID] = blocks
        Log.info("CommandBlock: \(files.count) files changed in '\(blocks[index].command.prefix(40))' (tab \(tabID.prefix(8)))")
    }

    /// Returns changed files from the most recent finished block in a tab.
    func lastChangedFiles(tabID: String) -> [String] {
        guard let blocks = blocksByTab[tabID],
              let last = blocks.last(where: { !$0.isRunning && !$0.changedFiles.isEmpty }) else { return [] }
        return last.changedFiles
    }

    // MARK: - Queries

    /// Returns all blocks for a given tab, ordered oldest-first.
    /// - Parameter tabID: The identifier of the terminal tab
    /// - Returns: Array of command blocks, or empty array if no blocks exist
    func blocksForTab(_ tabID: String) -> [CommandBlock] {
        blocksByTab[tabID] ?? []
    }

    /// Finds the command block that contains the given terminal line.
    /// - Parameters:
    ///   - line: The terminal line number to search for
    ///   - tabID: The identifier of the terminal tab
    /// - Returns: The containing block, or nil if no block spans that line
    func blockContaining(line: Int, tabID: String) -> CommandBlock? {
        guard let blocks = blocksByTab[tabID] else { return nil }

        for block in blocks {
            if line < block.startLine { continue }

            if let endLine = block.endLine {
                if line <= endLine {
                    return block
                }
            } else {
                // Block is still running; it contains all lines from startLine onward
                return block
            }
        }

        return nil
    }

    // MARK: - Cleanup

    /// Removes all blocks for a given tab.
    /// - Parameter tabID: The identifier of the terminal tab
    func clearBlocks(tabID: String) {
        let count = blocksByTab[tabID]?.count ?? 0
        blocksByTab.removeValue(forKey: tabID)
        Log.info("CommandBlockManager cleared \(count) blocks for tab \(tabID)")
    }

    // MARK: - Internal

    /// Trims oldest blocks when a tab exceeds the maximum capacity.
    private func trimBlocksIfNeeded(tabID: String) {
        guard var blocks = blocksByTab[tabID] else { return }
        let excess = blocks.count - Self.maxBlocksPerTab
        guard excess > 0 else { return }

        blocks.removeFirst(excess)
        blocksByTab[tabID] = blocks
        Log.trace("CommandBlockManager trimmed \(excess) oldest blocks for tab \(tabID)")
    }
}
