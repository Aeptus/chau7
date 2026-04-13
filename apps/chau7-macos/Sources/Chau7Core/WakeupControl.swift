import Foundation

public enum WakeupSwitch: String, CaseIterable {
    case instrumentationEnabled = "CHAU7_WAKEUP_INSTRUMENTATION"
    case asyncDebugAnalyticsRefresh = "CHAU7_ENABLE_ASYNC_DEBUG_ANALYTICS_REFRESH"
    case lowPowerDangerousHighlights = "CHAU7_ENABLE_LOW_POWER_DANGEROUS_HIGHLIGHTS"

    var defaultValue: Bool {
        switch self {
        case .instrumentationEnabled:
            return true
        case .asyncDebugAnalyticsRefresh:
            return true
        case .lowPowerDangerousHighlights:
            return true
        }
    }
}

public enum WakeupControl {
    public static func isEnabled(
        _ setting: WakeupSwitch,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let rawValue = environment[setting.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return setting.defaultValue
        }

        switch rawValue.lowercased() {
        case "0", "false", "no", "off":
            return false
        case "1", "true", "yes", "on":
            return true
        default:
            return setting.defaultValue
        }
    }
}
