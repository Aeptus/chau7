import XCTest
@testable import Chau7

/// SPM-runnable regression tests for `OverlayTab.==`.
///
/// `OverlayTab` is a struct used as a child-view input in the SwiftUI
/// tab bar. SwiftUI uses Equatable-equality to decide whether a child
/// view needs to re-render when its parent invalidates. If a field
/// rendered into the tab chip is missing from `==`, mutations to that
/// field appear "equal" to the diffing engine and the on-screen chip
/// stays stale — exactly the rename bug that motivated these tests.
///
/// Each test mutates a single display-affecting field on a copy of a
/// baseline tab and asserts the copy is `!=` the baseline. If a future
/// refactor accidentally drops a comparison, the test fails with a
/// clear name pointing at the dropped field.
final class OverlayTabEquatableTests: XCTestCase {

    /// id mismatch ⇒ unequal. Sanity baseline.
    func testDifferentIdIsUnequal() {
        let appModel = AppModel()
        let a = OverlayTab(appModel: appModel)
        let b = OverlayTab(appModel: appModel)
        XCTAssertNotEqual(a, b, "Different ids must compare unequal")
    }

    /// Same id, same fields ⇒ equal. Sanity baseline.
    func testSameTabEqualsItself() {
        let appModel = AppModel()
        let tab = OverlayTab(appModel: appModel)
        XCTAssertEqual(tab, tab)
    }

    // MARK: - Display-affecting fields (the rename-bug surface)

    /// customTitle mismatch ⇒ unequal. THE rename bug.
    func testCustomTitleChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.customTitle = "Original"
        b.customTitle = "Renamed"
        XCTAssertNotEqual(a, b, "customTitle must be in == — otherwise renames are silently diffed-equal")
    }

    /// nil → set is the most common rename path (first-time rename).
    func testCustomTitleNilToSetMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.customTitle = nil
        b.customTitle = "First Rename"
        XCTAssertNotEqual(a, b)
    }

    /// color mismatch ⇒ unequal. Tab color picker target.
    func testColorChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.color = .blue
        b.color = .orange
        XCTAssertNotEqual(a, b)
    }

    /// autoColor mismatch ⇒ unequal. F05 auto-tab-theme target.
    func testAutoColorChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.autoColor = nil
        b.autoColor = .green
        XCTAssertNotEqual(a, b)
    }

    /// isManualColorOverride mismatch ⇒ unequal. Set when the user
    /// chooses a color via the rename dialog (overrides F05 auto-color).
    func testIsManualColorOverrideChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.isManualColorOverride = false
        b.isManualColorOverride = true
        XCTAssertNotEqual(a, b)
    }

    /// lastCommand mismatch ⇒ unequal. F20 last-command badge.
    func testLastCommandChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.lastCommand = nil
        b.lastCommand = LastCommandInfo(
            command: "git status",
            startTime: Date(),
            endTime: Date(),
            exitCode: 0
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Pre-existing covered fields (regression guard)

    func testNotificationStyleChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.notificationStyle = nil
        b.notificationStyle = .error
        XCTAssertNotEqual(a, b)
    }

    func testRepoGroupIDChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.repoGroupID = nil
        b.repoGroupID = "/Users/x/repos/Chau7"
        XCTAssertNotEqual(a, b)
    }

    func testTokenOptOverrideChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.tokenOptOverride = .default
        b.tokenOptOverride = .forceOff
        XCTAssertNotEqual(a, b)
    }

    func testIsMCPControlledChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.isMCPControlled = false
        b.isMCPControlled = true
        XCTAssertNotEqual(a, b)
    }

    func testHasInheritedRepoGroupChangeMakesUnequal() {
        let appModel = AppModel()
        var a = OverlayTab(appModel: appModel)
        var b = a
        a.hasInheritedRepoGroup = false
        b.hasInheritedRepoGroup = true
        XCTAssertNotEqual(a, b)
    }
}
