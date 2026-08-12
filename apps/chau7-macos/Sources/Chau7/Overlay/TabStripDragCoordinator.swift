import AppKit
import Chau7Core
import QuartzCore

/// Owns transient AppKit presentation for a SwiftUI tab-group drag.
/// SwiftUI remains authoritative for tab content and commits the model reorder
/// only after this coordinator tears down the snapshot.
@MainActor
final class TabStripDragCoordinator: NSObject {
    private weak var scrollView: NSScrollView?
    private var dragState: TabGroupDragState?
    private var snapshotLayer: CALayer?
    private var snapshotOriginX: CGFloat = 0
    private var dragOriginScreenX: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var onDestinationChange: ((Int) -> Void)?
    private var onCancellation: (() -> Void)?

    var isDragging: Bool { dragState != nil }
    var homeRange: Range<Int>? { dragState?.homeRange }
    var destinationIndex: Int? { dragState?.destinationIndex }

    func attach(to scrollView: NSScrollView?) {
        guard self.scrollView !== scrollView else { return }
        cancel(notify: isDragging)
        self.scrollView = scrollView
    }

    @discardableResult
    func begin(
        homeRange: Range<Int>,
        tabWidths: [CGFloat],
        spacing: CGFloat,
        groupFrame: CGRect,
        viewportFrame: CGRect,
        initialPointerTranslation: CGFloat,
        onDestinationChange: @escaping (Int) -> Void,
        onCancellation: @escaping () -> Void
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
        dragOriginScreenX = NSEvent.mouseLocation.x - initialPointerTranslation
        self.onDestinationChange = onDestinationChange
        self.onCancellation = onCancellation
        scrollView.layer?.addSublayer(snapshot.layer)
        startDisplayLink(for: scrollView)
        return true
    }

    @discardableResult
    func updatePointerTranslation(_ translation: CGFloat) -> Int? {
        guard var state = dragState else { return nil }
        let previousDestination = state.destinationIndex
        state.updatePointerTranslation(translation)
        dragState = state
        moveSnapshot(to: state.effectiveTranslation)
        publishDestinationChange(from: previousDestination, to: state.destinationIndex)
        return state.destinationIndex
    }

    @discardableResult
    func applyScrollCompensation(_ delta: CGFloat) -> Int? {
        guard var state = dragState else { return nil }
        let previousDestination = state.destinationIndex
        state.applyScrollCompensation(delta)
        dragState = state
        moveSnapshot(to: state.effectiveTranslation)
        publishDestinationChange(from: previousDestination, to: state.destinationIndex)
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
        cancel(notify: false)
    }

    private func cancel(notify: Bool) {
        let cancellation = notify ? onCancellation : nil
        displayLink?.invalidate()
        displayLink = nil
        snapshotLayer?.removeFromSuperlayer()
        snapshotLayer = nil
        dragState = nil
        snapshotOriginX = 0
        dragOriginScreenX = 0
        onDestinationChange = nil
        onCancellation = nil
        cancellation?()
    }

    private func startDisplayLink(for scrollView: NSScrollView) {
        let link = scrollView.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard let scrollView,
              scrollView.window != nil,
              scrollView.documentView != nil,
              snapshotLayer?.superlayer != nil else {
            cancel(notify: true)
            return
        }

        let pointer = NSEvent.mouseLocation
        updatePointerTranslation(pointer.x - dragOriginScreenX)
        autoScrollIfNeeded(pointer: pointer, in: scrollView)
    }

    private func autoScrollIfNeeded(pointer: CGPoint, in scrollView: NSScrollView) {
        guard let window = scrollView.window, let documentView = scrollView.documentView else { return }

        let clipView = scrollView.contentView
        let viewportInWindow = clipView.convert(clipView.bounds, to: nil)
        let requestedDelta = TabDragLayout.edgeAutoScrollDelta(
            pointer: pointer,
            viewport: window.convertToScreen(viewportInWindow)
        )
        guard requestedDelta != 0 else { return }

        let appliedDelta = TabDragLayout.clampedAutoScrollDelta(
            requestedDelta: requestedDelta,
            currentOrigin: clipView.bounds.origin.x,
            contentWidth: documentView.bounds.width,
            viewportWidth: clipView.bounds.width
        )
        guard abs(appliedDelta) > 0.01 else { return }

        clipView.scroll(
            to: CGPoint(
                x: clipView.bounds.origin.x + appliedDelta,
                y: clipView.bounds.origin.y
            )
        )
        scrollView.reflectScrolledClipView(clipView)
        applyScrollCompensation(appliedDelta)
    }

    private func publishDestinationChange(from previous: Int, to destination: Int) {
        guard destination != previous else { return }
        onDestinationChange?(destination)
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
