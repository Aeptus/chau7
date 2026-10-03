import Foundation

/// Storage budgets apply to archives, never the authoritative latest restore.
public enum FileRetentionBudget {
    public struct Entry: Equatable, Sendable {
        public let key: String
        public let bytes: Int
        public let modifiedAt: TimeInterval
        public init(key: String, bytes: Int, modifiedAt: TimeInterval) {
            self.key = key
            self.bytes = bytes
            self.modifiedAt = modifiedAt
        }
    }

    public static func removals(
        newestFirst entries: [Entry], maximumCount: Int, maximumBytes: Int,
        maximumFileBytes: Int, cutoff: TimeInterval
    ) -> [String] {
        var keptCount = 0
        var keptBytes = 0
        var removed: [String] = []
        for entry in entries {
            guard entry.modifiedAt >= cutoff, entry.bytes >= 0,
                  entry.bytes <= max(0, maximumFileBytes), keptCount < max(0, maximumCount),
                  entry.bytes <= max(0, maximumBytes) - keptBytes else {
                removed.append(entry.key)
                continue
            }
            keptCount += 1
            keptBytes += entry.bytes
        }
        return removed
    }
}
