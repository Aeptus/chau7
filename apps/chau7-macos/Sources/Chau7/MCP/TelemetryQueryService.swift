import Foundation
import Chau7Core

/// Reads from TelemetryStore and live app state to answer MCP queries.
/// Returns JSON strings for direct use in MCP responses.
final class TelemetryQueryService {
    private let store = TelemetryStore.shared
    private let recorder = TelemetryRecorder.shared
    private let terminalControl = TerminalControlService.shared
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    // MARK: - Run Queries

    func getRun(_ runID: String) -> String {
        let activeRuns = activeRunsByID()
        guard let run = activeRuns[runID] ?? store.getRun(runID) else {
            return "{\"error\":\"Run not found\"}"
        }
        return encodeAny(projectRun(run, activeRunIDs: Set(activeRuns.keys)))
    }

    func listRuns(_ params: [String: Any] = [:]) -> String {
        let filter = TelemetryRunFilter(
            sessionID: params["session_id"] as? String,
            repoPath: params["repo_path"] as? String,
            provider: params["provider"] as? String,
            parentRunID: params["parent_run_id"] as? String,
            after: (params["after"] as? String).flatMap { isoFormatter.date(from: $0) },
            before: (params["before"] as? String).flatMap { isoFormatter.date(from: $0) },
            tags: params["tags"] as? [String],
            limit: params["limit"] as? Int ?? 50,
            offset: params["offset"] as? Int
        )

        let activeRuns = filteredActiveRuns(filter: filter)
        var storeFilter = filter
        storeFilter.limit = nil
        storeFilter.offset = nil
        let storedRuns = store.listRuns(filter: storeFilter)
        let activeRunIDs = Set(activeRuns.map(\.id))
        let mergedRuns = TelemetryQueryProjection.mergeRuns(
            activeRuns: activeRuns,
            storedRuns: storedRuns,
            offset: filter.offset ?? 0,
            limit: filter.limit ?? 50
        )

        return encodeAny(mergedRuns.map { projectRun($0, activeRunIDs: activeRunIDs) })
    }

    func getToolCalls(_ runID: String) -> String {
        let calls = store.getToolCalls(runID: runID)
        return encodeArray(calls)
    }

    func getTranscript(_ runID: String) -> String {
        let turns = store.getTurns(runID: runID)
        if !turns.isEmpty {
            return encodeArray(turns)
        }

        let activeRuns = activeRunsByID()
        guard let run = activeRuns[runID] ?? store.getRun(runID) else {
            return "[]"
        }

        return encodeArray(activeTranscriptFallback(for: run))
    }

    func tagRun(_ runID: String, tags: [String]) -> String {
        store.updateRunTags(runID, tags: tags)
        return "{\"ok\":true}"
    }

    func latestRunForRepo(_ repoPath: String, provider: String? = nil) -> String {
        let filter = TelemetryRunFilter(repoPath: repoPath, provider: provider)
        let activeRuns = filteredActiveRuns(filter: filter)
        var storeFilter = filter
        storeFilter.limit = nil
        storeFilter.offset = nil
        let storedRuns = store.listRuns(filter: storeFilter)
        let activeRunIDs = Set(activeRuns.map(\.id))
        if let run = TelemetryQueryProjection.mergeRuns(
            activeRuns: activeRuns,
            storedRuns: storedRuns,
            offset: 0,
            limit: 1
        ).first {
            return encodeAny(projectRun(run, activeRunIDs: activeRunIDs))
        }
        return "{\"error\":\"No runs found for repo\"}"
    }

    // MARK: - Session Queries

    func listSessions(repoPath: String? = nil, activeOnly: Bool = false) -> String {
        let sessions = store.listSessions(repoPath: repoPath)
        let activeRuns = filteredActiveRuns(filter: TelemetryRunFilter(repoPath: repoPath))
        let activeRunsBySession = Dictionary(grouping: activeRuns.compactMap { run -> (String, TelemetryRun)? in
            guard let sessionID = run.sessionID else { return nil }
            return (sessionID, run)
        }, by: \.0).mapValues { $0.map(\.1) }

        var latestStoredRunBySession: [String: TelemetryRun] = [:]
        for run in store.listRuns(filter: TelemetryRunFilter(repoPath: repoPath)) {
            guard let sessionID = run.sessionID,
                  latestStoredRunBySession[sessionID] == nil else {
                continue
            }
            latestStoredRunBySession[sessionID] = run
        }

        let enriched = sessions.compactMap { row -> [String: Any]? in
            guard let sessionID = row["session_id"] as? String,
                  !sessionID.isEmpty else {
                return nil
            }

            let activeSessionRuns = activeRunsBySession[sessionID] ?? []
            if activeOnly, activeSessionRuns.isEmpty {
                return nil
            }

            var projected = row
            let totalRunCount = row["run_count"] as? Int ?? 0
            let activeRunCount = activeSessionRuns.count
            projected["active_run_count"] = activeRunCount
            projected["completed_run_count"] = max(totalRunCount - activeRunCount, 0)

            let latestActiveRun = activeSessionRuns.max(by: { TelemetryQueryProjection.runSortDescending($1, $0) })
            let latestStoredRun = latestStoredRunBySession[sessionID]
            let latestRun: TelemetryRun?
            if let latestActiveRun, let latestStoredRun {
                latestRun = TelemetryQueryProjection.runSortDescending(latestActiveRun, latestStoredRun) ? latestActiveRun : latestStoredRun
            } else {
                latestRun = latestActiveRun ?? latestStoredRun
            }

            projected["latest_run_id"] = latestRun?.id ?? ""
            projected["latest_run_state"] = latestRun.map { candidate in
                activeSessionRuns.contains(where: { $0.id == candidate.id })
                    ? TelemetryRunState.active.rawValue
                    : TelemetryRunState.completed.rawValue
            } ?? TelemetryRunState.completed.rawValue
            if let latestRun {
                projected["provider"] = latestRun.provider
                projected["repo_path"] = latestRun.repoPath ?? (projected["repo_path"] as? String ?? "")
                projected["last_active"] = isoFormatter.string(from: latestRun.startedAt)
            }
            return projected
        }

        return encodeAny(enriched)
    }

    func currentSessions() -> String {
        let active = recorder.allActiveRuns.sorted(by: TelemetryQueryProjection.runSortDescending)
        let activeRunIDs = Set(active.map(\.id))
        return encodeAny(active.map { projectRun($0, activeRunIDs: activeRunIDs) })
    }

    // MARK: - Encoding

    private func encode(_ value: some Encodable) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func encodeArray(_ values: [some Encodable]) -> String {
        guard let data = try? encoder.encode(values) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func encodeAny(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func activeRunsByID() -> [String: TelemetryRun] {
        Dictionary(uniqueKeysWithValues: recorder.allActiveRuns.map { ($0.id, $0) })
    }

    private func filteredActiveRuns(filter: TelemetryRunFilter) -> [TelemetryRun] {
        recorder.allActiveRuns.filter { run in
            if let sessionID = filter.sessionID, run.sessionID != sessionID { return false }
            if let repoPath = filter.repoPath, run.repoPath != repoPath { return false }
            if let provider = filter.provider, run.provider != provider { return false }
            if let parentRunID = filter.parentRunID, run.parentRunID != parentRunID { return false }
            if let after = filter.after, run.startedAt < after { return false }
            if let before = filter.before, run.startedAt > before { return false }
            return true
        }
    }

    private func projectRun(_ run: TelemetryRun, activeRunIDs: Set<String>) -> [String: Any] {
        guard let data = try? encoder.encode(run),
              var json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) else {
            return [:]
        }

        let isActive = activeRunIDs.contains(run.id)
        let liveTurns = isActive ? activeTranscriptFallback(for: run) : []
        let contentState: TelemetryContentState
        if isActive {
            contentState = liveTurns.isEmpty ? .missing : .partial
        } else {
            contentState = TelemetryQueryProjection.completedContentState(for: run)
        }

        json["run_state"] = isActive ? TelemetryRunState.active.rawValue : TelemetryRunState.completed.rawValue
        json["content_state"] = contentState.rawValue
        return json
    }

    private func activeTranscriptFallback(for run: TelemetryRun) -> [TelemetryTurn] {
        guard run.endedAt == nil else { return [] }

        if run.provider.lowercased().contains("codex"),
           let sessionID = run.sessionID {
            let historyTurns = CodexLiveHistoryParser.turnsFromHistoryFile(
                sessionID: sessionID,
                runID: run.id,
                startedAt: run.startedAt
            )
            if !historyTurns.isEmpty {
                return historyTurns
            }
        }

        guard let tabID = run.tabID else { return [] }
        let response = terminalControl.tabOutput(tabID: tabID, lines: 80, source: "pty_log")
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = (json["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return []
        }

        return [
            TelemetryTurn(
                id: "\(run.id)-live-pty",
                runID: run.id,
                turnIndex: 0,
                role: .assistant,
                content: output,
                timestamp: Date()
            )
        ]
    }
}
