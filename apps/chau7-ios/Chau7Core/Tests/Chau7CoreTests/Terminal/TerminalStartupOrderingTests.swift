import XCTest
@testable import Chau7Core

final class TerminalStartupOrderingTests: XCTestCase {
    func testAppliesPaletteBeforeReplayingRestoredOutput() {
        var events: [String] = []

        TerminalStartupOrdering.applyPaletteThenReplay(
            initialOutput: "\u{001B}[31mred\u{001B}[0m",
            applyPalette: { events.append("palette") },
            replay: { output in events.append("replay:\(output)") }
        )

        XCTAssertEqual(events, ["palette", "replay:\u{001B}[31mred\u{001B}[0m"])
    }

    func testStillAppliesPaletteWithoutInitialOutput() {
        var events: [String] = []

        TerminalStartupOrdering.applyPaletteThenReplay(
            initialOutput: nil,
            applyPalette: { events.append("palette") },
            replay: { _ in events.append("replay") }
        )

        XCTAssertEqual(events, ["palette"])
    }
}
