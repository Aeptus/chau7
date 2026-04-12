import Foundation

/// Dedicated tracker for rows associated with commands that matched the
/// dangerous-command guard patterns. This deliberately keeps the legacy
/// row-based API so highlight rendering remains unchanged.
final class DangerousCommandLineTracker {
    private let tracker: InputLineTracker

    init(maxEntries: Int) {
        self.tracker = InputLineTracker(maxEntries: maxEntries)
    }

    func record(row: Int) {
        tracker.record(row: row)
    }

    func visibleRows(top: Int, bottom: Int) -> [Int] {
        tracker.visibleRows(top: top, bottom: bottom)
    }

    func reset() {
        tracker.reset()
    }
}
