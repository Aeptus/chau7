import Foundation

public enum TerminalPresentationPhase: String, Equatable, Sendable {
    case live
    case awaitingLiveFrame
}

public struct TerminalPresentationRevealCompletion: Equatable, Sendable {
    public let totalMs: Int?
    public let postPresentMs: Int?

    public init(totalMs: Int?, postPresentMs: Int?) {
        self.totalMs = totalMs
        self.postPresentMs = postPresentMs
    }
}

public struct TerminalPresentationSurfaceState: Equatable, Sendable {
    public private(set) var phase: TerminalPresentationPhase
    public private(set) var generation: UInt64
    public private(set) var revealStartedAt: TimeInterval?
    public private(set) var firstFramePresentedAt: TimeInterval?
    public private(set) var lastVisibleFramePresentedAt: TimeInterval?
    public private(set) var awaitingVisibleFrameReady: Bool

    public init(
        phase: TerminalPresentationPhase = .live,
        generation: UInt64 = 0,
        revealStartedAt: TimeInterval? = nil,
        firstFramePresentedAt: TimeInterval? = nil,
        lastVisibleFramePresentedAt: TimeInterval? = nil,
        awaitingVisibleFrameReady: Bool = false
    ) {
        self.phase = phase
        self.generation = generation
        self.revealStartedAt = revealStartedAt
        self.firstFramePresentedAt = firstFramePresentedAt
        self.lastVisibleFramePresentedAt = lastVisibleFramePresentedAt
        self.awaitingVisibleFrameReady = awaitingVisibleFrameReady
    }

    public var isLivePresentable: Bool {
        phase == .live
    }

    @discardableResult
    public mutating func beginReveal(
        shouldAwaitVisibleFrame: Bool,
        now: TimeInterval
    ) -> Bool {
        firstFramePresentedAt = nil
        lastVisibleFramePresentedAt = nil
        awaitingVisibleFrameReady = shouldAwaitVisibleFrame

        guard shouldAwaitVisibleFrame else {
            phase = .live
            revealStartedAt = nil
            return false
        }

        generation &+= 1
        phase = .awaitingLiveFrame
        revealStartedAt = now
        return true
    }

    public mutating func armVisibleFrameReadyHandoff() {
        awaitingVisibleFrameReady = true
    }

    public mutating func cancelVisibleFrameReadyHandoff() {
        awaitingVisibleFrameReady = false
    }

    @discardableResult
    public mutating func noteVisibleFramePresented(now: TimeInterval) -> Bool {
        guard awaitingVisibleFrameReady else { return false }
        awaitingVisibleFrameReady = false
        lastVisibleFramePresentedAt = now
        if phase == .awaitingLiveFrame, firstFramePresentedAt == nil {
            firstFramePresentedAt = now
        }
        return true
    }

    public mutating func commitLiveReveal(now: TimeInterval) -> TerminalPresentationRevealCompletion? {
        guard phase == .awaitingLiveFrame else { return nil }
        return finishReveal(now: now)
    }

    public mutating func forceLiveReveal(
        now: TimeInterval,
        preserveVisibleFrameHandoff: Bool = false
    ) -> TerminalPresentationRevealCompletion? {
        guard phase == .awaitingLiveFrame else {
            if !preserveVisibleFrameHandoff {
                awaitingVisibleFrameReady = false
            }
            return nil
        }
        return finishReveal(now: now, preserveVisibleFrameHandoff: preserveVisibleFrameHandoff)
    }

    public mutating func resetToLive() {
        phase = .live
        revealStartedAt = nil
        firstFramePresentedAt = nil
        lastVisibleFramePresentedAt = nil
        awaitingVisibleFrameReady = false
    }

    private mutating func finishReveal(
        now: TimeInterval,
        preserveVisibleFrameHandoff: Bool = false
    ) -> TerminalPresentationRevealCompletion {
        let completion = TerminalPresentationRevealCompletion(
            totalMs: elapsedMs(from: revealStartedAt, to: now),
            postPresentMs: elapsedMs(from: firstFramePresentedAt, to: now)
        )
        phase = .live
        revealStartedAt = nil
        firstFramePresentedAt = nil
        if !preserveVisibleFrameHandoff {
            awaitingVisibleFrameReady = false
        }
        return completion
    }

    private func elapsedMs(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
        guard let start, let end else { return nil }
        return Int((max(0, end - start) * 1000.0).rounded())
    }
}
