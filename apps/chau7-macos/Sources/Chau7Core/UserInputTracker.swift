import Foundation

public enum TerminalInputSource: String, Codable, CaseIterable, Sendable {
    case user
    case agent
    case system
}

public struct TerminalInputRecord: Equatable, Codable, Sendable {
    public let row: Int
    public let source: TerminalInputSource
    public let timestamp: Date

    public init(row: Int, source: TerminalInputSource, timestamp: Date) {
        self.row = row
        self.source = source
        self.timestamp = timestamp
    }
}

public final class UserInputTracker: @unchecked Sendable {
    private let maxEntries: Int
    private var recordsByRow: [Int: TerminalInputRecord] = [:]
    private let lock = NSLock()

    public init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    public func record(row: Int, source: TerminalInputSource, timestamp: Date = Date()) {
        lock.lock()
        recordsByRow[row] = TerminalInputRecord(row: row, source: source, timestamp: timestamp)
        pruneIfNeeded()
        lock.unlock()
    }

    public func visibleRows(top: Int, bottom: Int, source: TerminalInputSource? = nil) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordsByRow.values
            .filter { record in
                record.row >= top && record.row <= bottom && (source == nil || record.source == source)
            }
            .map(\.row)
            .sorted()
    }

    public func sortedRecords(source: TerminalInputSource? = nil) -> [TerminalInputRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsByRow.values
            .filter { source == nil || $0.source == source }
            .sorted { lhs, rhs in lhs.row < rhs.row }
    }

    public func reset() {
        lock.lock()
        recordsByRow.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func pruneIfNeeded() {
        guard recordsByRow.count > maxEntries else { return }
        let overflow = recordsByRow.count - maxEntries
        let keysToRemove = recordsByRow.values
            .sorted { lhs, rhs in lhs.row < rhs.row }
            .prefix(overflow)
            .map(\.row)
        for key in keysToRemove {
            recordsByRow.removeValue(forKey: key)
        }
    }
}
