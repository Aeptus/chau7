import XCTest
import AppKit
@testable import Chau7

/// Guards the toolbar sizing contract for the tab bar.
///
/// `NSToolbarItem` allocates space for a custom view from `minSize`/`maxSize`.
/// Apple deprecated both without shipping a replacement that works for custom
/// views, so it is tempting to delete them in favour of Auto Layout — which is
/// exactly what happened in 691574be. Constraints drive the hosting view's
/// internal layout but not the item viewer's allocation, so the tab bar
/// survived the toolbar built at window creation and then collapsed to 0x0 on
/// every subsequent `recreateToolbar`, with `intrinsicContentSize` still
/// reporting the correct size the whole time. That failure is invisible to a
/// build and to every test that only inspects the SwiftUI layer, so assert the
/// allocation on the item itself.
@MainActor
final class TabBarToolbarSizingTests: XCTestCase {

    private var toolbar: NSToolbar!
    private var tabsModel: OverlayTabsModel!

    override func setUp() {
        super.setUp()
        // A unique identifier per test keeps the shared delegate's per-toolbar
        // model and hosting-view caches from leaking across cases.
        toolbar = NSToolbar(identifier: "TabBarToolbarSizingTests-\(UUID().uuidString)")
        tabsModel = OverlayTabsModel(appModel: AppModel(), restoreState: false)
        TabBarToolbarDelegate.shared.registerTabsModel(tabsModel, for: toolbar.identifier)
    }

    override func tearDown() {
        toolbar = nil
        tabsModel = nil
        super.tearDown()
    }

    /// Reads the deprecated sizing properties the same way production writes
    /// them. Going through KVC also fails loudly if AppKit ever drops the keys,
    /// which is the one future change that would silently break the tab bar.
    private func size(of item: NSToolbarItem, forKey key: String) -> NSSize? {
        (item.value(forKey: key) as? NSValue)?.sizeValue
    }

    private func makeTabBarItem() throws -> NSToolbarItem {
        let identifier = try XCTUnwrap(
            TabBarToolbarDelegate.shared.toolbarDefaultItemIdentifiers(toolbar).first,
            "The delegate must advertise a default tab bar item"
        )
        return try XCTUnwrap(
            TabBarToolbarDelegate.shared.toolbar(
                toolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            ),
            "The delegate must vend an item for its own advertised identifier"
        )
    }

    /// Asserting the exact metrics matters more than asserting "non-zero":
    /// `NSToolbarItem` reports non-zero defaults derived from its view, so a
    /// `> 0` check passes even when nothing writes the sizing at all.
    func testToolbarItemSizingTracksTheOverlayWindowWidth() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        tabsModel.overlayWindow = window

        let item = try makeTabBarItem()

        // A default derived from the hosting view cannot know the window's
        // width, so this only holds if the sizing pass actually ran.
        XCTAssertEqual(size(of: item, forKey: "maxSize")?.width, 1400)
        XCTAssertEqual(size(of: item, forKey: "minSize")?.width, 180)
        let height = try XCTUnwrap(size(of: item, forKey: "minSize")?.height)
        XCTAssertGreaterThanOrEqual(height, OverlayLayout.tabBarHeight)
    }

    func testToolbarItemSizingMatchesComputedMetrics() throws {
        let item = try makeTabBarItem()

        // With no overlay window attached the metrics are fully determined:
        // the 180pt floor for the minimum, the 800pt fallback for the maximum,
        // and the shared tab bar height for both.
        XCTAssertEqual(
            size(of: item, forKey: "minSize"),
            NSSize(width: 180, height: OverlayLayout.tabBarHeight)
        )
        XCTAssertEqual(
            size(of: item, forKey: "maxSize"),
            NSSize(width: 800, height: OverlayLayout.tabBarHeight)
        )
    }

    /// The regression only showed up on recreation, not on first construction,
    /// so re-vending the item has to be covered explicitly.
    func testToolbarItemIsResizedWhenRecreated() throws {
        _ = try makeTabBarItem()
        let recreated = try makeTabBarItem()

        XCTAssertEqual(
            size(of: recreated, forKey: "minSize"),
            NSSize(width: 180, height: OverlayLayout.tabBarHeight),
            "A recreated item must be sized, not left to AppKit's defaults"
        )
        XCTAssertEqual(
            size(of: recreated, forKey: "maxSize"),
            NSSize(width: 800, height: OverlayLayout.tabBarHeight)
        )
    }

    /// Sizing is applied before the hosting-view guard, so an item whose view
    /// is missing or of an unexpected type still gets a usable allocation
    /// rather than collapsing the bar.
    func testSizingIsAppliedIndependentlyOfTheHostedView() throws {
        let item = try makeTabBarItem()
        item.view = NSView(frame: .zero)
        // Clear the allocation so the assertion below can only pass if this
        // sizing pass rewrote it, not because item creation had already.
        item.setValue(NSValue(size: .zero), forKey: "minSize")
        item.setValue(NSValue(size: .zero), forKey: "maxSize")

        let window = NSWindow()
        window.toolbar = toolbar
        TabBarToolbarDelegate.shared.updateToolbarItemSizing(for: window)

        XCTAssertEqual(
            size(of: item, forKey: "minSize"),
            NSSize(width: 180, height: OverlayLayout.tabBarHeight)
        )
    }
}
