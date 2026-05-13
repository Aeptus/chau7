/// Tracks terminal render requests without losing newer work when a frame
/// commits after additional sync/present requests arrived.
public struct TerminalRenderRequestCoalescer: Equatable, Sendable {
    public struct DrawRequest: Equatable, Sendable {
        public let shouldSync: Bool
        public let shouldPresent: Bool
        fileprivate let syncGeneration: UInt64
        fileprivate let presentGeneration: UInt64
    }

    public struct Diagnostics: Equatable, Sendable {
        public let pendingSync: Bool
        public let pendingPresent: Bool
        public let pendingRequestCount: Int
        public let syncRequestCount: UInt64
        public let presentRequestCount: UInt64
        public let coalescedSyncRequestCount: UInt64
        public let coalescedPresentRequestCount: UInt64

        public var coalescedRequestCount: UInt64 {
            coalescedSyncRequestCount + coalescedPresentRequestCount
        }
    }

    public private(set) var needsSync: Bool
    public private(set) var needsPresent: Bool
    private var syncGeneration: UInt64
    private var presentGeneration: UInt64
    private var syncRequestCount: UInt64
    private var presentRequestCount: UInt64
    private var coalescedSyncRequestCount: UInt64
    private var coalescedPresentRequestCount: UInt64

    public init(needsSync: Bool = true, needsPresent: Bool = true) {
        self.needsSync = needsSync
        self.needsPresent = needsPresent
        self.syncGeneration = needsSync ? 1 : 0
        self.presentGeneration = needsPresent ? 1 : 0
        self.syncRequestCount = needsSync ? 1 : 0
        self.presentRequestCount = needsPresent ? 1 : 0
        self.coalescedSyncRequestCount = 0
        self.coalescedPresentRequestCount = 0
    }

    public var diagnostics: Diagnostics {
        Diagnostics(
            pendingSync: needsSync,
            pendingPresent: needsPresent,
            pendingRequestCount: (needsSync ? 1 : 0) + (needsPresent ? 1 : 0),
            syncRequestCount: syncRequestCount,
            presentRequestCount: presentRequestCount,
            coalescedSyncRequestCount: coalescedSyncRequestCount,
            coalescedPresentRequestCount: coalescedPresentRequestCount
        )
    }

    public mutating func requestSync() {
        if needsSync {
            coalescedSyncRequestCount &+= 1
        }
        if needsPresent {
            coalescedPresentRequestCount &+= 1
        }
        needsSync = true
        needsPresent = true
        syncRequestCount &+= 1
        presentRequestCount &+= 1
        syncGeneration &+= 1
        presentGeneration &+= 1
    }

    public mutating func requestPresent() {
        if needsPresent {
            coalescedPresentRequestCount &+= 1
        }
        needsPresent = true
        presentRequestCount &+= 1
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

    public mutating func reset(
        needsSync: Bool = false,
        needsPresent: Bool = false
    ) {
        self.needsSync = needsSync
        self.needsPresent = needsPresent
        syncGeneration = needsSync ? 1 : 0
        presentGeneration = needsPresent ? 1 : 0
        syncRequestCount = needsSync ? 1 : 0
        presentRequestCount = needsPresent ? 1 : 0
        coalescedSyncRequestCount = 0
        coalescedPresentRequestCount = 0
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
