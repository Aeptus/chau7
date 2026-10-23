import Foundation

public enum TransitionSnapshotRetention {
    public static let nearbyTabDistance = 2

    public static func shouldRetainCachedSnapshot(
        tabIndex: Int,
        currentIndex: Int,
        hasRestorePreview: Bool,
        nearbyDistance: Int = nearbyTabDistance
    ) -> Bool {
        if hasRestorePreview {
            return true
        }

        return abs(tabIndex - currentIndex) <= max(0, nearbyDistance)
    }
}
