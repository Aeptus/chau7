import XCTest
@testable import Chau7Core
@testable import Chau7

final class NotificationPipelineTests: XCTestCase {

    // MARK: - Helpers

    /// A source that has no triggers in the catalog — guarantees the "unmatched" path.
    private static let uncatalogedSource = AIEventSource(rawValue: "test_uncataloged_source")

    /// Creates a minimal pipeline input with overridable flags.
    /// Uses an uncataloged source so the event reaches the "no matching trigger" path.
    private func makeInput(
        source: AIEventSource = uncatalogedSource,
        triggerState: NotificationTriggerState = NotificationTriggerState(),
        triggerConditions: [String: TriggerCondition] = [:],
        actionBindings: [String: [NotificationActionConfig]] = [:],
        groupConditions: [String: TriggerCondition] = [:],
        groupActionBindings: [String: [NotificationActionConfig]] = [:],
        isFocusModeActive: Bool = false,
        isAppActive: Bool = false,
        isToolTabActive: Bool = false
    ) -> NotificationPipeline.Input {
        let event = AIEvent(
            source: source,
            type: "some_type",
            tool: "TestTool",
            message: "test",
            ts: "2025-01-01T00:00:00Z"
        )
        return NotificationPipeline.Input(
            event: event,
            triggerState: triggerState,
            triggerConditions: triggerConditions,
            actionBindings: actionBindings,
            groupConditions: groupConditions,
            groupActionBindings: groupActionBindings,
            isFocusModeActive: isFocusModeActive,
            isAppActive: isAppActive,
            isToolTabActive: isToolTabActive
        )
    }

    // MARK: - Unmatched Trigger Default Conditions

    func testUnmatchedTriggerDropsWhenDNDActive() {
        let input = makeInput(isFocusModeActive: true)
        let decision = NotificationPipeline.evaluate(input)

        if case .drop(let reason) = decision {
            XCTAssertTrue(reason.contains("DND"), "Expected DND drop reason, got: \(reason)")
        } else {
            XCTFail("Expected .drop for unmatched trigger with DND active, got: \(decision)")
        }
    }

    func testUnmatchedTriggerDropsWhenTabActive() {
        let input = makeInput(isToolTabActive: true)
        let decision = NotificationPipeline.evaluate(input)

        if case .drop(let reason) = decision {
            XCTAssertTrue(reason.contains("tab"), "Expected tab-active drop reason, got: \(reason)")
        } else {
            XCTFail("Expected .drop for unmatched trigger with active tab, got: \(decision)")
        }
    }

    func testUnmatchedTriggerFiresDefaultWhenAllConditionsMet() {
        let input = makeInput(
            isFocusModeActive: false,
            isAppActive: false,
            isToolTabActive: false
        )
        let decision = NotificationPipeline.evaluate(input)

        if case .fireDefault(let triggerId) = decision {
            XCTAssertNil(triggerId, "Unmatched triggers should have nil triggerId")
        } else {
            XCTFail("Expected .fireDefault for unmatched trigger with all conditions met, got: \(decision)")
        }
    }

    func testUnmatchedTriggerDNDTakesPriorityOverTabActive() {
        let input = makeInput(isFocusModeActive: true, isToolTabActive: true)
        let decision = NotificationPipeline.evaluate(input)

        if case .drop(let reason) = decision {
            XCTAssertTrue(reason.contains("DND"), "DND should take priority, got: \(reason)")
        } else {
            XCTFail("Expected .drop, got: \(decision)")
        }
    }

    func testUnmatchedTriggerAppActiveRespectedWhenDefaultRequiresIt() {
        // TriggerCondition.default has onlyWhenUnfocused=false, so this documents behavior
        let input = makeInput(isAppActive: true)
        let decision = NotificationPipeline.evaluate(input)

        if TriggerCondition.default.onlyWhenUnfocused {
            if case .drop(let reason) = decision {
                XCTAssertTrue(reason.contains("active"), "Got: \(reason)")
            } else {
                XCTFail("Expected .drop when default requires unfocused")
            }
        } else {
            if case .fireDefault = decision {
                // Expected: default doesn't require unfocused
            } else {
                XCTFail("Expected .fireDefault when default doesn't require unfocused, got: \(decision)")
            }
        }
    }

    // MARK: - Matched Trigger Conditions

    func testMatchedTriggerDropsWhenDNDActive() {
        // Use Claude Code "finished" event — a well-known trigger
        let event = AIEvent(
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2025-01-01T00:00:00Z"
        )
        let input = NotificationPipeline.Input(
            event: event,
            triggerState: NotificationTriggerState(),
            triggerConditions: [:],
            actionBindings: [:],
            groupConditions: [:],
            groupActionBindings: [:],
            isFocusModeActive: true,
            isAppActive: false,
            isToolTabActive: false
        )
        let decision = NotificationPipeline.evaluate(input)

        if case .drop(let reason) = decision {
            XCTAssertTrue(reason.contains("DND"), "Expected DND drop, got: \(reason)")
        } else {
            XCTFail("Expected .drop for DND active, got: \(decision)")
        }
    }
}
