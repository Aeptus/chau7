import CoreGraphics

/// Geometry helpers for tab reorder previews.
public enum TabDragLayout {
    /// Returns the destination slot a dragged tab should visually occupy.
    ///
    /// The drag translation moves the tab's center by the same amount, so the
    /// reorder threshold is the distance between tab centers, not half of only
    /// the neighbor width.
    public static func destinationIndex(
        for translation: CGFloat,
        homeIndex: Int,
        tabWidths: [CGFloat],
        spacing: CGFloat
    ) -> Int {
        guard homeIndex >= 0, homeIndex < tabWidths.count else { return homeIndex }

        let draggedWidth = tabWidths[homeIndex]
        var newIndex = homeIndex
        var previousWidth = draggedWidth
        var centerDistance: CGFloat = 0

        if translation > 0 {
            for index in (homeIndex + 1) ..< tabWidths.count {
                let neighborWidth = tabWidths[index]
                centerDistance += (previousWidth * 0.5) + spacing + (neighborWidth * 0.5)
                if translation > centerDistance {
                    newIndex = index
                    previousWidth = neighborWidth
                } else {
                    break
                }
            }
        } else if translation < 0 {
            for index in stride(from: homeIndex - 1, through: 0, by: -1) {
                let neighborWidth = tabWidths[index]
                centerDistance += (previousWidth * 0.5) + spacing + (neighborWidth * 0.5)
                if -translation > centerDistance {
                    newIndex = index
                    previousWidth = neighborWidth
                } else {
                    break
                }
            }
        }

        return newIndex
    }
}
