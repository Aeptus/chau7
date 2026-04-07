import Foundation

public enum TelemetryRunState: String, Codable, Sendable {
    case active
    case completed
}

public enum TelemetryContentState: String, Codable, Sendable {
    case missing
    case partial
    case final
}

public enum TelemetryQueryProjection {
    public static func mergeRuns(
        activeRuns: [TelemetryRun],
        storedRuns: [TelemetryRun],
        offset: Int = 0,
        limit: Int? = nil
    ) -> [TelemetryRun] {
        let sortedActive = activeRuns.sorted(by: runSortDescending)
        var merged: [TelemetryRun] = []
        var seen = Set<String>()

        for run in sortedActive + storedRuns where seen.insert(run.id).inserted {
            merged.append(run)
        }

        let clampedOffset = max(0, offset)
        guard clampedOffset < merged.count else { return [] }

        let sliced = Array(merged.dropFirst(clampedOffset))
        guard let limit else { return sliced }
        return Array(sliced.prefix(max(0, limit)))
    }

    public static func completedContentState(for run: TelemetryRun) -> TelemetryContentState {
        if run.turnCount > 0 { return .final }
        if let rawTranscriptRef = run.rawTranscriptRef,
           !rawTranscriptRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .final
        }
        return .missing
    }

    public static func runSortDescending(_ lhs: TelemetryRun, _ rhs: TelemetryRun) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.id > rhs.id
    }
}

public enum CodexLiveHistoryParser {
    public static func turns(
        from jsonl: String,
        sessionID: String,
        runID: String,
        startedAt: Date,
        maxTurns: Int = 50
    ) -> [TelemetryTurn] {
        var turns: [TelemetryTurn] = []
        let cutoff = startedAt.addingTimeInterval(-1)

        for line in jsonl.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["session_id"] as? String == sessionID,
                  let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }

            let timestamp = parseTimestamp(json["ts"])
            if let timestamp, timestamp < cutoff {
                continue
            }

            turns.append(TelemetryTurn(
                id: "\(runID)-live-\(turns.count)",
                runID: runID,
                turnIndex: turns.count,
                role: .human,
                content: text,
                timestamp: timestamp
            ))

            if turns.count >= maxTurns {
                break
            }
        }

        return turns
    }

    public static func turnsFromHistoryFile(
        sessionID: String,
        runID: String,
        startedAt: Date,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxTurns: Int = 50
    ) -> [TelemetryTurn] {
        let historyPath = RuntimeIsolation.pathInHome(".codex/history.jsonl", fileManager: fileManager, environment: environment)
        guard fileManager.fileExists(atPath: historyPath),
              let data = fileManager.contents(atPath: historyPath),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return turns(
            from: text,
            sessionID: sessionID,
            runID: runID,
            startedAt: startedAt,
            maxTurns: maxTurns
        )
    }

    private static func parseTimestamp(_ rawValue: Any?) -> Date? {
        switch rawValue {
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            if let seconds = Double(value) {
                return Date(timeIntervalSince1970: seconds)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        default:
            return nil
        }
    }
}
