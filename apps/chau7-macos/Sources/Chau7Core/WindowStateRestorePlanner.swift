import Foundation

public enum WindowStateRestorePlanner {
    public struct CandidateWindow: Equatable {
        public let tabIDs: [UUID]

        public init(tabIDs: [UUID]) {
            self.tabIDs = tabIDs
        }
    }

    public static func additionalWindowsFromBackup(
        currentPrimaryTabIDs: Set<UUID>,
        backupWindows: [CandidateWindow]
    ) -> [CandidateWindow] {
        guard backupWindows.count > 1 else { return [] }

        let bestMatch = backupWindows.enumerated().max { lhs, rhs in
            let lhsScore = overlapScore(currentPrimaryTabIDs: currentPrimaryTabIDs, candidate: lhs.element)
            let rhsScore = overlapScore(currentPrimaryTabIDs: currentPrimaryTabIDs, candidate: rhs.element)
            if lhsScore == rhsScore {
                return lhs.offset > rhs.offset
            }
            return lhsScore < rhsScore
        }

        if let bestMatch,
           overlapScore(currentPrimaryTabIDs: currentPrimaryTabIDs, candidate: bestMatch.element) > 0 {
            return backupWindows.enumerated().compactMap { index, window in
                index == bestMatch.offset ? nil : window
            }
        }

        return Array(backupWindows.dropFirst())
    }

    private static func overlapScore(
        currentPrimaryTabIDs: Set<UUID>,
        candidate: CandidateWindow
    ) -> Int {
        guard !currentPrimaryTabIDs.isEmpty else { return 0 }
        let candidateIDs = Set(candidate.tabIDs)
        return currentPrimaryTabIDs.intersection(candidateIDs).count
    }
}
