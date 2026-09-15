import CoreGraphics

/// Pure transaction state for a repository-group tab drag.
///
/// Keeping pointer and scroll compensation in one value prevents the visual
/// presentation and the eventual reorder from using subtly different math.
public struct TabGroupDragState: Equatable, Sendable {
    public let homeRange: Range<Int>
    public let tabWidths: [CGFloat]
    public let spacing: CGFloat
    public let leadingAccessoryWidth: CGFloat

    public private(set) var pointerTranslation: CGFloat = 0
    public private(set) var scrollCompensation: CGFloat = 0
    public private(set) var destinationIndex: Int

    public init?(
        homeRange: Range<Int>,
        tabWidths: [CGFloat],
        spacing: CGFloat,
        leadingAccessoryWidth: CGFloat = 0
    ) {
        guard !homeRange.isEmpty,
              homeRange.lowerBound >= 0,
              homeRange.upperBound <= tabWidths.count,
              spacing >= 0,
              leadingAccessoryWidth >= 0,
              tabWidths.allSatisfy({ $0 > 0 }) else {
            return nil
        }

        self.homeRange = homeRange
        self.tabWidths = tabWidths
        self.spacing = spacing
        self.leadingAccessoryWidth = leadingAccessoryWidth
        self.destinationIndex = homeRange.lowerBound
    }

    public var effectiveTranslation: CGFloat {
        pointerTranslation + scrollCompensation
    }

    public var groupWidth: CGFloat {
        TabDragLayout.groupWidth(
            homeRange: homeRange,
            tabWidths: tabWidths,
            spacing: spacing,
            leadingAccessoryWidth: leadingAccessoryWidth
        ) ?? 0
    }

    public mutating func updatePointerTranslation(_ translation: CGFloat) {
        pointerTranslation = translation
        updateDestination()
    }

    public mutating func applyScrollCompensation(_ delta: CGFloat) {
        scrollCompensation += delta
        updateDestination()
    }

    /// Offset for a non-dragged tab while the original group remains in layout
    /// as an invisible placeholder.
    public func displacement(forTabAt index: Int) -> CGFloat {
        guard tabWidths.indices.contains(index), !homeRange.contains(index) else { return 0 }

        let shift = groupWidth + spacing
        if destinationIndex > homeRange.lowerBound {
            let displacedEnd = destinationIndex + homeRange.count
            return (homeRange.upperBound ..< displacedEnd).contains(index) ? -shift : 0
        }
        if destinationIndex < homeRange.lowerBound {
            return (destinationIndex ..< homeRange.lowerBound).contains(index) ? shift : 0
        }
        return 0
    }

    private mutating func updateDestination() {
        destinationIndex = TabDragLayout.groupDestinationIndex(
            for: effectiveTranslation,
            homeRange: homeRange,
            tabWidths: tabWidths,
            spacing: spacing,
            leadingAccessoryWidth: leadingAccessoryWidth
        )
    }
}
