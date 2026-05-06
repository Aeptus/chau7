import XCTest
@testable import Chau7Core

final class PromptInjectionTriggerTests: XCTestCase {
    func testNormalizedTriggersDefaultsToEveryPrompt() {
        XCTAssertEqual(PromptInjectionTrigger.normalized([]), [.everyPrompt])
        XCTAssertEqual(
            PromptInjectionTrigger.normalized([.afterClear]),
            [.afterClear]
        )
    }

    func testSessionEventDetectionMatchesCompactAndClearCommands() {
        XCTAssertEqual(PromptInjectionSessionEvent.detect(in: "/compact"), .afterCompact)
        XCTAssertEqual(PromptInjectionSessionEvent.detect(in: "  /clear   now "), .afterClear)
        XCTAssertNil(PromptInjectionSessionEvent.detect(in: "clear"))
        XCTAssertNil(PromptInjectionSessionEvent.detect(in: "/unknown"))
    }

    func testTriggerMatchesCorrespondingSessionEvent() {
        XCTAssertTrue(PromptInjectionTrigger.afterCompact.matches(event: .afterCompact))
        XCTAssertFalse(PromptInjectionTrigger.afterCompact.matches(event: .afterClear))
        XCTAssertTrue(PromptInjectionTrigger.afterClear.matches(event: .afterClear))
    }
}
