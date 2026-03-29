import XCTest
@testable import Chau7Core

final class HistorySummarySanitizerTests: XCTestCase {
    func testDropsSuspiciouslyShortNonExitSummary() {
        XCTAssertEqual(HistorySummarySanitizer.sanitize("rror", isExit: false), "")
    }

    func testPreservesExitSummaryEvenWhenShort() {
        XCTAssertEqual(HistorySummarySanitizer.sanitize("err", isExit: true), "err")
    }

    func testPreservesNormalSummary() {
        XCTAssertEqual(HistorySummarySanitizer.sanitize("Error", isExit: false), "Error")
    }

    func testSanitizesEscapeSequencesBeforeLengthCheck() {
        let raw = "\u{001B}[31mrror\u{001B}[0m"
        XCTAssertEqual(HistorySummarySanitizer.sanitize(raw, isExit: false), "")
    }
}
