import Foundation

public struct DeferredInputApproval: Sendable {
    public struct Context: Equatable, Sendable {
        public let terminalID: UInt64
        public let shellPID: Int32
        public let directory: String
        public let inputPrefix: String
        public let lastInputAt: Date
        public init(terminalID: UInt64, shellPID: Int32, directory: String, inputPrefix: String, lastInputAt: Date) {
            self.terminalID = terminalID
            self.shellPID = shellPID
            self.directory = directory
            self.inputPrefix = inputPrefix
            self.lastInputAt = lastInputAt
        }
    }

    public private(set) var pendingToken: UUID?
    private var context: Context?
    public init() {}

    public mutating func begin(context: Context) -> UUID? {
        guard pendingToken == nil else { return nil }
        let token = UUID()
        pendingToken = token
        self.context = context
        return token
    }

    /// A decision consumes its own request once, and cannot authorize edited
    /// input, another pane/PTY, another directory, or a replacement request.
    public mutating func resolve(token: UUID, current: Context?, approved: Bool) -> Bool {
        guard token == pendingToken else { return false }
        defer { pendingToken = nil
            context = nil
        }
        return approved && current != nil && current == context
    }
}
