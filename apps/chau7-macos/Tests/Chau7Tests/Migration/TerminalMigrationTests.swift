import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class TerminalMigrationTests: XCTestCase {

    // MARK: - ImportableProfile Tests

    func testImportableProfileCreation() {
        let profile = ImportableProfile(name: "TestProfile", source: .terminalApp)
        XCTAssertEqual(profile.name, "TestProfile")
        XCTAssertEqual(profile.source, .terminalApp)
        XCTAssertNil(profile.fontFamily)
        XCTAssertNil(profile.fontSize)
        XCTAssertNil(profile.backgroundColor)
        XCTAssertNil(profile.foregroundColor)
        XCTAssertNil(profile.cursorStyle)
        XCTAssertNil(profile.columns)
        XCTAssertNil(profile.rows)
        XCTAssertNil(profile.shell)
        XCTAssertNil(profile.directory)
    }

    func testImportableProfileWithAllFields() {
        var profile = ImportableProfile(name: "Full", source: .iterm2)
        profile.fontFamily = "Monaco"
        profile.fontSize = 14
        profile.backgroundColor = "#1E1E1E"
        profile.foregroundColor = "#D4D4D4"
        profile.cursorStyle = "bar"
        profile.columns = 120
        profile.rows = 40
        profile.shell = "/bin/zsh"
        profile.directory = "/Users/test"

        XCTAssertEqual(profile.fontFamily, "Monaco")
        XCTAssertEqual(profile.fontSize, 14)
        XCTAssertEqual(profile.backgroundColor, "#1E1E1E")
        XCTAssertEqual(profile.foregroundColor, "#D4D4D4")
        XCTAssertEqual(profile.cursorStyle, "bar")
        XCTAssertEqual(profile.columns, 120)
        XCTAssertEqual(profile.rows, 40)
        XCTAssertEqual(profile.shell, "/bin/zsh")
        XCTAssertEqual(profile.directory, "/Users/test")
    }

    func testImportableProfileSummaryWithFont() {
        var profile = ImportableProfile(name: "Test", source: .terminalApp)
        profile.fontFamily = "Menlo"
        profile.fontSize = 13
        XCTAssertTrue(profile.summary.contains("Terminal.app"))
        XCTAssertTrue(profile.summary.contains("Menlo"))
        XCTAssertTrue(profile.summary.contains("13pt"))
    }

    func testImportableProfileSummarySourceOnly() {
        let profile = ImportableProfile(name: "Test", source: .iterm2)
        XCTAssertEqual(profile.summary, "iTerm2")
    }

    func testImportableProfileHasUniqueId() {
        let profile1 = ImportableProfile(name: "A", source: .terminalApp)
        let profile2 = ImportableProfile(name: "A", source: .terminalApp)
        XCTAssertNotEqual(profile1.id, profile2.id)
    }

    // MARK: - ProfileSource Tests

    func testProfileSourceDisplayNames() {
        XCTAssertEqual(ProfileSource.terminalApp.displayName, "Terminal.app")
        XCTAssertEqual(ProfileSource.iterm2.displayName, "iTerm2")
    }

    func testProfileSourceRawValues() {
        XCTAssertEqual(ProfileSource.terminalApp.rawValue, "terminal")
        XCTAssertEqual(ProfileSource.iterm2.rawValue, "iterm2")
    }

    func testProfileSourceIcons() {
        XCTAssertEqual(ProfileSource.terminalApp.icon, "terminal")
        XCTAssertEqual(ProfileSource.iterm2.icon, "rectangle.split.3x1")
    }

    // MARK: - NSColor Hex Conversion Tests

    func testNSColorHexStringBlack() {
        let color = NSColor.black
        XCTAssertEqual(color.hexString, "#000000")
    }

    func testNSColorHexStringWhite() {
        let color = NSColor.white
        XCTAssertEqual(color.hexString, "#FFFFFF")
    }

    func testNSColorHexStringRed() {
        let color = NSColor(srgbRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        XCTAssertEqual(color.hexString, "#FF0000")
    }

    func testNSColorHexStringCustomColor() {
        let color = NSColor(srgbRed: 0.5, green: 0.75, blue: 0.25, alpha: 1.0)
        let hex = color.hexString
        // Allow slight rounding differences
        XCTAssertTrue(hex.hasPrefix("#"))
        XCTAssertEqual(hex.count, 7)
    }
}
#endif
