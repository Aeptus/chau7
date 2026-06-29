import XCTest
@testable import Chau7

/// Adds a schema-version field to `SavedSplitNode`. The intent is forward
/// compatibility: a future Chau7 binary writes version 2 with a new pane
/// kind, an old binary refuses to silently decode it (losing the new node)
/// and instead surfaces a decoding error so the caller substitutes a
/// default layout. These tests pin the wire format on both ends.
final class SavedSplitNodeVersionTests: XCTestCase {

    func testPreVersionedSnapshotDecodesAsVersionOne() throws {
        // What was on disk before this commit — no `version` key.
        let legacyJSON = """
        {
            "kind": "terminal",
            "id": "DEAD-BEEF",
            "textEditorPath": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SavedSplitNode.self, from: legacyJSON)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.kind, .terminal)
        XCTAssertEqual(decoded.id, "DEAD-BEEF")
    }

    func testFutureVersionFailsLoudly() {
        let futureJSON = """
        {
            "version": 999,
            "kind": "terminal",
            "id": "FUT-1"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(SavedSplitNode.self, from: futureJSON)) { error in
            // The decode must fail — caller falls back to a default layout
            // instead of silently mis-decoding a newer snapshot.
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("Expected DecodingError.dataCorrupted, got: \(error)")
                return
            }
        }
    }

    func testEncodeIncludesVersionField() throws {
        let node = SavedSplitNode(
            kind: .terminal,
            id: "ROUND-TRIP",
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let encoded = try JSONEncoder().encode(node)
        guard let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            XCTFail("Encoded JSON was not an object")
            return
        }
        XCTAssertEqual(json["version"] as? Int, SavedSplitNode.currentVersion)
        XCTAssertEqual(json["id"] as? String, "ROUND-TRIP")
    }

    func testRoundTripPreservesVersion() throws {
        let original = SavedSplitNode(
            kind: .split,
            id: "ROOT",
            direction: .horizontal,
            ratio: 0.42,
            first: SavedSplitNode(
                kind: .terminal,
                id: "L",
                direction: nil, ratio: nil, first: nil, second: nil,
                textEditorPath: nil
            ),
            second: SavedSplitNode(
                kind: .textEditor,
                id: "R",
                direction: nil, ratio: nil, first: nil, second: nil,
                textEditorPath: "/tmp/note.md"
            ),
            textEditorPath: nil
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SavedSplitNode.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.version, SavedSplitNode.currentVersion)
        XCTAssertEqual(restored.first?.version, SavedSplitNode.currentVersion)
        XCTAssertEqual(restored.second?.version, SavedSplitNode.currentVersion)
    }
}
