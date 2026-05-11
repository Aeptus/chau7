/// Tracks terminal render requests without losing newer work when a frame
/// commits after additional sync/present requests arrived.
public struct TerminalRenderRequestCoalescer: Equatable, Sendable {
    public struct DrawRequest: Equatable, Sendable {
        public let shouldSync: Bool
        public let shouldPresent: Bool
        fileprivate let syncGeneration: UInt64
        fileprivate let presentGeneration: UInt64
    }

    public private(set) var needsSync: Bool
    public private(set) var needsPresent: Bool
    private var syncGeneration: UInt64
    private var presentGeneration: UInt64

    public init(needsSync: Bool = true, needsPresent: Bool = true) {
        self.needsSync = needsSync
        self.needsPresent = needsPresent
        self.syncGeneration = needsSync ? 1 : 0
        self.presentGeneration = needsPresent ? 1 : 0
    }

    public mutating func requestSync() {
        needsSync = true
        needsPresent = true
        syncGeneration &+= 1
        presentGeneration &+= 1
    }

    public mutating func requestPresent() {
        needsPresent = true
        presentGeneration &+= 1
    }

    public func drawRequest() -> DrawRequest? {
        let shouldSync = needsSync
        let shouldPresent = needsPresent || shouldSync
        guard shouldPresent else { return nil }
        return DrawRequest(
            shouldSync: shouldSync,
            shouldPresent: shouldPresent,
            syncGeneration: syncGeneration,
            presentGeneration: presentGeneration
        )
    }

    /// Clears only the generations consumed by the committed draw.
    /// Returns true when a newer request remains pending and needs another draw.
    @discardableResult
    public mutating func completeCommittedDraw(_ request: DrawRequest) -> Bool {
        if request.shouldSync, syncGeneration == request.syncGeneration {
            needsSync = false
        }
        if request.shouldPresent, presentGeneration == request.presentGeneration {
            needsPresent = false
        }
        return needsSync || needsPresent
    }
}
