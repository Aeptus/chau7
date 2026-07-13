import XCTest
@testable import Chau7

final class Chau7StyleTests: XCTestCase {
    func testSpacingScaleUsesRoundedGoldenRatioSteps() {
        XCTAssertEqual(Chau7Style.Spacing.xxxSmall, 2)
        XCTAssertEqual(Chau7Style.Spacing.xxSmall, 3)
        XCTAssertEqual(Chau7Style.Spacing.xSmall, 5)
        XCTAssertEqual(Chau7Style.Spacing.small, 8)
        XCTAssertEqual(Chau7Style.Spacing.medium, 13)
        XCTAssertEqual(Chau7Style.Spacing.large, 21)
        XCTAssertEqual(Chau7Style.Spacing.xLarge, 34)
        XCTAssertEqual(Chau7Style.Spacing.xxLarge, 55)
    }

    func testSettingsLayoutReadsSharedTokens() {
        XCTAssertEqual(SettingsLayout.controlSpacing, Chau7Style.Settings.rowSpacing)
        XCTAssertEqual(SettingsLayout.compactRowSpacing, Chau7Style.Settings.compactRowSpacing)
        XCTAssertEqual(SettingsLayout.settingsWindowMinWidth, Chau7Style.Settings.windowMinWidth)
        XCTAssertEqual(SettingsLayout.detailIdealWidth, Chau7Style.Settings.detailIdealWidth)
    }
}
