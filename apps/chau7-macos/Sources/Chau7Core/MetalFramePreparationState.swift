import Foundation

/// Identifies one off-main terminal-frame preparation job. The binding
/// generation changes whenever the window-shared Metal renderer moves to a
/// different terminal view, so a late job can never publish into the new tab.
public struct MetalFramePreparationTicket: Equatable, Sendable {
    public let id: UInt64
    public let bindingGeneration: UInt64

    public init(id: UInt64, bindingGeneration: UInt64) {
        self.id = id
        self.bindingGeneration = bindingGeneration
    }
}

public enum MetalFramePreparationCompletion: Equatable, Sendable {
    case publish
    case discard
}

/// Latest-wins admission state for asynchronous terminal frame preparation.
///
/// Terminal data is never dropped: the Rust terminal remains authoritative.
/// This state coalesces only visual snapshots. At most one preparation and one
/// prepared frame exist at a time; requests arriving during either phase set a
/// pending bit and produce one fresh snapshot after the current frame is
/// consumed.
public struct MetalFramePreparationState: Equatable, Sendable {
    public private(set) var bindingGeneration: UInt64 = 0
    public private(set) var inFlight: MetalFramePreparationTicket?
    public private(set) var prepared: MetalFramePreparationTicket?
    public private(set) var hasPendingRequest = false

    private var nextID: UInt64 = 0

    public init() {}

    /// Requests the latest visual state. Returns a ticket only when a job may
    /// start immediately; otherwise the request is coalesced into the pending
    /// bit.
    public mutating func request() -> MetalFramePreparationTicket? {
        hasPendingRequest = true
        return beginIfPossible()
    }

    /// Publishes a completed job only if it still owns the active binding.
    /// Failed and stale jobs leave no prepared frame.
    public mutating func complete(
        _ ticket: MetalFramePreparationTicket,
        succeeded: Bool
    ) -> MetalFramePreparationCompletion {
        guard inFlight == ticket,
              ticket.bindingGeneration == bindingGeneration else {
            return .discard
        }
        inFlight = nil
        guard succeeded else { return .discard }
        prepared = ticket
        return .publish
    }

    /// Consumes the prepared frame and returns a ticket for the one coalesced
    /// follow-up request, if output arrived while it was being prepared or
    /// waiting for presentation.
    public mutating func consume(
        _ ticket: MetalFramePreparationTicket
    ) -> MetalFramePreparationTicket? {
        guard prepared == ticket else { return nil }
        prepared = nil
        return beginIfPossible()
    }

    /// Invalidates every outstanding job when the shared renderer is rebound.
    /// The caller explicitly requests the incoming tab's first frame after the
    /// reset, preventing outgoing-tab work from leaking across the handoff.
    public mutating func resetForNewBinding() {
        bindingGeneration &+= 1
        inFlight = nil
        prepared = nil
        hasPendingRequest = false
    }

    private mutating func beginIfPossible() -> MetalFramePreparationTicket? {
        guard hasPendingRequest, inFlight == nil, prepared == nil else {
            return nil
        }
        hasPendingRequest = false
        nextID &+= 1
        let ticket = MetalFramePreparationTicket(
            id: nextID,
            bindingGeneration: bindingGeneration
        )
        inFlight = ticket
        return ticket
    }
}
