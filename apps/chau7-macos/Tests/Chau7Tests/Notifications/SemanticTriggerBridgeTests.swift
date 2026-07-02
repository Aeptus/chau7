import XCTest
@testable import Chau7Core

/// The test bridge between the adapter layer and the trigger catalog (B3).
///
/// The dedicated Claude Code and Codex adapters rewrite an emitted event's
/// `type` to a `SemanticTriggerType` raw value, and the catalog gates
/// delivery by (source, type). This coupling was previously stringly-typed
/// and silently wrong for `.informational` — this suite makes every pair
/// explicit. Mapped sources (shell, app, terminal session, …) preserve their
/// original raw types and are covered by the catalog's own per-source
/// matrices, not this bridge.
final class SemanticTriggerBridgeTests: XCTestCase {

    /// Sources whose adapters emit semantic trigger types as the event type.
    private let dedicatedAdapterSources: [AIEventSource] = [.claudeCode, .codex]

    /// Pairs that intentionally resolve to the source's wildcard trigger
    /// rather than a dedicated one. Every entry encodes a deliberate product
    /// decision. `info` is the audit-flagged case: informational AI events
    /// have no dedicated toggle and ride the "Other events" wildcard until
    /// the routing-policy stage gives them per-surface treatment.
    private let intentionalWildcard: Set<String> = [
        "claude_code|info",
        "codex|info"
    ]

    func testEveryDedicatedAdapterTriggerTypeHasDeliberateCatalogTreatment() {
        var unexplained: [String] = []

        for source in dedicatedAdapterSources {
            for triggerType in SemanticTriggerType.allCases {
                let key = "\(source.rawValue)|\(triggerType.rawValue)"
                guard let trigger = NotificationTriggerCatalog.trigger(source: source, type: triggerType.rawValue) else {
                    unexplained.append("\(key) → NO TRIGGER AT ALL (not even wildcard)")
                    continue
                }
                let isWildcard = trigger.type == NotificationTriggerCatalog.wildcardType
                if isWildcard && !intentionalWildcard.contains(key) {
                    unexplained.append("\(key) → falls to wildcard but is not allowlisted")
                } else if !isWildcard && intentionalWildcard.contains(key) {
                    unexplained.append("\(key) → has a dedicated trigger; remove stale allowlist entry")
                }
            }
        }

        XCTAssertTrue(
            unexplained.isEmpty,
            "Adapter→catalog coupling drifted:\n" + unexplained.joined(separator: "\n")
        )
    }

    func testSemanticTriggerTypeCoversEveryEmittableKind() {
        for kind in NotificationSemanticKind.allCases where kind != .unknown {
            XCTAssertNotNil(
                SemanticTriggerType(kind: kind),
                "kind \(kind.rawValue) has no trigger-type mapping"
            )
        }
        XCTAssertNil(SemanticTriggerType(kind: .unknown), "adapters drop unknown kinds; no trigger type")
    }
}
