import XCTest
@testable import Chau7Core

final class JSONPrettyPrinterTests: XCTestCase {

    // MARK: - Valid JSON

    func testPrettyPrintSimpleObject() {
        let input = """
        {"name":"Alice","age":30}
        """
        let result = JSONPrettyPrinter.prettyPrint(input)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("\"age\""))
        XCTAssertTrue(result!.contains("\"name\""))
        // Pretty printed should contain newlines
        XCTAssertTrue(result!.contains("\n"))
    }

    func testPrettyPrintArray() {
        let input = "[1,2,3]"
        let result = JSONPrettyPrinter.prettyPrint(input)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("\n"))
    }

    func testPrettyPrintNestedObject() {
        let input = """
        {"outer":{"inner":"value"}}
        """
        let result = JSONPrettyPrinter.prettyPrint(input)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("inner"))
        XCTAssertTrue(result!.contains("outer"))
    }

    func testPrettyPrintSortsKeys() {
        let input = """
        {"zebra":1,"apple":2,"mango":3}
        """
        let result = JSONPrettyPrinter.prettyPrint(input)!

        // Keys should be sorted: apple, mango, zebra
        let appleIndex = result.range(of: "apple")!.lowerBound
        let mangoIndex = result.range(of: "mango")!.lowerBound
        let zebraIndex = result.range(of: "zebra")!.lowerBound

        XCTAssertLessThan(appleIndex, mangoIndex)
        XCTAssertLessThan(mangoIndex, zebraIndex)
    }

    func testPrettyPrintEmptyObject() {
        let result = JSONPrettyPrinter.prettyPrint("{}")
        XCTAssertNotNil(result)
    }

    func testPrettyPrintEmptyArray() {
        let result = JSONPrettyPrinter.prettyPrint("[]")
        XCTAssertNotNil(result)
    }

    func testPrettyPrintWithWhitespace() {
        // Leading/trailing whitespace should be trimmed before parsing
        let input = "   {\"key\":\"value\"}   "
        let result = JSONPrettyPrinter.prettyPrint(input)
        XCTAssertNotNil(result)
    }

    func testPrettyPrintRoundTrip() {
        let input = """
        {"a":1,"b":"hello","c":[1,2,3],"d":true,"e":null}
        """
        let pretty = JSONPrettyPrinter.prettyPrint(input)
        XCTAssertNotNil(pretty)

        // Pretty-printing again should produce the same result
        let doublePretty = JSONPrettyPrinter.prettyPrint(pretty!)
        XCTAssertEqual(pretty, doublePretty)
    }

    // MARK: - Invalid Input

    func testPrettyPrintNotJSON() {
        XCTAssertNil(JSONPrettyPrinter.prettyPrint("hello world"))
    }

    func testPrettyPrintEmptyString() {
        XCTAssertNil(JSONPrettyPrinter.prettyPrint(""))
    }

    func testPrettyPrintOnlyWhitespace() {
        XCTAssertNil(JSONPrettyPrinter.prettyPrint("   "))
    }

    func testPrettyPrintMalformedJSON() {
        XCTAssertNil(JSONPrettyPrinter.prettyPrint("{broken"))
    }

    func testPrettyPrintNumber() {
        // Starts with digit, not { or [
        XCTAssertNil(JSONPrettyPrinter.prettyPrint("42"))
    }

    func testPrettyPrintBooleanString() {
        XCTAssertNil(JSONPrettyPrinter.prettyPrint("true"))
    }

    func testPrettyPrintString() {
        // A JSON string by itself doesn't start with { or [
        XCTAssertNil(JSONPrettyPrinter.prettyPrint("\"hello\""))
    }
}
