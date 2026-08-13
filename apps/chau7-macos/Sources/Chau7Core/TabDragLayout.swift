import CoreGraphics

/// Geometry helpers for tab reorder previews.
public enum TabDragLayout {
    /// Total visual width of a dragged tab group, including an optional
    /// leading repository label and every spacing inside that segment.
    public static func groupWidth(
        homeRange: Range<Int>,
        tabWidths: [CGFloat],
        spacing: CGFloat,
        leadingAccessoryWidth: CGFloat = 0
    ) -> CGFloat? {
        guard !homeRange.isEmpty,
              homeRange.lowerBound >= 0,
              homeRange.upperBound <= tabWidths.count,
              spacing >= 0,
              leadingAccessoryWidth >= 0,
              homeRange.allSatisfy({ tabWidths[$0] > 0 }) else {
            return nil
        }

        let tabsWidth = homeRange.reduce(0) { $0 + tabWidths[$1] }
            + CGFloat(homeRange.count - 1) * spacing
        guard leadingAccessoryWidth > 0 else { return tabsWidth }
        return leadingAccessoryWidth + spacing + tabsWidth
    }

    /// Pixel delta for one autoscroll tick while a drag is held near a
    /// horizontal viewport edge. Speed ramps with edge penetration so entry
    /// into the activation zone is controlled while the outer edge remains
    /// fast enough for long tab bars.
    public static func edgeAutoScrollDelta(
        pointer: CGPoint,
        viewport: CGRect,
        edgeThreshold: CGFloat = 44,
        verticalTolerance: CGFloat = 12,
        minimumStep: CGFloat = 4,
        maximumStep: CGFloat = 22
    ) -> CGFloat {
        guard viewport.width > 0,
              viewport.height > 0,
              edgeThreshold > 0,
              maximumStep >= minimumStep,
              pointer.y >= viewport.minY - verticalTolerance,
              pointer.y <= viewport.maxY + verticalTolerance else {
            return 0
        }

        let leftPenetration = viewport.minX + edgeThreshold - pointer.x
        if leftPenetration > 0 {
            let progress = min(1, leftPenetration / edgeThreshold)
            return -(minimumStep + (maximumStep - minimumStep) * progress)
        }

        let rightPenetration = pointer.x - (viewport.maxX - edgeThreshold)
        if rightPenetration > 0 {
            let progress = min(1, rightPenetration / edgeThreshold)
            return minimumStep + (maximumStep - minimumStep) * progress
        }

        return 0
    }

    /// Returns the realizable portion of a requested horizontal scroll delta.
    /// The caller uses the same delta for both the clip view and drag
    /// translation, so clamping happens once in this shared policy.
    public static func clampedAutoScrollDelta(
        requestedDelta: CGFloat,
        currentOrigin: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        let maximumOrigin = max(0, contentWidth - viewportWidth)
        let targetOrigin = min(maximumOrigin, max(0, currentOrigin + requestedDelta))
        return targetOrigin - currentOrigin
    }

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
        spacing: CGFloat,
        leadingAccessoryWidth: CGFloat = 0
    ) -> Int {
        guard let groupWidth = groupWidth(
            homeRange: homeRange,
            tabWidths: tabWidths,
            spacing: spacing,
            leadingAccessoryWidth: leadingAccessoryWidth
        ) else {
            return homeRange.lowerBound
        }

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
