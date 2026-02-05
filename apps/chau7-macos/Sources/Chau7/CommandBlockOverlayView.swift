import SwiftUI
import Chau7Core

// MARK: - Command Block Overlay View

/// A SwiftUI overlay that renders visual gutter marks for command blocks.
/// Displays a colored left-border for each command block:
/// - Green for success (exit 0)
/// - Red for failure (non-zero exit)
/// - Blue for currently running
/// Supports hover tooltips, click-to-scroll, and visual collapse/expand.
struct CommandBlockOverlayView: View {
    @ObservedObject var manager: CommandBlockManager
    let tabID: String
    let visibleRowRange: Range<Int>
    let rowHeight: CGFloat
    let scrollToLine: ((Int) -> Void)?

    /// Tracks which blocks are visually collapsed
    @State private var collapsedBlockIDs: Set<UUID> = []

    /// Currently hovered block for tooltip display
    @State private var hoveredBlock: CommandBlock?

    /// Gutter width for the left-border marks
    private let gutterWidth: CGFloat = 4

    var body: some View {
        let blocks = manager.blocksForTab(tabID)
        let visibleBlocks = blocks.filter { block in
            blockIsVisible(block, in: visibleRowRange)
        }

        ZStack(alignment: .topLeading) {
            // Render gutter marks for each visible block
            ForEach(visibleBlocks) { block in
                blockGutterMark(block: block)
            }
        }
        .frame(width: gutterWidth)
    }

    // MARK: - Block Gutter Mark

    private func blockGutterMark(block: CommandBlock) -> some View {
        let color = blockColor(for: block)
        let isCollapsed = collapsedBlockIDs.contains(block.id)
        let startRow = max(block.startLine, visibleRowRange.lowerBound)
        let endRow = block.endLine.map { min($0, visibleRowRange.upperBound - 1) }
            ?? (visibleRowRange.upperBound - 1)
        let topOffset = CGFloat(startRow - visibleRowRange.lowerBound) * rowHeight
        let height: CGFloat = isCollapsed
            ? rowHeight
            : CGFloat(endRow - startRow + 1) * rowHeight

        return Rectangle()
            .fill(color)
            .frame(width: gutterWidth, height: max(height, rowHeight))
            .offset(y: topOffset)
            .opacity(hoveredBlock?.id == block.id ? 1.0 : 0.6)
            .onHover { isHovering in
                hoveredBlock = isHovering ? block : nil
            }
            .onTapGesture {
                handleBlockTap(block: block)
            }
            .help(tooltipText(for: block))
            .accessibilityLabel(accessibilityLabel(for: block))
    }

    // MARK: - Block Color

    /// Returns the gutter color based on block status.
    private func blockColor(for block: CommandBlock) -> Color {
        if block.isRunning {
            return .blue
        } else if block.isSuccess {
            return .green
        } else if block.isFailed {
            return .red
        } else {
            // Completed but no exit code recorded
            return .gray
        }
    }

    // MARK: - Visibility Check

    /// Determines whether a block overlaps with the visible row range.
    private func blockIsVisible(_ block: CommandBlock, in range: Range<Int>) -> Bool {
        let blockEnd = block.endLine ?? Int.max
        return block.startLine < range.upperBound && blockEnd >= range.lowerBound
    }

    // MARK: - Interaction

    /// Handles tap on a block gutter mark.
    /// Toggles collapse state or scrolls to block boundaries.
    private func handleBlockTap(block: CommandBlock) {
        if collapsedBlockIDs.contains(block.id) {
            collapsedBlockIDs.remove(block.id)
        } else if block.endLine != nil {
            collapsedBlockIDs.insert(block.id)
        }

        // Scroll to block start
        scrollToLine?(block.startLine)
    }

    // MARK: - Tooltip

    /// Generates tooltip text for a command block.
    private func tooltipText(for block: CommandBlock) -> String {
        var parts: [String] = []
        parts.append(block.command)

        if let dir = block.directory {
            parts.append("Dir: " + dir)
        }

        if block.isRunning {
            parts.append("Status: Running")
        } else if let code = block.exitCode {
            parts.append("Exit: " + String(code))
        }

        let dur = block.durationString
        if !dur.isEmpty {
            parts.append("Duration: " + dur)
        }

        if let lines = block.lineCount {
            parts.append("Lines: " + String(lines))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Accessibility

    /// Generates an accessibility label for a command block.
    private func accessibilityLabel(for block: CommandBlock) -> String {
        let status: String
        if block.isRunning {
            status = "running"
        } else if block.isSuccess {
            status = "succeeded"
        } else if block.isFailed {
            status = "failed with exit code " + String(block.exitCode ?? -1)
        } else {
            status = "completed"
        }
        return "Command block: " + block.command + ", " + status
    }
}
