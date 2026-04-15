import Foundation

public enum SelectedTabRevealPhase: String, Equatable, Sendable {
    case live
    case showingSnapshot
}

public struct SelectedTabRevealCompletion: Equatable, Sendable {
    public let tabID: UUID?
    public let totalMs: Int?
    public let postPresentMs: Int?

    public init(tabID: UUID?, totalMs: Int?, postPresentMs: Int?) {
        self.tabID = tabID
        self.totalMs = totalMs
        self.postPresentMs = postPresentMs
    }
}

public struct SelectedTabRevealState: Equatable, Sendable {
    public private(set) var selectedTabID: UUID?
    public private(set) var phase: SelectedTabRevealPhase
    public private(set) var generation: UInt64
    public private(set) var startedAt: TimeInterval?
    public private(set) var firstFramePresentedAt: TimeInterval?

    public init(
        selectedTabID: UUID? = nil,
        phase: SelectedTabRevealPhase = .live,
        generation: UInt64 = 0,
        startedAt: TimeInterval? = nil,
        firstFramePresentedAt: TimeInterval? = nil
    ) {
        self.selectedTabID = selectedTabID
        self.phase = phase
        self.generation = generation
        self.startedAt = startedAt
        self.firstFramePresentedAt = firstFramePresentedAt
    }

    public var isTerminalReady: Bool {
        phase == .live
    }

    @discardableResult
    public mutating func select(tabID: UUID, hasSnapshot: Bool, now: TimeInterval) -> Bool {
        selectedTabID = tabID
        firstFramePresentedAt = nil

        guard hasSnapshot else {
            phase = .live
            startedAt = nil
            return false
        }

        generation &+= 1
        phase = .showingSnapshot
        startedAt = now
        return true
    }

    @discardableResult
    public mutating func noteLiveFramePresented(for tabID: UUID, now: TimeInterval) -> Bool {
        guard phase == .showingSnapshot, selectedTabID == tabID else { return false }
        guard firstFramePresentedAt == nil else { return false }
        firstFramePresentedAt = now
        return true
    }

    public mutating func commitLiveReveal(for tabID: UUID, now: TimeInterval) -> SelectedTabRevealCompletion? {
        guard phase == .showingSnapshot, selectedTabID == tabID else { return nil }
        return finishCurrentReveal(now: now)
    }

    public mutating func forceLiveReveal(for tabID: UUID?, now: TimeInterval) -> SelectedTabRevealCompletion? {
        guard phase == .showingSnapshot else {
            if let tabID {
                selectedTabID = tabID
            }
            return nil
        }
        if let tabID, selectedTabID != tabID {
            return nil
        }
        return finishCurrentReveal(now: now)
    }

    public mutating func clearSelection() {
        selectedTabID = nil
        phase = .live
        startedAt = nil
        firstFramePresentedAt = nil
    }

    private mutating func finishCurrentReveal(now: TimeInterval) -> SelectedTabRevealCompletion {
        let completion = SelectedTabRevealCompletion(
            tabID: selectedTabID,
            totalMs: elapsedMs(from: startedAt, to: now),
            postPresentMs: elapsedMs(from: firstFramePresentedAt, to: now)
        )
        phase = .live
        startedAt = nil
        firstFramePresentedAt = nil
        return completion
    }

    private func elapsedMs(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
        guard let start, let end else { return nil }
        return Int((max(0, end - start) * 1000.0).rounded())
    }
}
