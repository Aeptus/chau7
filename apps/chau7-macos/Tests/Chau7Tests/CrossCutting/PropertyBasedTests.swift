import XCTest
@testable import Chau7Core

/// Property-based / fuzz-style tests that verify invariants hold across randomized inputs.
final class PropertyBasedTests: XCTestCase {

    // MARK: - ColorParsing Round-Trip

    func testColorParsingRoundTrip() {
        for _ in 0 ..< 100 {
            let r = Double.random(in: 0 ... 1)
            let g = Double.random(in: 0 ... 1)
            let b = Double.random(in: 0 ... 1)
            let rgb = ColorParsing.RGB(red: r, green: g, blue: b)
            let hex = ColorParsing.toHex(rgb)
            guard let parsed = ColorParsing.parseHex(hex) else {
                XCTFail("Failed to parse hex \(hex)")
                continue
            }
            // Allow ±1/255 rounding error
            XCTAssertEqual(parsed.red, rgb.red, accuracy: 1.0 / 255 + 0.001)
            XCTAssertEqual(parsed.green, rgb.green, accuracy: 1.0 / 255 + 0.001)
            XCTAssertEqual(parsed.blue, rgb.blue, accuracy: 1.0 / 255 + 0.001)
        }
    }

    func testColorParsingClampsOutOfRange() {
        // Values outside 0...1 should be clamped in toHex
        let rgb = ColorParsing.RGB(red: -0.5, green: 1.5, blue: 2.0)
        let hex = ColorParsing.toHex(rgb)
        guard let parsed = ColorParsing.parseHex(hex) else {
            XCTFail("Failed to parse hex \(hex)")
            return
        }
        XCTAssertEqual(parsed.red, 0.0, accuracy: 0.01)
        XCTAssertEqual(parsed.green, 1.0, accuracy: 0.01)
        XCTAssertEqual(parsed.blue, 1.0, accuracy: 0.01)
    }

    // MARK: - ShellEscaping: No Unescaped Single Quotes

    func testEscapeArgumentNeverProducesUnescapedSingleQuotes() {
        let chars: [Character] = Array("abcABC123 !@#$%^&*()_+-=[]{}|;':\",./<>?~`\n\t\\")
        for _ in 0 ..< 200 {
            let length = Int.random(in: 0 ... 20)
            let input = String((0 ..< length).map { _ in chars.randomElement()! })
            let escaped = ShellEscaping.escapeArgument(input)
            // The escaped string should be parseable by a POSIX shell
            // It must start and end with single quote (the overall quoting)
            XCTAssertTrue(escaped.hasPrefix("'"), "Missing opening quote for: \(input)")
            XCTAssertTrue(escaped.hasSuffix("'"), "Missing closing quote for: \(input)")
        }
    }

    // MARK: - FrameParser: Encode-Pack-Parse Round-Trip

    func testFrameParserRoundTrip() {
        for _ in 0 ..< 50 {
            let payloadSize = Int.random(in: 0 ... 200)
            let payload = Data((0 ..< payloadSize).map { _ in UInt8.random(in: 0 ... 255) })
            let frame = RemoteFrame(
                version: 1,
                type: UInt8.random(in: 0 ... 5),
                flags: UInt8.random(in: 0 ... 255),
                reserved: 0,
                tabID: UInt32.random(in: 0 ... UInt32.max),
                seq: UInt64.random(in: 0 ... UInt64.max),
                payload: payload
            )

            let packed = FrameParser.packForTransport(frame)
            var buffer = packed
            let result = FrameParser.parseFrames(from: &buffer)

            XCTAssertEqual(result.frames.count, 1)
            XCTAssertEqual(result.frames.first, frame)
            XCTAssertTrue(result.errors.isEmpty)
            XCTAssertTrue(buffer.isEmpty)
        }
    }

    // MARK: - SnippetParsing: Placeholders Sorted Ascending

    func testSnippetPlaceholdersSortedAscending() {
        let snippets = [
            "${3:third} ${1:first} ${2:second}",
            "${2} middle ${1}",
            "${5:e} ${3:c} ${1:a} ${4:d} ${2:b}",
            "no placeholders here",
            "${1:only one}",
            "${0:final} ${2:second} ${1:first}"
        ]

        for snippet in snippets {
            let result = SnippetParsing.expandPlaceholders(in: snippet)
            guard result.placeholders.count > 1 else { continue }
            for i in 1 ..< result.placeholders.count {
                let prev = result.placeholders[i - 1]
                let curr = result.placeholders[i]
                XCTAssertTrue(
                    prev.index < curr.index || (prev.index == curr.index && prev.start <= curr.start),
                    "Placeholders not sorted in: \(snippet)"
                )
            }
        }
    }

    // MARK: - ConfigFileParser: Serialize-Parse Round-Trip

    func testConfigFileParserRoundTrip() {
        let configs: [Chau7ConfigFile] = [
            Chau7ConfigFile(),
            Chau7ConfigFile(general: .init(shell: "/bin/zsh")),
            Chau7ConfigFile(
                general: .init(shell: "/bin/bash", closeOnExit: true),
                appearance: .init(fontFamily: "Menlo", fontSize: 14, opacity: 0.9),
                terminal: .init(scrollbackLines: 5000, bellEnabled: false),
                keybindings: ["cmd+t": "newTab"],
                profiles: ["work": .init(fontFamily: "SF Mono", fontSize: 12)]
            )
        ]

        for original in configs {
            let serialized = ConfigFileParser.serialize(original)
            let parsed = ConfigFileParser.parse(serialized)

            XCTAssertEqual(parsed.general?.shell, original.general?.shell)
            XCTAssertEqual(parsed.general?.closeOnExit, original.general?.closeOnExit)
            XCTAssertEqual(parsed.appearance?.fontFamily, original.appearance?.fontFamily)
            XCTAssertEqual(parsed.appearance?.fontSize, original.appearance?.fontSize)
            XCTAssertEqual(parsed.appearance?.opacity, original.appearance?.opacity)
            XCTAssertEqual(parsed.terminal?.scrollbackLines, original.terminal?.scrollbackLines)
            XCTAssertEqual(parsed.terminal?.bellEnabled, original.terminal?.bellEnabled)
            XCTAssertEqual(parsed.keybindings, original.keybindings)
            if let origProfiles = original.profiles {
                for (name, profile) in origProfiles {
                    XCTAssertEqual(parsed.profiles?[name]?.fontFamily, profile.fontFamily)
                    XCTAssertEqual(parsed.profiles?[name]?.fontSize, profile.fontSize)
                }
            }
        }
    }

    // MARK: - EscapeSequenceSanitizer: Idempotent

    func testSanitizeIsIdempotent() {
        let inputs = [
            "clean text",
            "  spaced  out  ",
            "\u{1b}[32mGreen\u{1b}[0m",
            "\u{1b}]7;file:///tmp\u{07}path",
            "mixed\u{1b}[1m bold \u{00} control"
        ]

        for input in inputs {
            let once = EscapeSequenceSanitizer.sanitize(input)
            let twice = EscapeSequenceSanitizer.sanitize(once)
            XCTAssertEqual(once, twice, "Sanitize not idempotent for: \(input)")
        }
    }
}
