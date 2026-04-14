import Foundation

final class Chau7StateSnapshotService {
    static let shared = Chau7StateSnapshotService()

    private let controlService = TerminalControlService.shared
    private let queryService = TelemetryQueryService()
    private let observability = Chau7ObservabilityService.shared

    private init() {}

    func snapshotPayload() -> [String: Any] {
        [
            "schema_version": 1,
            "generated_at_millis": Int64(Date().timeIntervalSince1970 * 1000),
            "latest_seq": observability.latestSequence(),
            "runtime_info": observability.runtimeInfoPayload(),
            "tabs": controlService.liveTabSummaries(),
            "approvals": controlService.pendingApprovalSummaries(),
            "repo_events": controlService.repoEventSnapshots(),
            "telemetry": [
                "active_runs": queryService.currentRunObjects(),
                "active_sessions": queryService.activeSessionObjects()
            ],
            "timers": observability.timerInventoryPayload()["timers"] as? [[String: Any]] ?? []
        ]
    }
}
