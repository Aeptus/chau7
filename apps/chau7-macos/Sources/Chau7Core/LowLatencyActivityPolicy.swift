import Foundation

public struct LowLatencyActivityPolicyInput: Equatable, Sendable {
    public let isAppActive: Bool
    public let hasLatencyCriticalScopes: Bool
    public let hasVisibleLiveWindows: Bool

    public init(
        isAppActive: Bool,
        hasLatencyCriticalScopes: Bool,
        hasVisibleLiveWindows: Bool
    ) {
        self.isAppActive = isAppActive
        self.hasLatencyCriticalScopes = hasLatencyCriticalScopes
        self.hasVisibleLiveWindows = hasVisibleLiveWindows
    }
}

public enum LowLatencyActivityPolicy {
    public static func shouldHoldActivity(_ input: LowLatencyActivityPolicyInput) -> Bool {
        input.isAppActive || input.hasLatencyCriticalScopes || input.hasVisibleLiveWindows
    }
}
