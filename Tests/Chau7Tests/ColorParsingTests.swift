import XCTest
@testable import Chau7Core

final class ColorParsingTests: XCTestCase {

    // MARK: - Hex Parsing Tests

    func testParseHexWithHash() {
        guard let rgb = ColorParsing.parseHex("#FF0000") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 0.0, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 0.0, accuracy: 0.001)
    }

    func testParseHexWithoutHash() {
        guard let rgb = ColorParsing.parseHex("00FF00") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb.red, 0.0, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 0.0, accuracy: 0.001)
    }

    func testParseHexBlue() {
        guard let rgb = ColorParsing.parseHex("#0000FF") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb.blue, 1.0, accuracy: 0.001)
    }

    func testParseHexWhite() {
        guard let rgb = ColorParsing.parseHex("#FFFFFF") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 1.0, accuracy: 0.001)
    }

    func testParseHexBlack() {
        guard let rgb = ColorParsing.parseHex("#000000") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb.red, 0.0, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 0.0, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 0.0, accuracy: 0.001)
    }

    func testParseHexMixedCase() {
        guard let rgb1 = ColorParsing.parseHex("#aAbBcC"),
              let rgb2 = ColorParsing.parseHex("#AABBCC") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb1.red, rgb2.red, accuracy: 0.001)
        XCTAssertEqual(rgb1.green, rgb2.green, accuracy: 0.001)
        XCTAssertEqual(rgb1.blue, rgb2.blue, accuracy: 0.001)
    }

    func testParseHexShortForm() {
        guard let rgb = ColorParsing.parseHex("#F00") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 0.0, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 0.0, accuracy: 0.001)
    }

    func testParseHexShortFormWhite() {
        guard let rgb = ColorParsing.parseHex("FFF") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 1.0, accuracy: 0.001)
    }

    func testParseHexWithWhitespace() {
        guard let rgb = ColorParsing.parseHex("  #FF0000  ") else {
            XCTFail("Failed to parse hex")
            return
        }
        XCTAssertEqual(rgb.red, 1.0, accuracy: 0.001)
    }

    func testParseHexGray() {
        guard let rgb = ColorParsing.parseHex("#808080") else {
            XCTFail("Failed to parse hex")
            return
        }
        let expected = 128.0 / 255.0
        XCTAssertEqual(rgb.red, expected, accuracy: 0.001)
        XCTAssertEqual(rgb.green, expected, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, expected, accuracy: 0.001)
    }

    // MARK: - Invalid Hex Tests

    func testParseInvalidHexTooShort() {
        XCTAssertNil(ColorParsing.parseHex("#FF"))
        XCTAssertNil(ColorParsing.parseHex("AB"))
    }

    func testParseInvalidHexTooLong() {
        XCTAssertNil(ColorParsing.parseHex("#FF00FF00"))
    }

    func testParseInvalidHexCharacters() {
        XCTAssertNil(ColorParsing.parseHex("#GGGGGG"))
        XCTAssertNil(ColorParsing.parseHex("#ZZZ"))
    }

    func testParseEmptyHex() {
        XCTAssertNil(ColorParsing.parseHex(""))
        XCTAssertNil(ColorParsing.parseHex("#"))
    }

    // MARK: - Hex Conversion Tests

    func testToHexRed() {
        let hex = ColorParsing.toHex(ColorParsing.RGB(red: 1.0, green: 0.0, blue: 0.0))
        XCTAssertEqual(hex, "#FF0000")
    }

    func testToHexGreen() {
        let hex = ColorParsing.toHex(ColorParsing.RGB(red: 0.0, green: 1.0, blue: 0.0))
        XCTAssertEqual(hex, "#00FF00")
    }

    func testToHexBlue() {
        let hex = ColorParsing.toHex(ColorParsing.RGB(red: 0.0, green: 0.0, blue: 1.0))
        XCTAssertEqual(hex, "#0000FF")
    }

    func testRoundTrip() {
        let original = "#3B8EEA"
        guard let rgb = ColorParsing.parseHex(original) else {
            XCTFail("Failed to parse hex")
            return
        }
        let result = ColorParsing.toHex(rgb)
        XCTAssertEqual(result, original)
    }

    // MARK: - Validation Tests

    func testIsValidHex() {
        XCTAssertTrue(ColorParsing.isValidHex("#FF0000"))
        XCTAssertTrue(ColorParsing.isValidHex("00FF00"))
        XCTAssertTrue(ColorParsing.isValidHex("#FFF"))
        XCTAssertFalse(ColorParsing.isValidHex("invalid"))
        XCTAssertFalse(ColorParsing.isValidHex("#GGG"))
    }

    // MARK: - Luminance Tests

    func testLuminanceWhite() {
        let lum = ColorParsing.luminance(ColorParsing.RGB(red: 1.0, green: 1.0, blue: 1.0))
        XCTAssertEqual(lum, 1.0, accuracy: 0.001)
    }

    func testLuminanceBlack() {
        let lum = ColorParsing.luminance(ColorParsing.RGB(red: 0.0, green: 0.0, blue: 0.0))
        XCTAssertEqual(lum, 0.0, accuracy: 0.001)
    }

    func testLuminanceGreenHigher() {
        // Green contributes most to luminance
        let redLum = ColorParsing.luminance(ColorParsing.RGB(red: 1.0, green: 0.0, blue: 0.0))
        let greenLum = ColorParsing.luminance(ColorParsing.RGB(red: 0.0, green: 1.0, blue: 0.0))
        let blueLum = ColorParsing.luminance(ColorParsing.RGB(red: 0.0, green: 0.0, blue: 1.0))
        XCTAssertGreaterThan(greenLum, redLum)
        XCTAssertGreaterThan(greenLum, blueLum)
    }

    // MARK: - Is Light Tests

    func testIsLightWhite() {
        XCTAssertTrue(ColorParsing.isLight(ColorParsing.RGB(red: 1.0, green: 1.0, blue: 1.0)))
    }

    func testIsLightBlack() {
        XCTAssertFalse(ColorParsing.isLight(ColorParsing.RGB(red: 0.0, green: 0.0, blue: 0.0)))
    }

    func testIsLightYellow() {
        guard let rgb = ColorParsing.parseHex("#FFFF00") else {
            XCTFail("Failed to parse")
            return
        }
        XCTAssertTrue(ColorParsing.isLight(rgb))
    }

    func testIsLightDarkBlue() {
        guard let rgb = ColorParsing.parseHex("#000080") else {
            XCTFail("Failed to parse")
            return
        }
        XCTAssertFalse(ColorParsing.isLight(rgb))
    }

    // MARK: - Brightness Adjustment Tests

    func testAdjustBrightnessDarker() {
        let original = ColorParsing.RGB(red: 0.8, green: 0.8, blue: 0.8)
        let darker = ColorParsing.adjustBrightness(original, factor: 0.5)
        XCTAssertEqual(darker.red, 0.4, accuracy: 0.001)
        XCTAssertEqual(darker.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(darker.blue, 0.4, accuracy: 0.001)
    }

    func testAdjustBrightnessBrighter() {
        let original = ColorParsing.RGB(red: 0.4, green: 0.4, blue: 0.4)
        let brighter = ColorParsing.adjustBrightness(original, factor: 2.0)
        XCTAssertEqual(brighter.red, 0.8, accuracy: 0.001)
        XCTAssertEqual(brighter.green, 0.8, accuracy: 0.001)
        XCTAssertEqual(brighter.blue, 0.8, accuracy: 0.001)
    }

    func testAdjustBrightnessClamped() {
        let original = ColorParsing.RGB(red: 0.8, green: 0.8, blue: 0.8)
        let brighter = ColorParsing.adjustBrightness(original, factor: 2.0)
        XCTAssertEqual(brighter.red, 1.0, accuracy: 0.001) // Clamped
        XCTAssertEqual(brighter.green, 1.0, accuracy: 0.001)
        XCTAssertEqual(brighter.blue, 1.0, accuracy: 0.001)
    }

    // MARK: - RGB Init Tests

    func testRGBInitFromIntegers() {
        let rgb = ColorParsing.RGB(r: 255, g: 128, b: 0)
        XCTAssertEqual(rgb.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 128.0/255.0, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 0.0, accuracy: 0.001)
    }
}
