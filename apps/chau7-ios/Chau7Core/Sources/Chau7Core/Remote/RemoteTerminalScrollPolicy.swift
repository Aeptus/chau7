import Foundation

/// Coordinates the phone scroll surface with source-width terminal history.
public enum RemoteTerminalScrollPolicy {
    public static func shouldForwardUserScroll(
        isSynchronizing: Bool,
        isTracking: Bool,
        isDragging: Bool,
        isDecelerating: Bool
    ) -> Bool {
        !isSynchronizing && (isTracking || isDragging || isDecelerating)
    }

    /// Convert phone-width rows before clamping to the engine's source history.
    /// Keep sub-row precision until the engine resolves the fraction against its
    /// live history; rounding first makes a wide terminal jump in whole chunks.
    public static func normalizedOffset(
        contentHeight: Double,
        viewportHeight: Double,
        contentOffsetY: Double,
        cellHeight: Double,
        scrollbackRows: Int,
        chunksPerRow: Int = 1
    ) -> Double {
        guard contentHeight.isFinite, viewportHeight.isFinite, contentOffsetY.isFinite,
              cellHeight.isFinite, cellHeight > 0, scrollbackRows > 0 else { return 0 }
        let maximumOffset = max(0, contentHeight - viewportHeight)
        let distance = max(0, maximumOffset - contentOffsetY)
        let historyHeight = Double(scrollbackRows) * Double(max(1, chunksPerRow)) * cellHeight
        return min(max(distance / historyHeight, 0), 1)
    }

    /// UIKit owns the position throughout a drag, bounce and momentum phase.
    public static func shouldSynchronizePosition(
        force: Bool,
        isTracking: Bool,
        isDragging: Bool,
        isDecelerating: Bool
    ) -> Bool {
        force || !(isTracking || isDragging || isDecelerating)
    }

    /// Only rows intersecting the dirty portion of the visible canvas need work.
    public static func visibleRows(
        totalRows: Int,
        cellHeight: Double,
        minY: Double,
        maxY: Double
    ) -> Range<Int> {
        guard totalRows > 0, cellHeight.isFinite, cellHeight > 0,
              minY.isFinite, maxY.isFinite, maxY > minY else { return 0 ..< 0 }
        let first = Int(min(max((minY / cellHeight).rounded(.down), 0), Double(totalRows)))
        let end = Int(min(max((maxY / cellHeight).rounded(.up), 0), Double(totalRows)))
        return first ..< max(first, end)
    }
}

/// One latest scroll destination per display refresh, never a task per gesture callback.
public struct RemoteTerminalScrollRequests: Sendable {
    public struct Request: Equatable, Sendable {
        public let tabID: UInt32
        public let fraction: Double
    }

    private var pending: Request?

    public init() {}

    public mutating func request(tabID: UInt32, fraction: Double) {
        guard tabID != 0, fraction.isFinite else { return }
        pending = Request(tabID: tabID, fraction: min(max(fraction, 0), 1))
    }

    public mutating func take(for tabID: UInt32) -> Request? {
        defer { pending = nil }
        guard pending?.tabID == tabID else { return nil }
        return pending
    }

    public mutating func discard() {
        pending = nil
    }
}
