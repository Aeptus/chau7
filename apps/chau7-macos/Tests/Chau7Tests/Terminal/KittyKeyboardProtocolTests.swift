import XCTest
@testable import Chau7Core

final class KittyKeyboardProtocolTests: XCTestCase {

    // MARK: - Flag Push/Pop/Query

    func testInitialFlagsAreZero() {
        let proto = KittyKeyboardProtocol()
        XCTAssertEqual(proto.flags, 0)
        XCTAssertTrue(proto.flagStack.isEmpty)
    }

    func testPushFlags() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(3)
        XCTAssertEqual(proto.flags, 3)
        XCTAssertEqual(proto.flagStack, [0])
    }

    func testPushMultipleFlags() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(1)
        proto.pushFlags(3)
        proto.pushFlags(7)
        XCTAssertEqual(proto.flags, 7)
        XCTAssertEqual(proto.flagStack, [0, 1, 3])
    }

    func testPopFlags() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(1)
        proto.pushFlags(3)
        proto.popFlags()
        XCTAssertEqual(proto.flags, 1)
        XCTAssertEqual(proto.flagStack, [0])
    }

    func testPopMultipleFlags() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(1)
        proto.pushFlags(3)
        proto.pushFlags(7)
        proto.popFlags(count: 2)
        XCTAssertEqual(proto.flags, 1)
        XCTAssertEqual(proto.flagStack, [0])
    }

    func testPopOnEmptyStackIsNoop() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(5)
        proto.popFlags(count: 10) // more pops than pushes
        XCTAssertEqual(proto.flags, 0)
        XCTAssertTrue(proto.flagStack.isEmpty)
    }

    func testMaxStackDepth() {
        var proto = KittyKeyboardProtocol()
        for i in 0..<KittyKeyboardProtocol.maxStackDepth + 10 {
            proto.pushFlags(UInt32(i))
        }
        // Stack should not exceed maxStackDepth
        XCTAssertEqual(proto.flagStack.count, KittyKeyboardProtocol.maxStackDepth)
    }

    func testQueryResponse() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(5)
        let response = proto.queryResponse()
        let expected = Array("\u{1b}[?5u".utf8)
        XCTAssertEqual(response, expected)
    }

    func testQueryResponseZeroFlags() {
        let proto = KittyKeyboardProtocol()
        let response = proto.queryResponse()
        let expected = Array("\u{1b}[?0u".utf8)
        XCTAssertEqual(response, expected)
    }

    // MARK: - Flag Checks

    func testDisambiguateEscapeCodes() {
        var proto = KittyKeyboardProtocol()
        XCTAssertFalse(proto.disambiguateEscapeCodes)
        proto.pushFlags(1)
        XCTAssertTrue(proto.disambiguateEscapeCodes)
    }

    func testReportEventTypes() {
        var proto = KittyKeyboardProtocol()
        XCTAssertFalse(proto.reportEventTypes)
        proto.pushFlags(2)
        XCTAssertTrue(proto.reportEventTypes)
    }

    func testReportAlternateKeys() {
        var proto = KittyKeyboardProtocol()
        XCTAssertFalse(proto.reportAlternateKeys)
        proto.pushFlags(4)
        XCTAssertTrue(proto.reportAlternateKeys)
    }

    func testReportAllKeysAsEscapeCodes() {
        var proto = KittyKeyboardProtocol()
        XCTAssertFalse(proto.reportAllKeysAsEscapeCodes)
        proto.pushFlags(8)
        XCTAssertTrue(proto.reportAllKeysAsEscapeCodes)
    }

    func testReportAssociatedText() {
        var proto = KittyKeyboardProtocol()
        XCTAssertFalse(proto.reportAssociatedText)
        proto.pushFlags(16)
        XCTAssertTrue(proto.reportAssociatedText)
    }

    func testCombinedFlags() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(0b11111) // all 5 flags
        XCTAssertTrue(proto.disambiguateEscapeCodes)
        XCTAssertTrue(proto.reportEventTypes)
        XCTAssertTrue(proto.reportAlternateKeys)
        XCTAssertTrue(proto.reportAllKeysAsEscapeCodes)
        XCTAssertTrue(proto.reportAssociatedText)
    }

    // MARK: - Key Encoding

    func testEncodeWithNoFlags() {
        let proto = KittyKeyboardProtocol()
        let event = KittyKeyEvent(keyCode: 97, legacyEncoding: [0x61]) // a
        let result = proto.encodeKeyEvent(event)
        XCTAssertEqual(result, [0x61]) // legacy encoding returned
    }

    func testEncodeSimpleKeyWithDisambiguate() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(1) // disambiguate only
        let event = KittyKeyEvent(keyCode: 97) // a
        let result = proto.encodeKeyEvent(event)
        let expected = Array("\u{1b}[97u".utf8)
        XCTAssertEqual(result, expected)
    }

    func testEncodeKeyWithModifiers() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(1)
        let event = KittyKeyEvent(keyCode: 97, modifiers: .shift) // Shift+a
        let result = proto.encodeKeyEvent(event)
        let expected = Array("\u{1b}[97;2u".utf8)
        XCTAssertEqual(result, expected)
    }

    func testEncodeKeyWithEventType() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(3) // disambiguate + event types
        let event = KittyKeyEvent(keyCode: 97, eventType: .release)
        let result = proto.encodeKeyEvent(event)
        let expected = Array("\u{1b}[97;1:3u".utf8)
        XCTAssertEqual(result, expected)
    }

    func testEncodeKeyWithAlternateKeys() {
        var proto = KittyKeyboardProtocol()
        proto.pushFlags(4) // report alternate keys
        let event = KittyKeyEvent(keyCode: 97, shiftedKey: 65) // a -> A
        let result = proto.encodeKeyEvent(event)
        let expected = Array("\u{1b}[97:65u".utf8)
        XCTAssertEqual(result, expected)
    }

    // MARK: - Parse Request

    func testParseRequestPush() {
        let seq: [UInt8] = Array("\u{1b}[>3u".utf8)
        let result = KittyKeyboardProtocol.parseRequest(seq)
        XCTAssertEqual(result, .push(3))
    }

    func testParseRequestPop() {
        let seq: [UInt8] = Array("\u{1b}[<2u".utf8)
        let result = KittyKeyboardProtocol.parseRequest(seq)
        XCTAssertEqual(result, .pop(2))
    }

    func testParseRequestPopDefault() {
        let seq: [UInt8] = Array("\u{1b}[<u".utf8)
        let result = KittyKeyboardProtocol.parseRequest(seq)
        XCTAssertEqual(result, .pop(1))
    }

    func testParseRequestQuery() {
        let seq: [UInt8] = Array("\u{1b}[?u".utf8)
        let result = KittyKeyboardProtocol.parseRequest(seq)
        XCTAssertEqual(result, .query)
    }

    func testParseRequestTooShort() {
        let seq: [UInt8] = [0x1b, 0x5b]
        let result = KittyKeyboardProtocol.parseRequest(seq)
        XCTAssertNil(result)
    }

    func testParseRequestWrongTerminator() {
        let seq: [UInt8] = Array("\u{1b}[>3x".utf8) // x instead of u
        let result = KittyKeyboardProtocol.parseRequest(seq)
        XCTAssertNil(result)
    }

    func testParseRequestNotCSI() {
        let seq: [UInt8] = [0x41, 0x42, 0x43] // ABC
        let result = KittyKeyboardProtocol.parseRequest(seq)
        XCTAssertNil(result)
    }

    func testParseRequestPushLargeFlags() {
        let seq: [UInt8] = Array("\u{1b}[>31u".utf8)
        let result = KittyKeyboardProtocol.parseRequest(seq)
        XCTAssertEqual(result, .push(31))
    }
}
