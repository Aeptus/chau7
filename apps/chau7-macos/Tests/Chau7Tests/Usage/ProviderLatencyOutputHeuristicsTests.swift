import XCTest
@testable import Chau7Core

final class ProviderLatencyOutputHeuristicsTests: XCTestCase {
    func testRejectsControlOnlyOutput() {
        let data = Data("\u{1b}[2K\r".utf8)
        XCTAssertFalse(ProviderLatencyOutputHeuristics.hasMeaningfulFirstResponseText(in: data))
    }

    func testRejectsSpinnerOnlyOutput() {
        let data = Data("⠋⠙⠹".utf8)
        XCTAssertFalse(ProviderLatencyOutputHeuristics.hasMeaningfulFirstResponseText(in: data))
    }

    func testAcceptsVisibleModelText() {
        let data = Data("Thinking about that…".utf8)
        XCTAssertTrue(ProviderLatencyOutputHeuristics.hasMeaningfulFirstResponseText(in: data))
    }

    func testAcceptsAnsiWrappedVisibleText() {
        let data = Data("\u{1b}[32mAnswer ready\u{1b}[0m".utf8)
        XCTAssertTrue(ProviderLatencyOutputHeuristics.hasMeaningfulFirstResponseText(in: data))
    }
}
