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

    /// Per-tab claim decision for multi-window restore deduplication.
    public enum TabClaim: Equatable {
        /// Unique so far (or unparseable ID, which always restores fresh).
        case restore
        /// Its ID was already claimed by an earlier window or earlier tab.
        case dropDuplicate
    }

    /// Hard per-tab deduplication across restored windows: the same saved tab
    /// must restore exactly once no matter how many window snapshots claim it.
    /// First occurrence wins — duplicated-window snapshots from past incidents
    /// converge back to a single copy instead of re-persisting forever.
    ///
    /// `windows` carries one optional UUID per saved tab (nil = unparseable
    /// tab ID, which hydration re-mints and therefore can never collide).
    public static func claimTabs(
        alreadyClaimed: Set<UUID>,
        windows: [[UUID?]]
    ) -> [[TabClaim]] {
        var claimed = alreadyClaimed
        return windows.map { window in
            window.map { tabID in
                guard let tabID else { return .restore }
                if claimed.contains(tabID) { return .dropDuplicate }
                claimed.insert(tabID)
                return .restore
            }
        }
    }
}
