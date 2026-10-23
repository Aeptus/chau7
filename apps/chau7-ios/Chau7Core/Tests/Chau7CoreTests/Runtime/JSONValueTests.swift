import XCTest
import Chau7Core

final class JSONValueTests: XCTestCase {

    // MARK: - Decode

    func testDecodesPrimitives() throws {
        XCTAssertEqual(try decode("null"), .null)
        XCTAssertEqual(try decode("true"), .bool(true))
        XCTAssertEqual(try decode("false"), .bool(false))
        XCTAssertEqual(try decode("42"), .number(42))
        XCTAssertEqual(try decode("3.14"), .number(3.14))
        XCTAssertEqual(try decode(#""hello""#), .string("hello"))
    }

    func testDecodesArray() throws {
        let value = try decode("[1, \"two\", null, false]")
        XCTAssertEqual(value, .array([.number(1), .string("two"), .null, .bool(false)]))
    }

    func testDecodesObject() throws {
        let value = try decode(#"{"name":"alice","age":30}"#)
        XCTAssertEqual(value, .object(["name": .string("alice"), "age": .number(30)]))
    }

    func testDecodesNestedStructure() throws {
        let json = #"{"users":[{"id":1,"active":true},{"id":2,"active":false}]}"#
        let value = try decode(json)
        guard case let .object(root) = value,
              case let .array(users) = root["users"],
              users.count == 2,
              case let .object(first) = users[0] else {
            return XCTFail("unexpected structure")
        }
        XCTAssertEqual(first["id"], .number(1))
        XCTAssertEqual(first["active"], .bool(true))
    }

    // MARK: - Encode

    func testEncodesPrimitivesRoundTrip() throws {
        try assertRoundTrip(.null)
        try assertRoundTrip(.bool(true))
        try assertRoundTrip(.number(42))
        try assertRoundTrip(.string("hi"))
    }

    func testEncodesArrayAndObjectRoundTrip() throws {
        try assertRoundTrip(.array([.number(1), .bool(false)]))
        try assertRoundTrip(.object(["k": .string("v")]))
    }

    // MARK: - from(any:)

    func testFromAnyHandlesPrimitives() {
        XCTAssertEqual(JSONValue.from(any: "hello"), .string("hello"))
        XCTAssertEqual(JSONValue.from(any: 42), .number(42))
        XCTAssertEqual(JSONValue.from(any: 3.14), .number(3.14))
        XCTAssertEqual(JSONValue.from(any: NSNull()), .null)
    }

    func testFromAnyDistinguishesBoolFromNumber() {
        // NSNumber bridging hazard: true would arrive as NSNumber 1.
        // JSONValue.from(any:) must preserve the bool tag.
        XCTAssertEqual(JSONValue.from(any: true), .bool(true))
        XCTAssertEqual(JSONValue.from(any: false), .bool(false))
    }

    func testFromAnyHandlesNestedDictionaryAndArray() {
        let input: [String: Any] = [
            "n": 3,
            "flag": true,
            "list": [1, "two", NSNull()]
        ]
        let value = JSONValue.from(any: input)
        guard case let .object(dict) = value else { return XCTFail("expected object") }
        XCTAssertEqual(dict["n"], .number(3))
        XCTAssertEqual(dict["flag"], .bool(true))
        XCTAssertEqual(dict["list"], .array([.number(1), .string("two"), .null]))
    }

    func testFromAnyReturnsNilForUnsupportedType() {
        struct Custom {}
        XCTAssertNil(JSONValue.from(any: Custom()))
    }

    func testFromAnyReturnsNilWhenObjectContainsUnsupportedValue() {
        struct Custom {}
        let input: [String: Any] = ["bad": Custom()]
        XCTAssertNil(JSONValue.from(any: input))
    }

    // MARK: - foundationValue

    func testFoundationValueReturnsIntForWholeNumbers() {
        let value = JSONValue.number(42)
        XCTAssertEqual(value.foundationValue as? Int, 42)
    }

    func testFoundationValueReturnsDoubleForFractionalNumbers() {
        let value = JSONValue.number(3.14)
        XCTAssertEqual(value.foundationValue as? Double, 3.14)
    }

    func testFoundationValueReturnsNSNullForNull() {
        XCTAssertTrue(JSONValue.null.foundationValue is NSNull)
    }

    func testFoundationValueRoundTripsNestedStructures() {
        let value = JSONValue.object([
            "n": .number(42),
            "list": .array([.string("a"), .bool(true)])
        ])
        guard let dict = value.foundationValue as? [String: Any] else { return XCTFail("expected dict") }
        XCTAssertEqual(dict["n"] as? Int, 42)
        guard let list = dict["list"] as? [Any] else { return XCTFail("expected list") }
        XCTAssertEqual(list[0] as? String, "a")
        XCTAssertEqual(list[1] as? Bool, true)
    }

    // MARK: - Accessors

    func testTypedAccessorsReturnValueOnMatch() {
        XCTAssertEqual(JSONValue.string("x").stringValue, "x")
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertEqual(JSONValue.object(["k": .null]).objectValue, ["k": .null])
        XCTAssertEqual(JSONValue.array([.null]).arrayValue, [.null])
    }

    func testTypedAccessorsReturnNilOnMismatch() {
        XCTAssertNil(JSONValue.number(1).stringValue)
        XCTAssertNil(JSONValue.string("x").boolValue)
        XCTAssertNil(JSONValue.null.objectValue)
        XCTAssertNil(JSONValue.null.arrayValue)
    }

    func testIsIntegerMatchesWholeNumbers() {
        XCTAssertTrue(JSONValue.number(42).isInteger)
        XCTAssertTrue(JSONValue.number(-3).isInteger)
        XCTAssertFalse(JSONValue.number(3.14).isInteger)
        XCTAssertFalse(JSONValue.string("42").isInteger)
    }

    // MARK: - helpers

    private func decode(_ json: String) throws -> JSONValue {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func assertRoundTrip(_ value: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }
}
