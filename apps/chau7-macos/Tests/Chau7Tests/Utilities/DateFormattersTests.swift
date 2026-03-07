import XCTest
@testable import Chau7Core

final class DateFormattersTests: XCTestCase {

    // MARK: - iso8601 Formatter

    func testISO8601FormatterParsesDateWithFractionalSeconds() {
        let dateString = "2025-01-14T12:30:45.123Z"
        let date = DateFormatters.iso8601.date(from: dateString)
        XCTAssertNotNil(date)
    }

    func testISO8601FormatterFormatsDateWithFractionalSeconds() {
        // Create a known date (2025-01-14 12:00:00 UTC)
        let date = Date(timeIntervalSince1970: 1_736_856_000)
        let formatted = DateFormatters.iso8601.string(from: date)

        XCTAssertTrue(formatted.contains("2025-01-14"))
        XCTAssertTrue(formatted.contains("T"))
        XCTAssertTrue(formatted.hasSuffix("Z"))
        // Should contain fractional seconds (dot followed by digits)
        XCTAssertTrue(formatted.contains("."))
    }

    func testISO8601FormatterRoundTrip() {
        let original = Date(timeIntervalSince1970: 1_736_856_000.456)
        let formatted = DateFormatters.iso8601.string(from: original)
        let parsed = DateFormatters.iso8601.date(from: formatted)

        XCTAssertNotNil(parsed)
        // Allow small rounding error from fractional seconds
        XCTAssertEqual(parsed!.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.01)
    }

    func testISO8601FormatterRejectsInvalidString() {
        let result = DateFormatters.iso8601.date(from: "not a date")
        XCTAssertNil(result)
    }

    func testISO8601FormatterRejectsDateWithoutTimezone() {
        let result = DateFormatters.iso8601.date(from: "2025-01-14T12:00:00")
        XCTAssertNil(result)
    }

    // MARK: - nowISO8601()

    func testNowISO8601ReturnsValidISO8601String() {
        let result = DateFormatters.nowISO8601()

        // Should be parseable back
        let date = DateFormatters.iso8601.date(from: result)
        XCTAssertNotNil(date, "nowISO8601() should return a parseable ISO8601 string")
    }

    func testNowISO8601IsRecent() {
        let result = DateFormatters.nowISO8601()
        let date = DateFormatters.iso8601.date(from: result)!

        // Should be within 2 seconds of now
        let diff = abs(date.timeIntervalSinceNow)
        XCTAssertLessThan(diff, 2.0)
    }

    func testNowISO8601ContainsExpectedFormat() {
        let result = DateFormatters.nowISO8601()

        // Should match pattern like "2025-01-14T12:00:00.000Z"
        XCTAssertTrue(result.contains("T"), "Should contain time separator")
        XCTAssertTrue(result.hasSuffix("Z"), "Should end with Z (UTC)")
        XCTAssertTrue(result.contains("."), "Should contain fractional seconds")
    }

    // MARK: - Formatter Identity

    func testISO8601FormatterIsSingleton() {
        // Accessing .iso8601 multiple times should return the same instance
        let a = DateFormatters.iso8601
        let b = DateFormatters.iso8601
        XCTAssertTrue(a === b, "iso8601 formatter should be a shared instance")
    }
}
