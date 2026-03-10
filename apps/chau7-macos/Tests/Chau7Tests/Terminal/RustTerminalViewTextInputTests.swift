import XCTest
import AppKit
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class RustTerminalViewTextInputTests: XCTestCase {

    func testShouldSuppressRawTextFallbackWhenInputContextHandled() {
        let view = RustTerminalView(frame: .zero)

        XCTAssertTrue(
            view.shouldSuppressRawTextFallback(afterInputContextHandled: true),
            "Committed input from NSTextInputContext should never fall through to raw character fallback"
        )
    }

    func testShouldSuppressRawTextFallbackWhenMarkedTextExists() {
        let view = RustTerminalView(frame: .zero)

        view.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.hasMarkedText(), "Dead-key composition should register marked text")
        XCTAssertTrue(
            view.shouldSuppressRawTextFallback(afterInputContextHandled: false),
            "Pending dead-key composition must suppress raw fallback to avoid injecting literal accent characters"
        )
    }

    func testShouldNotSuppressRawTextFallbackWithoutHandledInputOrMarkedText() {
        let view = RustTerminalView(frame: .zero)

        XCTAssertFalse(
            view.shouldSuppressRawTextFallback(afterInputContextHandled: false),
            "Plain text keys still need the fallback path when NSTextInputContext does not consume the event"
        )
    }
}
#endif
