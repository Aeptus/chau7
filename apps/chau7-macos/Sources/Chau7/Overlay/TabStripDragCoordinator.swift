import AppKit
import Chau7Core
import QuartzCore

/// Owns transient AppKit presentation for a SwiftUI tab-group drag.
/// SwiftUI remains authoritative for tab content and commits the model reorder
/// only after this coordinator tears down the snapshot.
@MainActor
final class TabStripDragCoordinator {
    private weak var scrollView: NSScrollView?
    private var dragState: TabGroupDragState?
    private var snapshotLayer: CALayer?
    private var snapshotOriginX: CGFloat = 0

    var isDragging: Bool { dragState != nil }
    var homeRange: Range<Int>? { dragState?.homeRange }
    var destinationIndex: Int? { dragState?.destinationIndex }

    func attach(to scrollView: NSScrollView?) {
        guard self.scrollView !== scrollView else { return }
        cancel()
        self.scrollView = scrollView
    }

    @discardableResult
    func begin(
        homeRange: Range<Int>,
        tabWidths: [CGFloat],
        spacing: CGFloat,
        groupFrame: CGRect,
        viewportFrame: CGRect
    ) -> Bool {
        cancel()
        guard let scrollView,
              let documentView = scrollView.documentView,
              let state = TabGroupDragState(
                  homeRange: homeRange,
                  tabWidths: tabWidths,
                  spacing: spacing
              ),
              let snapshot = makeSnapshot(
                  of: groupFrame,
                  viewportFrame: viewportFrame,
                  documentView: documentView,
                  scrollView: scrollView
              ) else {
            return false
        }

        dragState = state
        snapshotLayer = snapshot.layer
        snapshotOriginX = snapshot.layer.frame.minX
        scrollView.layer?.addSublayer(snapshot.layer)
        return true
    }

    @discardableResult
    func updatePointerTranslation(_ translation: CGFloat) -> Int? {
        guard var state = dragState else { return nil }
        state.updatePointerTranslation(translation)
        dragState = state
        moveSnapshot(to: state.effectiveTranslation)
        return state.destinationIndex
    }

    @discardableResult
    func applyScrollCompensation(_ delta: CGFloat) -> Int? {
        guard var state = dragState else { return nil }
        state.applyScrollCompensation(delta)
        dragState = state
        moveSnapshot(to: state.effectiveTranslation)
        return state.destinationIndex
    }

    func displacement(forTabAt index: Int) -> CGFloat {
        dragState?.displacement(forTabAt: index) ?? 0
    }

    func finish() -> TabGroupDragState? {
        let state = dragState
        cancel()
        return state
    }

    func cancel() {
        snapshotLayer?.removeFromSuperlayer()
        snapshotLayer = nil
        dragState = nil
        snapshotOriginX = 0
    }

    private func moveSnapshot(to translation: CGFloat) {
        guard let snapshotLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer.frame.origin.x = snapshotOriginX + translation
        CATransaction.commit()
    }

    private func makeSnapshot(
        of groupFrame: CGRect,
        viewportFrame: CGRect,
        documentView: NSView,
        scrollView: NSScrollView
    ) -> (layer: CALayer, documentRect: CGRect)? {
        guard groupFrame.width > 0,
              viewportFrame.width > 0,
              scrollView.bounds.width > 0 else { return nil }

        let clipView = scrollView.contentView
        let clipRect = CGRect(
            x: groupFrame.minX - viewportFrame.minX,
            y: 0,
            width: groupFrame.width,
            height: clipView.bounds.height
        )
        let documentRect = clipView.convert(clipRect, to: documentView)
        guard let bitmap = documentView.bitmapImageRepForCachingDisplay(in: documentRect) else {
            return nil
        }
        documentView.cacheDisplay(in: documentRect, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }

        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true

        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = scrollView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.frame = clipView.convert(clipRect, to: scrollView)
        layer.zPosition = 1_000
        return (layer, documentRect)
    }
}
