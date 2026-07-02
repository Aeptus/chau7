import Foundation

/// Exponential backoff for WebSocket reconnection: 2, 4, 8, 16, 32 seconds (5 attempts max).
public struct RemoteReconnectBackoff: Sendable {
    public static let maxAttempts = 5

    public private(set) var attempt = 0

    public init() {}

    public var hasRemainingAttempts: Bool {
        attempt < Self.maxAttempts
    }

    public mutating func reset() {
        attempt = 0
    }

    public mutating func nextDelay() -> TimeInterval? {
        guard hasRemainingAttempts else { return nil }
        attempt += 1
        return pow(2.0, Double(attempt))
    }
}
