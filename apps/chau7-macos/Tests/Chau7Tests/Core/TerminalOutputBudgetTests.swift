import XCTest
import Chau7Core

final class TerminalOutputBudgetTests: XCTestCase {
    func testOneHugeLineStillRespectsByteCeiling() {
        XCTAssertEqual(TerminalOutputBudget.tail(String(repeating: "a", count: 10000), maximumLines: 1, maximumBytes: 17), String(repeating: "a", count: 17))
    }

    func testUTF8BoundaryAndLineCeiling() {
        let text = "old\nnew 😀😀😀"
        for bytes in 1 ... 20 {
            let output = TerminalOutputBudget.tail(text, maximumLines: 1, maximumBytes: bytes)
            XCTAssertLessThanOrEqual(output.utf8.count, bytes)
            XCTAssertFalse(output.contains("�"))
            XCTAssertFalse(output.contains("\n"))
        }
    }

    func testEmptyAndSmallInputs() {
        XCTAssertEqual(TerminalOutputBudget.tail("a\nb\nc", maximumLines: 2, maximumBytes: 100), "b\nc")
        XCTAssertEqual(TerminalOutputBudget.tail("test", maximumLines: 1, maximumBytes: 0), "")
        XCTAssertEqual(TerminalOutputBudget.tail("", maximumLines: 1, maximumBytes: 10), "")
    }
}
