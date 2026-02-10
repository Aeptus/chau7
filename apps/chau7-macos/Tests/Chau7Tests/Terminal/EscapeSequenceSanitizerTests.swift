import XCTest
@testable import Chau7Core

final class EscapeSequenceSanitizerTests: XCTestCase {

    // MARK: - sanitize: CSI Sequences

    func testSanitize_CSIWithEscPrefix() {
        // ESC [ ... final_byte — e.g. cursor movement, SGR
        let input = "Hello\u{1b}[32mWorld\u{1b}[0m"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "HelloWorld")
    }

    func testSanitize_CSIFocusEvents() {
        // [O = focus out, [I = focus in
        let input = "before\u{1b}[Oafter\u{1b}[Iend"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "beforeafterend")
    }

    func testSanitize_CSICursorReport() {
        // [5;1R = cursor position report
        let input = "text\u{1b}[5;1Rmore"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "textmore")
    }

    func testSanitize_CSIDeviceAttributes() {
        // [?65;4;1;2;6;21;22;17;28c
        let input = "\u{1b}[?65;4;1;2;6;21;22;17;28c"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "")
    }

    func testSanitize_BareCSI() {
        // Bare CSI without ESC prefix (sometimes in logs)
        let input = "foo[32mbar"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "foobar")
    }

    // MARK: - sanitize: OSC Sequences

    func testSanitize_OSCWithBEL() {
        // OSC terminated by BEL (0x07)
        let input = "text\u{1b}]10;rgb:ff/ff/ff\u{07}more"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "textmore")
    }

    func testSanitize_OSCWithESCBackslash() {
        // OSC terminated by ESC \ (ST)
        let input = "text\u{1b}]7;file:///home/user\u{1b}\\more"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "textmore")
    }

    func testSanitize_BareOSC() {
        // Bare OSC without ESC prefix
        let input = "foo]10;rgb:00/00/00\u{07}bar"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "foobar")
    }

    // MARK: - sanitize: Bracketed Paste

    func testSanitize_BracketedPasteMarkers() {
        // [200~ = start, [201~ = end
        let input = "\u{1b}[200~pasted text\u{1b}[201~"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "pasted text")
    }

    func testSanitize_BareBracketedPaste() {
        let input = "[200~text[201~"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "text")
    }

    // MARK: - sanitize: Simple Escapes

    func testSanitize_ESCReset() {
        // ESC c = full reset
        let input = "before\u{1b}cafter"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "beforeafter")
    }

    func testSanitize_ESCSaveCursor() {
        // ESC 7 = save cursor, ESC 8 = restore cursor
        let input = "\u{1b}7text\u{1b}8"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "text")
    }

    // MARK: - sanitize: Control Characters

    func testSanitize_ControlCharactersRemoved() {
        // NUL, BEL, BS, etc. should be removed
        let input = "he\u{00}ll\u{07}o\u{08}"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "hello")
    }

    func testSanitize_PreservesNewlines() {
        let input = "line1\nline2\rline3"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "line1\nline2\rline3")
    }

    func testSanitize_PreservesTabs() {
        let input = "col1\tcol2\tcol3"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "col1\tcol2\tcol3")
    }

    func testSanitize_RemovesDEL() {
        // 0x7F = DEL
        let input = "hel\u{7f}lo"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "hello")
    }

    // MARK: - sanitize: Space Collapsing & Trimming

    func testSanitize_CollapsesMultipleSpaces() {
        let input = "hello     world"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "hello world")
    }

    func testSanitize_TrimsLeadingTrailingWhitespace() {
        let input = "   hello world   "
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "hello world")
    }

    // MARK: - sanitize: Combined / Edge Cases

    func testSanitize_CleanTextUnchanged() {
        let input = "just normal text"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "just normal text")
    }

    func testSanitize_EmptyString() {
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(""), "")
    }

    func testSanitize_OnlyEscapeSequences() {
        let input = "\u{1b}[32m\u{1b}[0m\u{1b}c"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "")
    }

    func testSanitize_MixedSequenceTypes() {
        // CSI + OSC + control chars
        let input = "\u{1b}[1mBold\u{1b}[0m \u{1b}]7;file:///tmp\u{07} \u{00}end"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "Bold end")
    }

    func testSanitize_UnicodePreserved() {
        let input = "Tâche terminée 🎉"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "Tâche terminée 🎉")
    }

    func testSanitize_UnicodeWithEscapes() {
        let input = "\u{1b}[32mRéussi\u{1b}[0m"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitize(input), "Réussi")
    }

    // MARK: - sanitizeForLogging

    func testSanitizeForLogging_ShortTextUnchanged() {
        let input = "Short message"
        XCTAssertEqual(EscapeSequenceSanitizer.sanitizeForLogging(input), "Short message")
    }

    func testSanitizeForLogging_TruncatesLongText() {
        let input = String(repeating: "a", count: 600)
        let result = EscapeSequenceSanitizer.sanitizeForLogging(input)
        XCTAssertEqual(result.count, 500)
        XCTAssertTrue(result.hasSuffix("..."))
    }

    func testSanitizeForLogging_CustomMaxLength() {
        let input = String(repeating: "b", count: 50)
        let result = EscapeSequenceSanitizer.sanitizeForLogging(input, maxLength: 20)
        XCTAssertEqual(result.count, 20)
        XCTAssertTrue(result.hasSuffix("..."))
    }

    func testSanitizeForLogging_ExactlyMaxLength() {
        let input = String(repeating: "c", count: 500)
        let result = EscapeSequenceSanitizer.sanitizeForLogging(input)
        XCTAssertEqual(result.count, 500)
        XCTAssertFalse(result.hasSuffix("..."))
    }

    func testSanitizeForLogging_AlsoStripsEscapes() {
        let input = "\u{1b}[31m" + String(repeating: "x", count: 10) + "\u{1b}[0m"
        let result = EscapeSequenceSanitizer.sanitizeForLogging(input)
        XCTAssertEqual(result, String(repeating: "x", count: 10))
    }

    // MARK: - containsEscapeSequences

    func testContainsEscapeSequences_ESCCharacter() {
        XCTAssertTrue(EscapeSequenceSanitizer.containsEscapeSequences("\u{1b}[32m"))
    }

    func testContainsEscapeSequences_BareFocusOut() {
        XCTAssertTrue(EscapeSequenceSanitizer.containsEscapeSequences("text[Omore"))
    }

    func testContainsEscapeSequences_BareFocusIn() {
        XCTAssertTrue(EscapeSequenceSanitizer.containsEscapeSequences("text[Imore"))
    }

    func testContainsEscapeSequences_BareOSCColor() {
        XCTAssertTrue(EscapeSequenceSanitizer.containsEscapeSequences("]10;rgb:ff/ff/ff"))
    }

    func testContainsEscapeSequences_BareOSCPath() {
        XCTAssertTrue(EscapeSequenceSanitizer.containsEscapeSequences("]7;file:///home"))
    }

    func testContainsEscapeSequences_BareBracketedPaste() {
        XCTAssertTrue(EscapeSequenceSanitizer.containsEscapeSequences("[200~"))
        XCTAssertTrue(EscapeSequenceSanitizer.containsEscapeSequences("[201~"))
    }

    func testContainsEscapeSequences_BareCSIQuestion() {
        XCTAssertTrue(EscapeSequenceSanitizer.containsEscapeSequences("[?7u"))
    }

    func testContainsEscapeSequences_CleanText() {
        XCTAssertFalse(EscapeSequenceSanitizer.containsEscapeSequences("hello world"))
    }

    func testContainsEscapeSequences_EmptyString() {
        XCTAssertFalse(EscapeSequenceSanitizer.containsEscapeSequences(""))
    }

    // MARK: - Performance: Space Collapse

    func testSanitize_ManyConsecutiveSpaces() {
        // Verify no quadratic blowup with many consecutive spaces
        let spaces = String(repeating: " ", count: 1000)
        let input = "start" + spaces + "end"
        let result = EscapeSequenceSanitizer.sanitize(input)
        XCTAssertEqual(result, "start end")
    }
}
