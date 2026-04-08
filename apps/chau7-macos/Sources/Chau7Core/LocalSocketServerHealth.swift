import Foundation

public struct LocalSocketServerHealthSnapshot: Sendable, Equatable {
    public let expectedRunning: Bool
    public let isRunning: Bool
    public let hasSocketDescriptor: Bool
    public let hasAcceptSource: Bool
    public let socketPathExists: Bool

    public init(
        expectedRunning: Bool,
        isRunning: Bool,
        hasSocketDescriptor: Bool,
        hasAcceptSource: Bool,
        socketPathExists: Bool
    ) {
        self.expectedRunning = expectedRunning
        self.isRunning = isRunning
        self.hasSocketDescriptor = hasSocketDescriptor
        self.hasAcceptSource = hasAcceptSource
        self.socketPathExists = socketPathExists
    }
}

public enum LocalSocketServerHealth {
    public static func needsRecovery(_ snapshot: LocalSocketServerHealthSnapshot) -> Bool {
        guard snapshot.expectedRunning else {
            return false
        }
        guard snapshot.isRunning else {
            return true
        }
        return !snapshot.hasSocketDescriptor || !snapshot.hasAcceptSource || !snapshot.socketPathExists
    }
}
