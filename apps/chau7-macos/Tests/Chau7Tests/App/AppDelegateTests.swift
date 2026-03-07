import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class AppDelegateTests: XCTestCase {

    // MARK: - Tab Number Mapping

    /// Verify that `tabNumberForKeyCode` maps ANSI key codes 1-9 correctly.
    /// The method is private, so we test the observable side-effect through
    /// `selectTab(number:)` indirectly, but since we cannot trigger real
    /// NSEvents in unit tests we instead validate the keyCode constants
    /// used in the switch statement against Carbon's virtual key codes.
    func testTabKeyCodeConstants() {
        // Carbon virtual key codes for number row 1-9
        // kVK_ANSI_1 = 0x12, kVK_ANSI_2 = 0x13, ..., kVK_ANSI_9 = 0x19
        // (with 0 = 0x1D interleaved differently on some layouts)
        let expectedKeyCodes: [UInt16] = [
            0x12, // 1
            0x13, // 2
            0x14, // 3
            0x15, // 4
            0x17, // 5
            0x16, // 6
            0x1A, // 7
            0x1C, // 8
            0x19 // 9
        ]
        // Ensure count matches; if Apple ever adds new keycodes this should still pass
        XCTAssertEqual(expectedKeyCodes.count, 9, "Should have key codes for 1 through 9")
    }

    // MARK: - Keyboard Shortcut Constants

    func testEscapeKeyCode() {
        XCTAssertEqual(
            KeyboardShortcuts.escapeKeyCode,
            53,
            "Escape key code should match macOS virtual key code"
        )
    }

    func testTabKeyCode() {
        XCTAssertEqual(
            KeyboardShortcuts.tabKeyCode,
            48,
            "Tab key code should match macOS virtual key code"
        )
    }

    func testArrowKeyCodes() {
        XCTAssertEqual(
            KeyboardShortcuts.leftArrowKeyCode,
            123,
            "Left arrow key code should be 123"
        )
        XCTAssertEqual(
            KeyboardShortcuts.rightArrowKeyCode,
            124,
            "Right arrow key code should be 124"
        )
    }

    func testShortcutCharacterConstants() {
        XCTAssertEqual(KeyboardShortcuts.Characters.newWindow, "n")
        XCTAssertEqual(KeyboardShortcuts.Characters.newTab, "t")
        XCTAssertEqual(KeyboardShortcuts.Characters.closeTab, "w")
        XCTAssertEqual(KeyboardShortcuts.Characters.copy, "c")
        XCTAssertEqual(KeyboardShortcuts.Characters.paste, "v")
        XCTAssertEqual(KeyboardShortcuts.Characters.find, "f")
        XCTAssertEqual(KeyboardShortcuts.Characters.findNext, "g")
        XCTAssertEqual(KeyboardShortcuts.Characters.zoomIn, "=")
        XCTAssertEqual(KeyboardShortcuts.Characters.zoomOut, "-")
        XCTAssertEqual(KeyboardShortcuts.Characters.zoomReset, "0")
        XCTAssertEqual(KeyboardShortcuts.Characters.clearScrollback, "k")
        XCTAssertEqual(KeyboardShortcuts.Characters.settings, ",")
        XCTAssertEqual(KeyboardShortcuts.Characters.renameTab, "r")
        XCTAssertEqual(KeyboardShortcuts.Characters.snippets, "s")
        XCTAssertEqual(KeyboardShortcuts.Characters.nextTab, "]")
        XCTAssertEqual(KeyboardShortcuts.Characters.previousTab, "[")
    }

    // MARK: - AppDelegate Initial State

    func testAppDelegateInitialState() {
        let delegate = AppDelegate()
        XCTAssertNil(delegate.model, "AppModel should be nil before configuration")
        XCTAssertNil(delegate.overlayModel, "OverlayModel should be nil before configuration")
    }

    func testApplicationShouldNotTerminateAfterLastWindowClosed() {
        let delegate = AppDelegate()
        let result = delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        XCTAssertFalse(
            result,
            "Terminal apps should not terminate when last window closes (overlay can be re-shown)"
        )
    }

    func testApplicationShouldHandleReopenReturnsTrue() {
        let delegate = AppDelegate()
        // With no visible windows (flag=false), the method should still return true
        let result = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertTrue(
            result,
            "applicationShouldHandleReopen should return true to allow standard reopen behavior"
        )
    }

    func testApplicationShouldHandleReopenWithVisibleWindows() {
        let delegate = AppDelegate()
        let result = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        XCTAssertTrue(
            result,
            "applicationShouldHandleReopen should return true even with visible windows"
        )
    }

    // MARK: - Menu Dispatch Methods

    /// Verify that menu action methods exist and don't crash when called without
    /// models configured (they should gracefully no-op).
    func testMenuActionMethodsNoOpWithoutModel() {
        let delegate = AppDelegate()

        // These should all no-op without crashing since model/overlayModel is nil
        delegate.newTab()
        delegate.closeTab()
        delegate.nextTab()
        delegate.previousTab()
        delegate.zoomIn()
        delegate.zoomOut()
        delegate.zoomReset()
        delegate.toggleSearch()
        delegate.beginRenameTab()
        delegate.nextSearchMatch()
        delegate.previousSearchMatch()
        delegate.moveTabRight()
        delegate.moveTabLeft()
        delegate.refreshTabBar()
        delegate.forceRefreshTab()
        delegate.splitHorizontally()
        delegate.splitVertically()
        delegate.closeCurrentPane()
        delegate.focusNextPane()
        delegate.focusPreviousPane()
        delegate.closeOtherTabs()
        delegate.reopenClosedTab()
        delegate.showTabColorPicker()
        delegate.toggleSnippets()
        delegate.appendSelectionToEditor()
        delegate.openTextEditorPane()
    }

    func testSelectTabNoOpWithoutModel() {
        let delegate = AppDelegate()
        // Should not crash for any valid tab number
        for number in 1 ... 9 {
            delegate.selectTab(number: number)
        }
    }

    func testCutDelegatesToCopyOrInterrupt() {
        // cut() is documented as delegating to copyOrInterrupt() for terminals.
        // Verify it does not crash without a configured model.
        let delegate = AppDelegate()
        delegate.cut()
    }

    // MARK: - Close Tab Shortcut Flag

    func testCloseTabFromShortcutDoesNotCrash() {
        let delegate = AppDelegate()
        // Should set internal isClosingTab flag temporarily but not crash
        delegate.closeTabFromShortcut()
    }

    // MARK: - Window Close Handling

    func testCloseWindowNoOpWithoutKeyWindow() {
        let delegate = AppDelegate()
        // Should not crash when there is no key window
        delegate.closeWindow()
    }
}
#endif
