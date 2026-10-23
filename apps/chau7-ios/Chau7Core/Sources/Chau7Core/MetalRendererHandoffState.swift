/// Transaction token for moving a window-shared Metal surface between terminal panes.
///
/// A presentation may commit only when its generation still owns the surface.
/// This prevents an older GPU completion from revealing itself after a newer
/// pane selection has already started.
public struct MetalRendererHandoffState: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var isAwaitingFirstFrame = false

    public init() {}

    @discardableResult
    public mutating func begin() -> UInt64 {
        generation &+= 1
        isAwaitingFirstFrame = true
        return generation
    }

    public func owns(_ candidateGeneration: UInt64) -> Bool {
        generation == candidateGeneration
    }

    /// Commits the first frame for the current generation. Returns `false`
    /// for stale completions and for duplicate completions after the handoff.
    @discardableResult
    public mutating func commitFirstFrame(generation candidateGeneration: UInt64) -> Bool {
        guard owns(candidateGeneration), isAwaitingFirstFrame else { return false }
        isAwaitingFirstFrame = false
        return true
    }
}
