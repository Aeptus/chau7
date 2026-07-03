import XCTest
@testable import Chau7Core

final class TriggerVocabularyTests: XCTestCase {

    // MARK: - Table integrity

    func testEntryTypesAreNormalizedAndUnique() {
        let types = TriggerVocabulary.entries.map(\.type)
        XCTAssertEqual(Set(types).count, types.count, "duplicate vocabulary entries")
        for type in types {
            XCTAssertEqual(
                type, NotificationSemanticMapping.normalize(type),
                "\(type) is not in normalized form"
            )
        }
    }

    /// Drift guard: the vocabulary's `semanticKind` column must agree with
    /// `NotificationSemanticMapping.kind(forRawType:)`, which stays
    /// authoritative for kind derivation in the adapter layer.
    func testSemanticKindsMatchNotificationSemanticMapping() {
        for entry in TriggerVocabulary.entries {
            XCTAssertEqual(
                entry.semanticKind,
                NotificationSemanticMapping.kind(forRawType: entry.type),
                "vocabulary semanticKind for \(entry.type) drifted from NotificationSemanticMapping"
            )
        }
    }

    // MARK: - Golden presentation snapshot

    /// Pins the presentation columns byte-for-byte so a refactor of the
    /// formatter/planner lookups cannot silently change user-facing text or
    /// tab styling. (type, title fallback, body fallback, style preset);
    /// nil title means the generic "Update" title, nil body means the
    /// "<type>: <message>" fallback.
    func testVocabularyMatchesGoldenSnapshot() {
        let golden: [(type: String, title: String?, body: String?, style: String?)] = [
            ("finished", "Finished", "Done.", "waiting"),
            ("failed", "Failed", "Check the logs.", "error"),
            ("tool_failed", "Tool failed", nil, "error"),
            ("response_failed", nil, nil, "error"),
            ("permission", "Permission needed", "Needs your permission to continue.", "attention"),
            ("waiting_input", "Waiting for input", "Ready for your input.", "waiting"),
            ("idle", "Waiting for input", "No new history entries for a while.", "waiting"),
            ("attention_required", "Needs attention", "Needs your attention.", "attention"),
            ("elicitation", nil, nil, "attention"),
            ("needs_validation", "Needs review", "Your input is required.", nil),
            ("error", "Error", "An error occurred.", "error"),
            ("context_limit", "Context limit reached", "Approaching context window limit.", "error"),
            ("file_conflict", "File conflict", nil, nil),
            ("tool_called", "Tool called", nil, nil),
            ("file_edited", "File edited", nil, nil),
            ("token_threshold", "Token threshold", "Usage threshold exceeded.", nil),
            ("cost_threshold", "Cost threshold", "Usage threshold exceeded.", nil)
        ]

        XCTAssertEqual(TriggerVocabulary.entries.count, golden.count)
        for expected in golden {
            guard let entry = TriggerVocabulary.entry(forNormalizedType: expected.type) else {
                XCTFail("missing vocabulary entry for \(expected.type)")
                continue
            }
            XCTAssertEqual(entry.titleFallback, expected.title, "title drift for \(expected.type)")
            XCTAssertEqual(entry.bodyFallback, expected.body, "body drift for \(expected.type)")
            XCTAssertEqual(entry.stylePreset, expected.style, "style drift for \(expected.type)")
        }
    }

    // MARK: - Lookup behavior

    func testEntryLookupNormalizesRawTypes() {
        XCTAssertEqual(TriggerVocabulary.entry(forType: "  FINISHED  ")?.type, "finished")
        XCTAssertEqual(TriggerVocabulary.entry(forType: "tool-failed")?.type, "tool_failed")
        XCTAssertNil(TriggerVocabulary.entry(forType: "some_unknown_type"))
    }

    // MARK: - Consumer parity (formatter + style planner read this table)

    func testFormatterTitleSuffixMatchesVocabulary() {
        for entry in TriggerVocabulary.entries {
            let expected = entry.titleFallback ?? "Update"
            XCTAssertEqual(
                NotificationContentFormatter.titleSuffix(forType: entry.type),
                expected,
                "titleSuffix drift for \(entry.type)"
            )
        }
        XCTAssertEqual(NotificationContentFormatter.titleSuffix(forType: "mystery"), "Update")
    }

    func testFormatterBodyMatchesVocabulary() {
        for entry in TriggerVocabulary.entries {
            let event = AIEvent(type: entry.type, tool: "Tool", message: "", ts: "2026-01-01T00:00:00Z")
            let expected = entry.bodyFallback ?? entry.type
            XCTAssertEqual(NotificationContentFormatter.body(for: event), expected, "body drift for \(entry.type)")

            // Producer-supplied messages always win over the vocabulary default.
            let withMessage = AIEvent(type: entry.type, tool: "Tool", message: "custom", ts: "2026-01-01T00:00:00Z")
            let expectedWithMessage = entry.bodyFallback == nil ? "\(entry.type): custom" : "custom"
            XCTAssertEqual(NotificationContentFormatter.body(for: withMessage), expectedWithMessage)
        }
    }

    func testStylePlannerPresetMatchesVocabulary() {
        for entry in TriggerVocabulary.entries {
            let event = AIEvent(type: entry.type, tool: "Tool", message: "", ts: "2026-01-01T00:00:00Z")
            let action = NotificationStylePlanner.defaultStyleAction(for: event)
            XCTAssertEqual(action?.config["style"], entry.stylePreset, "style planner drift for \(entry.type)")
            if entry.stylePreset != nil {
                XCTAssertEqual(action?.actionType, .styleTab)
                XCTAssertEqual(action?.config["autoClearSeconds"], "30")
            }
        }
        let unknownEvent = AIEvent(type: "mystery", tool: "Tool", message: "", ts: "2026-01-01T00:00:00Z")
        XCTAssertNil(NotificationStylePlanner.defaultStyleAction(for: unknownEvent))
    }
}
