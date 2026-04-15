import Foundation

public enum TerminalPresentationPhase: String, Equatable, Sendable {
    case live
    case showingSnapshot
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
    public private(set) var awaitingVisibleFrameReady: Bool

    public init(
        phase: TerminalPresentationPhase = .live,
        generation: UInt64 = 0,
        revealStartedAt: TimeInterval? = nil,
        firstFramePresentedAt: TimeInterval? = nil,
        awaitingVisibleFrameReady: Bool = false
    ) {
        self.phase = phase
        self.generation = generation
        self.revealStartedAt = revealStartedAt
        self.firstFramePresentedAt = firstFramePresentedAt
        self.awaitingVisibleFrameReady = awaitingVisibleFrameReady
    }

    public var isLivePresentable: Bool {
        phase == .live
    }

    public var shouldShowSnapshot: Bool {
        phase == .showingSnapshot
    }

    @discardableResult
    public mutating func beginReveal(
        hasSnapshot: Bool,
        shouldAwaitVisibleFrame: Bool,
        now: TimeInterval
    ) -> Bool {
        firstFramePresentedAt = nil
        awaitingVisibleFrameReady = shouldAwaitVisibleFrame

        guard hasSnapshot else {
            phase = .live
            revealStartedAt = nil
            return false
        }

        generation &+= 1
        phase = .showingSnapshot
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
        if phase == .showingSnapshot, firstFramePresentedAt == nil {
            firstFramePresentedAt = now
        }
        return true
    }

    public mutating func commitLiveReveal(now: TimeInterval) -> TerminalPresentationRevealCompletion? {
        guard phase == .showingSnapshot else { return nil }
        return finishReveal(now: now)
    }

    public mutating func forceLiveReveal(now: TimeInterval) -> TerminalPresentationRevealCompletion? {
        guard phase == .showingSnapshot else {
            awaitingVisibleFrameReady = false
            return nil
        }
        return finishReveal(now: now)
    }

    public mutating func resetToLive() {
        phase = .live
        revealStartedAt = nil
        firstFramePresentedAt = nil
        awaitingVisibleFrameReady = false
    }

    private mutating func finishReveal(now: TimeInterval) -> TerminalPresentationRevealCompletion {
        let completion = TerminalPresentationRevealCompletion(
            totalMs: elapsedMs(from: revealStartedAt, to: now),
            postPresentMs: elapsedMs(from: firstFramePresentedAt, to: now)
        )
        phase = .live
        revealStartedAt = nil
        firstFramePresentedAt = nil
        awaitingVisibleFrameReady = false
        return completion
    }

    private func elapsedMs(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
        guard let start, let end else { return nil }
        return Int((max(0, end - start) * 1000.0).rounded())
    }
}
