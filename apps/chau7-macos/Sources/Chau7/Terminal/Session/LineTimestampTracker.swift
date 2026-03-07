import Foundation
import AppKit

// MARK: - F19: Line Timestamps

/// Tracks timestamps for terminal output lines
final class LineTimestampTracker: ObservableObject {
    /// Maximum number of timestamps to track (matching scrollback buffer)
    private let maxEntries: Int

    /// Timestamps indexed by absolute row number
    @Published private(set) var timestamps: [Int: Date] = [:]

    /// Current line count (tracks where we are in the buffer)
    private var currentRow = 0

    /// Minimum row currently tracked (for O(1) pruning instead of O(n log n) sorting)
    private var minTrackedRow = 0

    /// Last update timestamp for batching
    private var lastUpdateTime: Date = .distantPast

    /// Formatter for displaying timestamps
    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = FeatureSettings.shared.timestampFormat
        return f
    }()

    init(maxEntries: Int = 10000) {
        self.maxEntries = maxEntries
        // Pre-allocate dictionary capacity
        timestamps.reserveCapacity(min(maxEntries, 1000))
    }

    // MARK: - Tracking

    /// Called when new output is received
    func recordOutput(data: Data) {
        guard FeatureSettings.shared.isLineTimestampsEnabled else { return }

        let now = Date()

        // Count newlines to determine how many new lines
        let newlineCount = data.filter { $0 == 0x0A }.count // \n

        if newlineCount > 0 {
            // Record timestamp for each new line
            for _ in 0 ..< newlineCount {
                currentRow += 1
                timestamps[currentRow] = now
            }

            // Prune old entries if exceeding max
            pruneIfNeeded()
        } else if now.timeIntervalSince(lastUpdateTime) > 0.1 {
            // Even without newlines, update current row timestamp for partial lines
            timestamps[currentRow] = now
        }

        lastUpdateTime = now
    }

    /// Called when terminal is cleared
    func reset() {
        timestamps.removeAll(keepingCapacity: true)
        currentRow = 0
        minTrackedRow = 0
    }

    /// Called when scrollback is cleared
    func clearScrollback() {
        timestamps.removeAll(keepingCapacity: true)
        currentRow = 0
        minTrackedRow = 0
    }

    /// Memory-optimized pruning: O(k) where k = excess entries, instead of O(n log n)
    /// Since rows are added sequentially, we can simply remove from minTrackedRow upward
    private func pruneIfNeeded() {
        let excess = timestamps.count - maxEntries
        guard excess > 0 else { return }

        // Remove oldest entries by incrementing minTrackedRow
        let targetMin = minTrackedRow + excess
        while minTrackedRow < targetMin {
            timestamps.removeValue(forKey: minTrackedRow)
            minTrackedRow += 1
        }
    }

    // MARK: - Display

    /// Gets formatted timestamp for a row, if available
    func formattedTimestamp(forRow row: Int) -> String? {
        guard let date = timestamps[row] else { return nil }
        return formatter.string(from: date)
    }

    /// Gets relative time string (e.g., "2s ago", "5m ago")
    func relativeTimestamp(forRow row: Int) -> String? {
        guard let date = timestamps[row] else { return nil }

        let interval = Date().timeIntervalSince(date)

        if interval < 1 {
            return "now"
        } else if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h"
        } else {
            return formatter.string(from: date)
        }
    }

    /// Updates the format from settings
    func updateFormat() {
        formatter.dateFormat = FeatureSettings.shared.timestampFormat
    }
}

// MARK: - Timestamp Overlay View

import SwiftUI

/// A view that displays timestamps alongside terminal content
struct TimestampOverlayView: View {
    @ObservedObject var tracker: LineTimestampTracker
    let visibleRowRange: Range<Int>
    let rowHeight: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(visibleRowRange, id: \.self) { row in
                if let timestamp = tracker.relativeTimestamp(forRow: row) {
                    Text(timestamp)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(height: rowHeight, alignment: .trailing)
                } else {
                    Color.clear
                        .frame(height: rowHeight)
                }
            }
        }
        .padding(.trailing, 4)
    }
}

// MARK: - Integration Helper

extension TerminalSessionModel {
    /// Creates a timestamp tracker for this session
    func createTimestampTracker() -> LineTimestampTracker {
        return LineTimestampTracker(maxEntries: FeatureSettings.shared.scrollbackLines)
    }
}
