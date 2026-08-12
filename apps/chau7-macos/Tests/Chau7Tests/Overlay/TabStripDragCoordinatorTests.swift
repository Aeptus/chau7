import AppKit
import XCTest
@testable import Chau7

@MainActor
final class TabStripDragCoordinatorTests: XCTestCase {
    func testAttachedSnapshotFinishesAsSingleTransactionForWindowDrop() throws {
        let fixture = makeFixture()
        let coordinator = TabStripDragCoordinator()
        coordinator.attach(to: fixture.scrollView)

        XCTAssertTrue(beginDrag(with: coordinator))
        XCTAssertTrue(coordinator.isDragging)
        XCTAssertTrue(fixture.scrollView.layer?.sublayers?.contains(where: { $0.zPosition == 1_000 }) == true)

        coordinator.updatePointerTranslation(300)
        let transaction = try XCTUnwrap(coordinator.finish())

        XCTAssertEqual(transaction.homeRange, 1 ..< 3)
        XCTAssertGreaterThan(transaction.destinationIndex, transaction.homeRange.lowerBound)
        XCTAssertFalse(coordinator.isDragging)
        XCTAssertFalse(fixture.scrollView.layer?.sublayers?.contains(where: { $0.zPosition == 1_000 }) == true)
    }

    func testDisplayStepAutoscrollsAttachedOverflowingView() {
        let fixture = makeFixture()
        let coordinator = TabStripDragCoordinator()
        coordinator.attach(to: fixture.scrollView)
        XCTAssertTrue(beginDrag(with: coordinator))

        let clipView = fixture.scrollView.contentView
        let viewport = fixture.window.convertToScreen(clipView.convert(clipView.bounds, to: nil))
        coordinator.displayLinkStep(pointer: CGPoint(x: viewport.maxX + 10, y: viewport.midY))

        XCTAssertGreaterThan(clipView.bounds.origin.x, 0)
        coordinator.cancel()
    }

    func testDetachedViewCancelsPresentationAndNotifiesOwner() {
        let fixture = makeFixture()
        let coordinator = TabStripDragCoordinator()
        coordinator.attach(to: fixture.scrollView)
        var cancellationCount = 0
        XCTAssertTrue(beginDrag(with: coordinator) { cancellationCount += 1 })

        fixture.scrollView.removeFromSuperview()
        coordinator.displayLinkStep(pointer: .zero)

        XCTAssertFalse(coordinator.isDragging)
        XCTAssertEqual(cancellationCount, 1)
    }

    private func beginDrag(
        with coordinator: TabStripDragCoordinator,
        onCancellation: @escaping () -> Void = {}
    ) -> Bool {
        coordinator.begin(
            homeRange: 1 ..< 3,
            tabWidths: [80, 100, 100, 90],
            spacing: 8,
            groupFrame: CGRect(x: 88, y: 0, width: 208, height: 40),
            viewportFrame: CGRect(x: 0, y: 0, width: 300, height: 40),
            initialPointerTranslation: 0,
            onDestinationChange: { _ in },
            onCancellation: onCancellation
        )
    }

    private func makeFixture() -> (window: NSWindow, scrollView: NSScrollView) {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 300, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        let documentView = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 40))
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        scrollView.documentView = documentView
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(scrollView)
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, scrollView)
    }
}
