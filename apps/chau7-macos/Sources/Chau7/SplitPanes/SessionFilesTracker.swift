import Chau7Core
import Foundation

/// Tracks files touched during the current turn while preserving per-turn history.
final class TurnFilesTracker {
    private(set) var currentTurnID: String?
    private(set) var currentTurnFiles: Set<String> = []
    private(set) var filesByTurn: [String: Set<String>] = [:]
    private(set) var fileTimeline: [String: [FileTouchRecord]] = [:]
    private(set) var fileActions: [String: Set<FileTrackingAction>] = [:]
    private(set) var touchedFiles: Set<String> = []

    private var cursor: UInt64 = 0
    private var processedCommandBlocks: Set<UUID> = []
    private var lastSeenTurnID: String?
    private var turnStartTimes: [String: Date] = [:]

    var gitRoot: String?

    func update(from journal: EventJournal, commandBlocks: [CommandBlock] = []) {
        while true {
            let (events, newCursor, hasMore) = journal.events(after: cursor, limit: 500)
            cursor = newCursor

            for event in events {
                if event.type == RuntimeEventType.turnStarted.rawValue,
                   let turnID = event.turnID,
                   turnID != currentTurnID {
                    turnStartTimes[turnID] = event.timestamp
                    currentTurnID = turnID
                    currentTurnFiles.removeAll()
                } else if let turnID = event.turnID, currentTurnID == nil {
                    currentTurnID = turnID
                }

                if let turnID = event.turnID {
                    lastSeenTurnID = turnID
                }

                let activities = FileTrackingParser.activities(from: event, gitRoot: gitRoot)
                for activity in activities {
                    record(activity: activity, turnID: event.turnID, timestamp: event.timestamp)
                }
            }

            guard hasMore else {
                break
            }
        }

        for block in commandBlocks where !block.isRunning && processedCommandBlocks.insert(block.id).inserted {
            let activities = FileTrackingParser.activities(from: block, gitRoot: gitRoot)
            let timestamp = block.endTime ?? block.startTime
            let fallbackTurnID = block.turnID ?? resolvedTurnID(for: timestamp)
            for activity in activities {
                record(activity: activity, turnID: fallbackTurnID, timestamp: timestamp)
            }
        }
    }

    func reset() {
        currentTurnID = nil
        currentTurnFiles.removeAll()
        filesByTurn.removeAll()
        fileTimeline.removeAll()
        fileActions.removeAll()
        touchedFiles.removeAll()
        cursor = 0
        processedCommandBlocks.removeAll()
        lastSeenTurnID = nil
        turnStartTimes.removeAll()
    }

    private func record(activity: TrackedFileActivity, turnID: String?, timestamp: Date) {
        touchedFiles.insert(activity.path)
        fileActions[activity.path, default: []].insert(activity.action)
        fileTimeline[activity.path, default: []].append(
            FileTouchRecord(turnID: turnID, action: activity.action, timestamp: timestamp)
        )

        if let turnID {
            filesByTurn[turnID, default: []].insert(activity.path)
            if currentTurnID == nil {
                currentTurnID = turnID
            }
            if currentTurnID == turnID {
                currentTurnFiles.insert(activity.path)
            }
        }
    }

    private func resolvedTurnID(for timestamp: Date) -> String? {
        let matchedTurn = turnStartTimes
            .filter { $0.value <= timestamp }
            .max { lhs, rhs in lhs.value < rhs.value }?
            .key
        return matchedTurn ?? currentTurnID ?? lastSeenTurnID
    }
}

/// Accumulates files touched by an AI agent session by reading the EventJournal.
///
/// Survives journal ring-buffer eviction: once a file path is seen, it stays
/// in `touchedFiles` even if the journal event is overwritten. Call `update(from:)`
/// on each refresh cycle to incrementally read new events.
final class SessionFilesTracker {
    private let turnTracker = TurnFilesTracker()

    var gitRoot: String? {
        get { turnTracker.gitRoot }
        set { turnTracker.gitRoot = newValue }
    }

    var touchedFiles: Set<String> {
        turnTracker.touchedFiles
    }

    var currentTurnID: String? {
        turnTracker.currentTurnID
    }

    var currentTurnFiles: Set<String> {
        turnTracker.currentTurnFiles
    }

    var filesByTurn: [String: Set<String>] {
        turnTracker.filesByTurn
    }

    var fileTimeline: [String: [FileTouchRecord]] {
        turnTracker.fileTimeline
    }

    var fileActions: [String: Set<FileTrackingAction>] {
        turnTracker.fileActions
    }

    func update(from journal: EventJournal, commandBlocks: [CommandBlock] = []) {
        turnTracker.update(from: journal, commandBlocks: commandBlocks)
    }

    func reset() {
        turnTracker.reset()
    }
}
