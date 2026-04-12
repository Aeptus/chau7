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

    /// Returns the destination index for the first tab of a dragged group.
    ///
    /// The group occupies `homeRange` in the flat tab array. Its total visual
    /// width (all members + internal spacings) acts as the "dragged width."
    /// Only tabs outside the group are considered as swap targets.
    public static func groupDestinationIndex(
        for translation: CGFloat,
        homeRange: Range<Int>,
        tabWidths: [CGFloat],
        spacing: CGFloat
    ) -> Int {
        guard !homeRange.isEmpty,
              homeRange.lowerBound >= 0,
              homeRange.upperBound <= tabWidths.count else {
            return homeRange.lowerBound
        }

        let groupWidth: CGFloat = homeRange.reduce(0) { $0 + tabWidths[$1] }
            + CGFloat(max(0, homeRange.count - 1)) * spacing

        var newStart = homeRange.lowerBound
        var centerDistance: CGFloat = 0

        if translation > 0 {
            // Dragging right — iterate over tabs after the group
            var previousEdgeWidth = groupWidth
            for index in homeRange.upperBound ..< tabWidths.count {
                let neighborWidth = tabWidths[index]
                centerDistance += (previousEdgeWidth * 0.5) + spacing + (neighborWidth * 0.5)
                if translation > centerDistance {
                    newStart = index - homeRange.count + 1
                    previousEdgeWidth = neighborWidth
                } else {
                    break
                }
            }
        } else if translation < 0 {
            // Dragging left — iterate over tabs before the group
            var previousEdgeWidth = groupWidth
            for index in stride(from: homeRange.lowerBound - 1, through: 0, by: -1) {
                let neighborWidth = tabWidths[index]
                centerDistance += (previousEdgeWidth * 0.5) + spacing + (neighborWidth * 0.5)
                if -translation > centerDistance {
                    newStart = index
                    previousEdgeWidth = neighborWidth
                } else {
                    break
                }
            }
        }

        return newStart
    }
}
