import Foundation

public enum Chau7MCPObserverContract {
    public static let version = 1
    public static let snapshotSchemaVersion = 1
    public static let notificationMethod = "notifications/chau7.event"
    public static let heartbeatEventType = "heartbeat"
    public static let subscriptionControlTopic = "subscription-control"

    public static let snapshotToolName = "chau7_state_snapshot"
    public static let subscribeToolName = "chau7_subscribe"
    public static let unsubscribeToolName = "chau7_unsubscribe"

    public static let defaultReplayLimit = 200
    public static let maxReplayLimit = 500
    public static let defaultHeartbeatIntervalMs = 15_000
    public static let minHeartbeatIntervalMs = 1_000
    public static let maxHeartbeatIntervalMs = 60_000

    public static let deliveryMode = "serial"
    public static let healthyLagState = "healthy"

    public static let snapshotRequiredError = "snapshot_required"
    public static let notificationsUnavailableError = "notifications_unavailable"

    public static let supportedTopics = [
        "approval-state",
        "repo-events",
        "runtime-events",
        "session-state",
        "tab-state",
        "telemetry-runs",
        "timer-inventory"
    ]
}
