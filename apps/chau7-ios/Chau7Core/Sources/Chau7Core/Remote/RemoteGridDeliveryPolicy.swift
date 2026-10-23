import Foundation

/// Async frames are scoped to a connection epoch, selected tab and pane session.
public enum RemoteGridDeliveryPolicy {
    public static func shouldDeliver(
        capturedEpoch: UInt64,
        currentEpoch: UInt64,
        capturedTab: UInt32,
        selectedTab: UInt32?,
        capturedSession: String,
        currentSession: String?,
        isConnected: Bool,
        streamsTerminal: Bool
    ) -> Bool {
        isConnected && streamsTerminal && capturedEpoch == currentEpoch
            && capturedTab == selectedTab && capturedSession == currentSession
    }
}
