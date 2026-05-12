import CoreGraphics
import Foundation

/// Compact diagnostic snapshot for terminal renderer geometry.
public struct TerminalRenderSurfaceReport: Equatable {
    public struct PointSnapshot: Equatable {
        public let x: CGFloat
        public let y: CGFloat

        public init(_ point: CGPoint) {
            self.x = point.x
            self.y = point.y
        }
    }

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

    public struct CoordinatorDiagnostics: Equatable, Sendable {
        public let renderRequests: TerminalRenderRequestCoalescer.Diagnostics
        public let retry: TerminalRenderRetrySnapshot

        public init(
            renderRequests: TerminalRenderRequestCoalescer.Diagnostics,
            retry: TerminalRenderRetrySnapshot
        ) {
            self.renderRequests = renderRequests
            self.retry = retry
        }
    }

    public let windowFrame: RectSnapshot?
    public let windowContentSize: SizeSnapshot?
    public let contentLayoutRect: RectSnapshot?
    public let contentViewBounds: RectSnapshot?
    public let terminalBounds: RectSnapshot
    public let surfaceFrame: RectSnapshot
    public let gridFrame: RectSnapshot
    public let gridOrigin: PointSnapshot
    public let rawRows: Int
    public let rawCols: Int
    public let rows: Int
    public let cols: Int
    public let maxRows: Int
    public let maxCols: Int
    public let cellSize: SizeSnapshot
    public let backingScaleFactor: CGFloat?
    public let horizontalRemainder: CGFloat
    public let verticalRemainder: CGFloat
    public let remainderPixels: SizeSnapshot?
    public let metalActive: Bool
    public let metalViewFrame: RectSnapshot?
    public let metalViewBounds: RectSnapshot?
    public let metalDrawableSize: SizeSnapshot?
    public let lastPresentedFrameAgeMs: Int?
    public let coordinatorDiagnostics: CoordinatorDiagnostics?

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
        lastPresentedFrameAgeMs: Int?,
        coordinatorDiagnostics: CoordinatorDiagnostics? = nil
    ) {
        self.windowFrame = windowFrame.map(RectSnapshot.init)
        self.windowContentSize = contentLayoutRect.map { SizeSnapshot($0.size) }
        self.contentLayoutRect = contentLayoutRect.map(RectSnapshot.init)
        self.contentViewBounds = contentViewBounds.map(RectSnapshot.init)
        self.terminalBounds = RectSnapshot(terminalBounds)
        self.surfaceFrame = RectSnapshot(geometry.surfaceFrame)
        self.gridFrame = RectSnapshot(geometry.gridFrame)
        self.gridOrigin = PointSnapshot(geometry.gridOrigin)
        self.rawRows = geometry.rawRows
        self.rawCols = geometry.rawCols
        self.rows = geometry.rows
        self.cols = geometry.cols
        self.maxRows = geometry.maxRows
        self.maxCols = geometry.maxCols
        self.cellSize = SizeSnapshot(geometry.cellSize)
        self.backingScaleFactor = backingScaleFactor
        self.horizontalRemainder = geometry.horizontalRemainder
        self.verticalRemainder = geometry.verticalRemainder
        self.remainderPixels = backingScaleFactor.map {
            SizeSnapshot(geometry.remainderPixels(backingScaleFactor: $0))
        }
        self.metalActive = metalActive
        self.metalViewFrame = metalViewFrame.map(RectSnapshot.init)
        self.metalViewBounds = metalViewBounds.map(RectSnapshot.init)
        self.metalDrawableSize = metalDrawableSize.map(SizeSnapshot.init)
        self.lastPresentedFrameAgeMs = lastPresentedFrameAgeMs
        self.coordinatorDiagnostics = coordinatorDiagnostics
    }

    public func formattedLines(indent: String = "") -> [String] {
        var lines = [
            "\(indent)windowFrame: \(format(windowFrame))",
            "\(indent)windowContentSize: \(format(windowContentSize))",
            "\(indent)contentLayoutRect: \(format(contentLayoutRect))",
            "\(indent)contentViewBounds: \(format(contentViewBounds))",
            "\(indent)terminalBounds: \(format(terminalBounds))",
            "\(indent)surfaceFrame: \(format(surfaceFrame))",
            "\(indent)gridFrame: \(format(gridFrame))",
            "\(indent)gridOrigin: \(format(gridOrigin))",
            "\(indent)raw cols × rows: \(rawCols) × \(rawRows)",
            "\(indent)cols × rows: \(cols) × \(rows)",
            "\(indent)max cols × rows: \(maxCols) × \(maxRows)",
            "\(indent)cellWidth × cellHeight: \(format(cellSize))",
            "\(indent)remainderX × remainderY: \(format(horizontalRemainder)) × \(format(verticalRemainder))",
            "\(indent)remainderPixels: \(format(remainderPixels))",
            "\(indent)backingScaleFactor: \(backingScaleFactor.map(format) ?? "<nil>")",
            "\(indent)metalActive: \(metalActive)",
            "\(indent)metalViewFrame: \(format(metalViewFrame))",
            "\(indent)metalViewBounds: \(format(metalViewBounds))",
            "\(indent)metalDrawableSize: \(format(metalDrawableSize))",
            "\(indent)lastPresentedFrameAgeMs: \(lastPresentedFrameAgeMs.map(String.init) ?? "<nil>")"
        ]

        if let coordinatorDiagnostics {
            lines.append("\(indent)renderRequests: \(format(coordinatorDiagnostics.renderRequests))")
            lines.append("\(indent)retry: \(format(coordinatorDiagnostics.retry))")
        } else {
            lines.append("\(indent)renderRequests: <nil>")
            lines.append("\(indent)retry: <nil>")
        }
        return lines
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

    private func format(_ point: PointSnapshot) -> String {
        "(x:\(format(point.x)) y:\(format(point.y)))"
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

    private func format(_ diagnostics: TerminalRenderRequestCoalescer.Diagnostics) -> String {
        "pending(sync:\(diagnostics.pendingSync) present:\(diagnostics.pendingPresent) count:\(diagnostics.pendingRequestCount)) "
            + "requested(sync:\(diagnostics.syncRequestCount) present:\(diagnostics.presentRequestCount)) "
            + "coalesced(sync:\(diagnostics.coalescedSyncRequestCount) present:\(diagnostics.coalescedPresentRequestCount) total:\(diagnostics.coalescedRequestCount))"
    }

    private func format(_ retry: TerminalRenderRetrySnapshot) -> String {
        let reason = retry.lastReason?.rawValue ?? "<nil>"
        return "reason:\(reason) consecutiveFailures:\(retry.consecutiveFailureCount)"
    }
}
