import Foundation
import Chau7Core

/// Reads from TelemetryStore and live app state to answer MCP queries.
/// Returns JSON strings for direct use in MCP responses.
final class TelemetryQueryService {
    private let store = TelemetryStore.shared
    private let recorder = TelemetryRecorder.shared

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    // MARK: - Run Queries

    func getRun(_ runID: String) -> String {
        // Check in-progress runs first
        for run in recorder.allActiveRuns where run.id == runID {
            return encode(run)
        }

        guard let run = store.getRun(runID) else {
            return "{\"error\":\"Run not found\"}"
        }
        return encode(run)
    }

    func listRuns(_ params: [String: Any] = [:]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let filter = TelemetryRunFilter(
            sessionID: params["session_id"] as? String,
            repoPath: params["repo_path"] as? String,
            provider: params["provider"] as? String,
            after: (params["after"] as? String).flatMap { iso.date(from: $0) },
            before: (params["before"] as? String).flatMap { iso.date(from: $0) },
            tags: params["tags"] as? [String],
            limit: params["limit"] as? Int ?? 50,
            offset: params["offset"] as? Int
        )

        var runs = store.listRuns(filter: filter)

        // Prepend active runs if no time filter excludes them
        if filter.after == nil || filter.after! < Date() {
            let active = recorder.allActiveRuns.filter { run in
                if let sid = filter.sessionID, run.sessionID != sid { return false }
                if let rp = filter.repoPath, run.repoPath != rp { return false }
                if let p = filter.provider, run.provider != p { return false }
                return true
            }
            runs = active + runs
        }

        return encodeArray(runs)
    }

    func getToolCalls(_ runID: String) -> String {
        let calls = store.getToolCalls(runID: runID)
        return encodeArray(calls)
    }

    func getTranscript(_ runID: String) -> String {
        let turns = store.getTurns(runID: runID)
        return encodeArray(turns)
    }

    func tagRun(_ runID: String, tags: [String]) -> String {
        store.updateRunTags(runID, tags: tags)
        return "{\"ok\":true}"
    }

    func latestRunForRepo(_ repoPath: String, provider: String? = nil) -> String {
        if let run = store.latestRunForRepo(repoPath, provider: provider) {
            return encode(run)
        }
        return "{\"error\":\"No runs found for repo\"}"
    }

    // MARK: - Session Queries

    func listSessions(repoPath: String? = nil, activeOnly: Bool = false) -> String {
        let sessions = store.listSessions(repoPath: repoPath)

        if activeOnly {
            let activeSessionIDs = Set(recorder.allActiveRuns.compactMap(\.sessionID))
            let filtered = sessions.filter { row in
                guard let sid = row["session_id"] as? String else { return false }
                return activeSessionIDs.contains(sid)
            }
            return encodeAny(filtered)
        }

        return encodeAny(sessions)
    }

    func currentSessions() -> String {
        let active = recorder.allActiveRuns
        return encodeArray(active)
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
}
