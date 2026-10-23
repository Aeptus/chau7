import XCTest
@testable import Chau7Core

final class StructuredResultExtractorTests: XCTestCase {
    func testCaptureReturnsAvailableResultWhenSchemaMatches() throws {
        let schema = try XCTUnwrap(JSONValue.from(any: [
            "type": "object",
            "required": ["summary", "approved"],
            "properties": [
                "summary": ["type": "string"],
                "approved": ["type": "boolean"]
            ]
        ]))

        let result = StructuredResultExtractor.capture(
            sessionID: "rs_test",
            turnID: "t_1",
            summary: """
            ```json
            {"summary":"Ready to merge","approved":true}
            ```
            """,
            output: nil,
            schema: schema
        )

        XCTAssertEqual(result?.status, .available)
        XCTAssertEqual(result?.value?.objectValue?["summary"]?.stringValue, "Ready to merge")
    }

    func testCaptureReturnsInvalidWhenSchemaDoesNotMatch() throws {
        let schema = try XCTUnwrap(JSONValue.from(any: [
            "type": "object",
            "required": ["summary", "findings"],
            "properties": [
                "summary": ["type": "string"],
                "findings": ["type": "array"]
            ]
        ]))

        let result = StructuredResultExtractor.capture(
            sessionID: "rs_test",
            turnID: "t_1",
            summary: "{\"summary\":\"Ready to merge\"}",
            output: nil,
            schema: schema
        )

        XCTAssertEqual(result?.status, .invalid)
        XCTAssertTrue(result?.validationErrors.contains("$.findings is required") == true)
    }

    func testCaptureReturnsMissingWhenSchemaRequestedButNoJSONFound() throws {
        let schema = try XCTUnwrap(JSONValue.from(any: [
            "type": "object",
            "required": ["summary"],
            "properties": [
                "summary": ["type": "string"]
            ]
        ]))

        let result = StructuredResultExtractor.capture(
            sessionID: "rs_test",
            turnID: "t_1",
            summary: "No structured payload here.",
            output: nil,
            schema: schema
        )

        XCTAssertEqual(result?.status, .missing)
        XCTAssertNil(result?.value)
    }
}
