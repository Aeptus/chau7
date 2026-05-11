import CoreGraphics
import Foundation

/// Compact diagnostic snapshot for terminal renderer geometry.
public struct TerminalRenderSurfaceReport: Equatable {
    public struct RectSnapshot: Equatable {
        public let x: CGFloat
        public let y: CGFloat
        public let width: CGFloat
        public let height: CGFloat

        public init(_ rect: CGRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }
    }

    public struct SizeSnapshot: Equatable {
        public let width: CGFloat
        public let height: CGFloat

        public init(_ size: CGSize) {
            self.width = size.width
            self.height = size.height
        }
    }

    public let windowFrame: RectSnapshot?
    public let contentLayoutRect: RectSnapshot?
    public let contentViewBounds: RectSnapshot?
    public let terminalBounds: RectSnapshot
    public let surfaceFrame: RectSnapshot
    public let gridFrame: RectSnapshot
    public let rows: Int
    public let cols: Int
    public let cellSize: SizeSnapshot
    public let backingScaleFactor: CGFloat?
    public let horizontalRemainder: CGFloat
    public let verticalRemainder: CGFloat
    public let metalActive: Bool
    public let metalViewFrame: RectSnapshot?
    public let metalViewBounds: RectSnapshot?
    public let metalDrawableSize: SizeSnapshot?
    public let lastPresentedFrameAgeMs: Int?

    public init(
        windowFrame: CGRect?,
        contentLayoutRect: CGRect?,
        contentViewBounds: CGRect?,
        terminalBounds: CGRect,
        geometry: TerminalRenderGeometry,
        backingScaleFactor: CGFloat?,
        metalActive: Bool,
        metalViewFrame: CGRect?,
        metalViewBounds: CGRect?,
        metalDrawableSize: CGSize?,
        lastPresentedFrameAgeMs: Int?
    ) {
        self.windowFrame = windowFrame.map(RectSnapshot.init)
        self.contentLayoutRect = contentLayoutRect.map(RectSnapshot.init)
        self.contentViewBounds = contentViewBounds.map(RectSnapshot.init)
        self.terminalBounds = RectSnapshot(terminalBounds)
        self.surfaceFrame = RectSnapshot(geometry.surfaceFrame)
        self.gridFrame = RectSnapshot(geometry.gridFrame)
        self.rows = geometry.rows
        self.cols = geometry.cols
        self.cellSize = SizeSnapshot(geometry.cellSize)
        self.backingScaleFactor = backingScaleFactor
        self.horizontalRemainder = geometry.horizontalRemainder
        self.verticalRemainder = geometry.verticalRemainder
        self.metalActive = metalActive
        self.metalViewFrame = metalViewFrame.map(RectSnapshot.init)
        self.metalViewBounds = metalViewBounds.map(RectSnapshot.init)
        self.metalDrawableSize = metalDrawableSize.map(SizeSnapshot.init)
        self.lastPresentedFrameAgeMs = lastPresentedFrameAgeMs
    }

    public func formattedLines(indent: String = "") -> [String] {
        [
            "\(indent)windowFrame: \(format(windowFrame))",
            "\(indent)contentLayoutRect: \(format(contentLayoutRect))",
            "\(indent)contentViewBounds: \(format(contentViewBounds))",
            "\(indent)terminalBounds: \(format(terminalBounds))",
            "\(indent)surfaceFrame: \(format(surfaceFrame))",
            "\(indent)gridFrame: \(format(gridFrame))",
            "\(indent)cols × rows: \(cols) × \(rows)",
            "\(indent)cellWidth × cellHeight: \(format(cellSize))",
            "\(indent)remainderX × remainderY: \(format(horizontalRemainder)) × \(format(verticalRemainder))",
            "\(indent)backingScaleFactor: \(backingScaleFactor.map(format) ?? "<nil>")",
            "\(indent)metalActive: \(metalActive)",
            "\(indent)metalViewFrame: \(format(metalViewFrame))",
            "\(indent)metalViewBounds: \(format(metalViewBounds))",
            "\(indent)metalDrawableSize: \(format(metalDrawableSize))",
            "\(indent)lastPresentedFrameAgeMs: \(lastPresentedFrameAgeMs.map(String.init) ?? "<nil>")"
        ]
    }

    public func formatted(indent: String = "") -> String {
        formattedLines(indent: indent).joined(separator: "\n")
    }

    private func format(_ rect: RectSnapshot?) -> String {
        guard let rect else { return "<nil>" }
        return format(rect)
    }

    private func format(_ rect: RectSnapshot) -> String {
        "(x:\(format(rect.x)) y:\(format(rect.y)) \(format(rect.width))x\(format(rect.height)))"
    }

    private func format(_ size: SizeSnapshot?) -> String {
        guard let size else { return "<nil>" }
        return format(size)
    }

    private func format(_ size: SizeSnapshot) -> String {
        "\(format(size.width))x\(format(size.height))"
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}
