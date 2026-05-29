import XCTest
@testable import Chau7

final class RestorationScrollbackCaptureTests: XCTestCase {
    func testBoundedTailSnapshotDoesNotFallBackToFullBufferWhenEmpty() {
        var styledCalled = false
        var fallbackCalled = false

        let restored = TerminalSessionModel.captureRestorationScrollbackContent(
            maxLines: 10,
            tailData: Data(),
            styledData: {
                styledCalled = true
                return Data("full styled snapshot".utf8)
            },
            fallbackData: {
                fallbackCalled = true
                return Data("plain fallback snapshot".utf8)
            }
        )

        XCTAssertNil(restored)
        XCTAssertFalse(styledCalled)
        XCTAssertFalse(fallbackCalled)
    }

    func testFullBufferFallbackIsUsedOnlyWhenTailSnapshotIsUnavailable() {
        var styledCalled = false
        var fallbackCalled = false

        let restored = TerminalSessionModel.captureRestorationScrollbackContent(
            maxLines: 10,
            tailData: nil,
            styledData: {
                styledCalled = true
                return Data("\u{1B}[31mstyled full snapshot\u{1B}[0m".utf8)
            },
            fallbackData: {
                fallbackCalled = true
                return Data("plain fallback snapshot".utf8)
            }
        )

        XCTAssertEqual(restored, "\u{1B}[31mstyled full snapshot\u{1B}[0m")
        XCTAssertTrue(styledCalled)
        XCTAssertFalse(fallbackCalled)
    }

    func testTailSnapshotStillUsesRestoreFiltering() {
        let restored = TerminalSessionModel.captureRestorationScrollbackContent(
            maxLines: 2,
            tailData: Data("old\nnewer\nnewest\n".utf8),
            styledData: { XCTFail("Tail snapshot should avoid full styled capture"); return nil },
            fallbackData: { XCTFail("Tail snapshot should avoid plain fallback capture"); return nil }
        )

        XCTAssertEqual(restored, "newer\nnewest")
    }
}
