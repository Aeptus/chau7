import Foundation
import Chau7Core

final class Chau7StateSnapshotService {
    static let shared = Chau7StateSnapshotService()

    private let controlService = TerminalControlService.shared
    private let queryService = TelemetryQueryService()
    private let observability = Chau7ObservabilityService.shared

    private init() {}

    func snapshotPayload() -> [String: Any] {
        [
            "schema_version": Chau7MCPObserverContract.snapshotSchemaVersion,
            "observer_contract_version": Chau7MCPObserverContract.version,
            "generated_at_millis": Int64(Date().timeIntervalSince1970 * 1000),
            "latest_seq": observability.latestSequence(),
            "observer_contract": [
                "version": Chau7MCPObserverContract.version,
                "snapshot_tool": Chau7MCPObserverContract.snapshotToolName,
                "subscribe_tool": Chau7MCPObserverContract.subscribeToolName,
                "unsubscribe_tool": Chau7MCPObserverContract.unsubscribeToolName,
                "notification_method": Chau7MCPObserverContract.notificationMethod,
                "heartbeat_event_type": Chau7MCPObserverContract.heartbeatEventType,
                "default_heartbeat_interval_ms": Chau7MCPObserverContract.defaultHeartbeatIntervalMs,
                "min_heartbeat_interval_ms": Chau7MCPObserverContract.minHeartbeatIntervalMs,
                "max_heartbeat_interval_ms": Chau7MCPObserverContract.maxHeartbeatIntervalMs,
                "default_replay_limit": Chau7MCPObserverContract.defaultReplayLimit,
                "max_replay_limit": Chau7MCPObserverContract.maxReplayLimit,
                "supported_topics": Chau7MCPObserverContract.supportedTopics,
                "delivery_mode": Chau7MCPObserverContract.deliveryMode
            ],
            "runtime_info": observability.runtimeInfoPayload(),
            "tabs": controlService.liveTabSummaries(),
            "approvals": controlService.pendingApprovalSummaries(),
            "repo_events": controlService.repoEventSnapshots(),
            "telemetry": [
                "active_runs": queryService.currentRunObjects(),
                "active_sessions": queryService.activeSessionObjects()
            ],
            "timers": observability.timerInventorySnapshot()["timers"] as? [[String: Any]] ?? []
        ]
    }
}
