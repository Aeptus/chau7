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
        let eligible = candidates.filter { $0.index != excludedIndex }

        if let exact = eligible.first(where: { !$0.primaryFrame.isEmpty && $0.primaryFrame.contains(point) }) {
            return exact.index
        }

        return eligible.first(where: { $0.fallbackFrame.contains(point) })?.index
    }
}
