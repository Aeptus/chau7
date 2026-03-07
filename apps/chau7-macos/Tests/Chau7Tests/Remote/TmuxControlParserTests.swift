import XCTest
@testable import Chau7Core

final class TmuxControlParserTests: XCTestCase {

    // MARK: - Begin/End/Error

    func testParseBegin() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%begin 1234567890 1 0")
        XCTAssertEqual(result, .begin(1_234_567_890, 1))
    }

    func testParseEnd() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%end 1234567890 1 0")
        XCTAssertEqual(result, .end(1_234_567_890, 1))
    }

    func testParseError() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%error 1234567890 1 0")
        XCTAssertEqual(result, .error(1_234_567_890, 1, "0"))
    }

    func testParseErrorWithMessage() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%error 100 2 session not found")
        XCTAssertEqual(result, .error(100, 2, "session not found"))
    }

    // MARK: - Session Changed

    func testParseSessionChanged() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%session-changed $1 main")
        XCTAssertEqual(result, .sessionChanged("$1", "main"))
    }

    // MARK: - Window Add/Close

    func testParseWindowAdd() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%window-add @0")
        XCTAssertEqual(result, .windowAdd("@0"))
    }

    func testParseWindowClose() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%window-close @3")
        XCTAssertEqual(result, .windowClose("@3"))
    }

    // MARK: - Output

    func testParseOutput() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%output %0 hello world")
        XCTAssertEqual(result, .output("%0", "hello world"))
    }

    func testParseOutputEmptyData() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%output %1")
        XCTAssertEqual(result, .output("%1", ""))
    }

    // MARK: - Layout Change

    func testParseLayoutChange() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%layout-change @0 34b7,80x24,0,0,0")
        XCTAssertEqual(result, .layoutChange("@0", "34b7,80x24,0,0,0"))
    }

    // MARK: - Exit

    func testParseExitWithReason() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%exit client-detached")
        XCTAssertEqual(result, .exit("client-detached"))
    }

    func testParseExitWithoutReason() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%exit")
        XCTAssertEqual(result, .exit(nil))
    }

    // MARK: - Unknown Lines

    func testParseUnknownNotification() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%unknown-command foo")
        XCTAssertEqual(result, .unknown("%unknown-command foo"))
    }

    func testParseNonNotificationLine() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("some regular output")
        XCTAssertEqual(result, .unknown("some regular output"))
    }

    func testParseEmptyLine() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("")
        XCTAssertEqual(result, .unknown(""))
    }

    // MARK: - Block Content Accumulation

    func testBlockContentAccumulation() {
        let parser = TmuxControlParser()
        _ = parser.parseLine("%begin 100 1 0")
        XCTAssertNotNil(parser.blockContent)
        XCTAssertEqual(parser.blockContent?.count, 0)

        _ = parser.parseLine("line 1")
        _ = parser.parseLine("line 2")
        XCTAssertEqual(parser.blockContent?.count, 2)
        XCTAssertEqual(parser.blockContent?[0], "line 1")
        XCTAssertEqual(parser.blockContent?[1], "line 2")

        _ = parser.parseLine("%end 100 1 0")
        XCTAssertNil(parser.blockContent)
    }

    func testBlockContentClearedOnError() {
        let parser = TmuxControlParser()
        _ = parser.parseLine("%begin 100 1 0")
        _ = parser.parseLine("data line")
        _ = parser.parseLine("%error 100 1 something went wrong")
        XCTAssertNil(parser.blockContent)
    }

    func testNoBlockContentOutsideBlock() {
        let parser = TmuxControlParser()
        XCTAssertNil(parser.blockContent)
        _ = parser.parseLine("random line")
        XCTAssertNil(parser.blockContent)
    }

    // MARK: - Edge Cases

    func testBeginWithMinimalFields() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%begin")
        XCTAssertEqual(result, .begin(0, 0))
    }

    func testEndWithMinimalFields() {
        let parser = TmuxControlParser()
        let result = parser.parseLine("%end")
        XCTAssertEqual(result, .end(0, 0))
    }

    func testSequenceOfNotifications() {
        let parser = TmuxControlParser()
        XCTAssertEqual(parser.parseLine("%session-changed $0 dev"), .sessionChanged("$0", "dev"))
        XCTAssertEqual(parser.parseLine("%window-add @0"), .windowAdd("@0"))
        XCTAssertEqual(parser.parseLine("%window-add @1"), .windowAdd("@1"))
        XCTAssertEqual(parser.parseLine("%window-close @0"), .windowClose("@0"))
        XCTAssertEqual(parser.parseLine("%exit"), .exit(nil))
    }
}
