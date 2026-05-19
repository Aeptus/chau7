import Foundation
import CoreGraphics

public struct OverlayWindowDropCandidate: Equatable {
    public let index: Int
    public let primaryFrame: CGRect
    public let fallbackFrame: CGRect

    public init(index: Int, primaryFrame: CGRect, fallbackFrame: CGRect) {
        self.index = index
        self.primaryFrame = primaryFrame
        self.fallbackFrame = fallbackFrame
    }
}

public enum OverlayWindowDropResolver {
    public static func targetIndex(
        at point: CGPoint,
        candidates: [OverlayWindowDropCandidate],
        excluding excludedIndex: Int? = nil
    ) -> Int? {
        let source = candidates.first { $0.index == excludedIndex }
        let eligible = candidates.filter { $0.index != excludedIndex }

        if let exact = eligible.first(where: { !$0.primaryFrame.isEmpty && $0.primaryFrame.contains(point) }) {
            return exact.index
        }

        // If the drop still lies within the source window, treat it as an
        // intra-window gesture — overlapping/stacked windows otherwise let a
        // sibling's fallbackFrame steal the tab.
        if let source, source.fallbackFrame.contains(point) || (!source.primaryFrame.isEmpty && source.primaryFrame.contains(point)) {
            return nil
        }

        return eligible.first(where: { $0.fallbackFrame.contains(point) })?.index
    }
}
