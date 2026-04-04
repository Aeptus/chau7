import Foundation

/// Exponential backoff for WebSocket reconnection: 2, 4, 8, 16, 32 seconds (5 attempts max).
struct RemoteReconnectBackoff {
    static let maxAttempts = 5

    private(set) var attempt = 0

    var hasRemainingAttempts: Bool {
        attempt < Self.maxAttempts
    }

    mutating func reset() {
        attempt = 0
    }

    mutating func nextDelay() -> TimeInterval? {
        guard hasRemainingAttempts else { return nil }
        attempt += 1
        return pow(2.0, Double(attempt))
    }
}
