import Foundation

public enum DeferredRestoreCandidatePriority: String, Equatable, Sendable {
    case selected
    case nearestToSelection
    case fifoFallback
}

public enum DeferredRestoreSchedulingDecision: Equatable, Sendable {
    case idle
    case wait(TimeInterval)
    case restore(UUID, DeferredRestoreCandidatePriority)
}

public enum DeferredRestoreSchedulingPolicy {
    public static let rapidSelectionQuietPeriod: TimeInterval = 0.45

    public static func decide(
        pendingTabIDs: [UUID],
        tabOrder: [UUID],
        selectedTabID: UUID,
        lastSelectionChangedAt: TimeInterval?,
        now: TimeInterval,
        quietPeriod: TimeInterval = rapidSelectionQuietPeriod
    ) -> DeferredRestoreSchedulingDecision {
        guard !pendingTabIDs.isEmpty else { return .idle }

        if pendingTabIDs.contains(selectedTabID) {
            return .restore(selectedTabID, .selected)
        }

        if let lastSelectionChangedAt {
            let elapsed = max(0, now - lastSelectionChangedAt)
            if elapsed < quietPeriod {
                return .wait(quietPeriod - elapsed)
            }
        }

        let pendingSet = Set(pendingTabIDs)
        if let selectedIndex = tabOrder.firstIndex(of: selectedTabID) {
            for distance in 1 ... max(tabOrder.count, 1) {
                let rightIndex = selectedIndex + distance
                if rightIndex < tabOrder.count {
                    let candidate = tabOrder[rightIndex]
                    if pendingSet.contains(candidate) {
                        return .restore(candidate, .nearestToSelection)
                    }
                }

                let leftIndex = selectedIndex - distance
                if leftIndex >= 0 {
                    let candidate = tabOrder[leftIndex]
                    if pendingSet.contains(candidate) {
                        return .restore(candidate, .nearestToSelection)
                    }
                }
            }
        }

        return .restore(pendingTabIDs[0], .fifoFallback)
    }
}
