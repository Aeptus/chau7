import CoreGraphics

/// Shared geometry contract for terminal renderers.
///
/// The render surface fills the available terminal area, while the terminal
/// grid uses only whole cells top-aligned inside that surface. Any fractional
/// remainder stays as terminal background below/right of the final full row or
/// column, never as a partially rendered cell.
public struct TerminalRenderGeometry: Equatable {
    public struct CellCoordinate: Equatable {
        public let col: Int
        public let row: Int

        public init(col: Int, row: Int) {
            self.col = col
            self.row = row
        }
    }

    public static let defaultMaxColumns = 2000
    public static let defaultMaxRows = 500

    public let bounds: CGRect
    public let inset: CGFloat
    public let contentBounds: CGRect
    public let surfaceFrame: CGRect
    public let gridFrame: CGRect
    public let cellSize: CGSize
    public let rawCols: Int
    public let rawRows: Int
    public let cols: Int
    public let rows: Int
    public let maxCols: Int
    public let maxRows: Int

    public var canResizePTY: Bool {
        rawCols > 1 && rawRows > 1
    }

    public var isClamped: Bool {
        rawCols > maxCols || rawRows > maxRows
    }

    public var horizontalRemainder: CGFloat {
        max(0, surfaceFrame.width - CGFloat(cols) * cellSize.width)
    }

    public var verticalRemainder: CGFloat {
        max(0, surfaceFrame.height - CGFloat(rows) * cellSize.height)
    }

    public static func resolve(
        bounds: CGRect,
        inset: CGFloat,
        cellSize: CGSize,
        maxCols: Int = defaultMaxColumns,
        maxRows: Int = defaultMaxRows
    ) -> TerminalRenderGeometry {
        let safeBounds = sanitize(bounds)
        let safeInset = finiteNonNegative(inset)
        let safeCellSize = CGSize(
            width: finiteNonNegative(cellSize.width),
            height: finiteNonNegative(cellSize.height)
        )
        let safeMaxCols = max(0, maxCols)
        let safeMaxRows = max(0, maxRows)

        let contentBounds = CGRect(
            x: safeBounds.minX + safeInset,
            y: safeBounds.minY + safeInset,
            width: max(0, safeBounds.width - safeInset * 2),
            height: max(0, safeBounds.height - safeInset * 2)
        )

        let rawCols = wholeCellCount(available: contentBounds.width, cell: safeCellSize.width)
        let rawRows = wholeCellCount(available: contentBounds.height, cell: safeCellSize.height)
        let cols = min(safeMaxCols, rawCols)
        let rows = min(safeMaxRows, rawRows)

        let surfaceHeight = rows > 0 && safeCellSize.height > 0 ? contentBounds.height : 0
        let surfaceFrame = CGRect(
            x: contentBounds.minX,
            y: contentBounds.minY,
            width: contentBounds.width,
            height: surfaceHeight
        )

        let gridHeight = CGFloat(rows) * safeCellSize.height
        let gridWidth = CGFloat(cols) * safeCellSize.width
        let gridFrame = CGRect(
            x: surfaceFrame.minX,
            y: surfaceFrame.maxY - gridHeight,
            width: gridWidth,
            height: gridHeight
        )

        return TerminalRenderGeometry(
            bounds: safeBounds,
            inset: safeInset,
            contentBounds: contentBounds,
            surfaceFrame: surfaceFrame,
            gridFrame: gridFrame,
            cellSize: safeCellSize,
            rawCols: rawCols,
            rawRows: rawRows,
            cols: cols,
            rows: rows,
            maxCols: safeMaxCols,
            maxRows: safeMaxRows
        )
    }

    /// Maps an AppKit-style point (origin at bottom-left) to a visible terminal
    /// cell. Points in the fractional bottom/right remainder clamp to the final
    /// full row/column, preserving the existing mouse behavior.
    public func clampedCell(for point: CGPoint) -> CellCoordinate {
        guard cols > 0, rows > 0, cellSize.width > 0, cellSize.height > 0 else {
            return CellCoordinate(col: 0, row: 0)
        }

        let rawCol = Int((point.x - gridFrame.minX) / cellSize.width)
        let rawRow = Int((gridFrame.maxY - point.y) / cellSize.height)
        return CellCoordinate(
            col: max(0, min(rawCol, cols - 1)),
            row: max(0, min(rawRow, rows - 1))
        )
    }

    private static func sanitize(_ rect: CGRect) -> CGRect {
        CGRect(
            x: finiteOrZero(rect.minX),
            y: finiteOrZero(rect.minY),
            width: finiteNonNegative(rect.width),
            height: finiteNonNegative(rect.height)
        )
    }

    private static func wholeCellCount(available: CGFloat, cell: CGFloat) -> Int {
        guard available > 0, cell > 0 else { return 0 }
        return max(0, Int(available / cell))
    }

    private static func finiteNonNegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func finiteOrZero(_ value: CGFloat) -> CGFloat {
        value.isFinite ? value : 0
    }
}
