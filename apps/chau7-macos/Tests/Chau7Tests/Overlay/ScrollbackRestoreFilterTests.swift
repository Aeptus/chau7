import XCTest
@testable import Chau7Core

final class ScrollbackRestoreFilterTests: XCTestCase {
    func testStripRestoreArtifactsPreservesAnsiStyledContent() {
        let redLine = "\u{1B}[31mred output\u{1B}[0m"
        let greenLine = "\u{1B}[32mgreen output\u{1B}[0m"
        let artifact = "\u{1B}[2m stty -echo && cat '/tmp/chau7_restore.txt' && clear && stty echo\u{1B}[0m"

        let stripped = ScrollbackRestoreFilter.stripRestoreArtifacts(
            from: [redLine, artifact, greenLine].joined(separator: "\n")
        )

        XCTAssertTrue(stripped.contains(redLine))
        XCTAssertTrue(stripped.contains(greenLine))
        XCTAssertTrue(stripped.contains("\u{1B}[31m"))
        XCTAssertTrue(stripped.contains("\u{1B}[32m"))
        XCTAssertFalse(stripped.contains("stty -echo"))
        XCTAssertFalse(stripped.contains("chau7_restore.txt"))
    }

    func testStripRestoreArtifactsRemovesAnsiStyledBareCdArtifact() {
        let redLine = "\u{1B}[31mred output\u{1B}[0m"
        let greenLine = "\u{1B}[32mgreen output\u{1B}[0m"
        let artifact = "\u{1B}[2m%  cd '/Users/christophehenner/Downloads/Repositories/Chau7'\u{1B}[0m"

        let stripped = ScrollbackRestoreFilter.stripRestoreArtifacts(
            from: [redLine, artifact, greenLine].joined(separator: "\n")
        )

        XCTAssertTrue(stripped.contains(redLine))
        XCTAssertTrue(stripped.contains(greenLine))
        XCTAssertFalse(stripped.contains("cd '/Users/christophehenner/Downloads/Repositories/Chau7'"))
    }

    func testCaptureScrollbackPrefersStyledSnapshotWithoutPlainFallback() {
        let styled = "\u{1B}[31mred output\u{1B}[0m"
        var fallbackCalled = false

        let restored = ScrollbackRestoreFilter.captureScrollback(
            maxLines: 10,
            styledData: { Data(styled.utf8) },
            fallbackData: {
                fallbackCalled = true
                return Data("plain output".utf8)
            }
        )

        XCTAssertEqual(restored, styled)
        XCTAssertFalse(fallbackCalled)
    }

    func testCaptureScrollbackFallsBackWhenStyledSnapshotIsEmpty() {
        let restored = ScrollbackRestoreFilter.captureScrollback(
            maxLines: 10,
            styledData: { Data() },
            fallbackData: { Data("plain output".utf8) }
        )

        XCTAssertEqual(restored, "plain output")
    }

    func testScrollbackLinesWithinByteLimitDropsOldestLines() throws {
        let lines = (0 ..< 8).map { "line-\($0)-" + String(repeating: "x", count: 24) }

        let capped = try XCTUnwrap(
            ScrollbackRestoreFilter.scrollbackLinesWithinByteLimit(lines, maxBytes: 120)
        )
        let payload = capped.joined(separator: "\n")

        XCTAssertLessThanOrEqual(payload.utf8.count, 120)
        XCTAssertEqual(capped.last, lines.last)
        XCTAssertFalse(capped.contains(lines.first!))
    }

    func testScrollbackLinesWithinByteLimitRejectsSingleOversizedLine() {
        let oversized = String(repeating: "x", count: 128)

        XCTAssertNil(
            ScrollbackRestoreFilter.scrollbackLinesWithinByteLimit([oversized], maxBytes: 64)
        )
    }
}
