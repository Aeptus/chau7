import XCTest
@testable import Chau7Core

final class ConfigFileParserTests: XCTestCase {

    // MARK: - Section Headers

    func testParseSectionHeaders() {
        let content = """
        [general]
        shell = "/bin/zsh"

        [appearance]
        font_size = 14
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertNotNil(raw["general"])
        XCTAssertNotNil(raw["appearance"])
    }

    func testParseSectionHeaderWithSpaces() {
        let content = """
        [ general ]
        shell = "/bin/zsh"
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertNotNil(raw["general"])
    }

    // MARK: - Key Value Pairs

    func testParseKeyValuePairs() {
        let content = """
        [general]
        shell = "/bin/zsh"
        startup_command = "neofetch"
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
        XCTAssertEqual(raw["general"]?["startup_command"] as? String, "neofetch")
    }

    func testParseKeyValueWithoutSpaces() {
        let content = """
        [general]
        shell="/bin/zsh"
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
    }

    // MARK: - String Values

    func testParseDoubleQuotedString() {
        let content = """
        [general]
        shell = "/bin/zsh"
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
    }

    func testParseSingleQuotedString() {
        let content = """
        [general]
        shell = '/bin/zsh'
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
    }

    func testParseUnquotedString() {
        let content = """
        [appearance]
        cursor_style = block
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["appearance"]?["cursor_style"] as? String, "block")
    }

    // MARK: - Boolean Values

    func testParseBooleanTrue() {
        let content = """
        [terminal]
        bell_enabled = true
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["terminal"]?["bell_enabled"] as? Bool, true)
    }

    func testParseBooleanFalse() {
        let content = """
        [terminal]
        bell_enabled = false
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["terminal"]?["bell_enabled"] as? Bool, false)
    }

    func testParseBooleanCaseInsensitive() {
        let content = """
        [terminal]
        bell_enabled = True
        word_wrap = FALSE
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["terminal"]?["bell_enabled"] as? Bool, true)
        XCTAssertEqual(raw["terminal"]?["word_wrap"] as? Bool, false)
    }

    // MARK: - Integer Values

    func testParseInteger() {
        let content = """
        [terminal]
        scrollback_lines = 10000
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["terminal"]?["scrollback_lines"] as? Int, 10000)
    }

    func testParseZeroInteger() {
        let content = """
        [terminal]
        scrollback_lines = 0
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["terminal"]?["scrollback_lines"] as? Int, 0)
    }

    // MARK: - Double Values

    func testParseDouble() {
        let content = """
        [appearance]
        opacity = 0.85
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["appearance"]?["opacity"] as? Double, 0.85)
    }

    func testParseDoubleOnePointZero() {
        let content = """
        [appearance]
        opacity = 1.0
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["appearance"]?["opacity"] as? Double, 1.0)
    }

    // MARK: - Comments

    func testParseHashComments() {
        let content = """
        # This is a comment
        [general]
        # Another comment
        shell = "/bin/zsh"
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
        XCTAssertEqual(raw["general"]?.count, 1)
    }

    func testParseSlashSlashComments() {
        let content = """
        // This is a comment
        [general]
        // Another comment
        shell = "/bin/zsh"
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
        XCTAssertEqual(raw["general"]?.count, 1)
    }

    // MARK: - Empty Lines

    func testParseEmptyLines() {
        let content = """
        [general]

        shell = "/bin/zsh"

        startup_command = "neofetch"

        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
        XCTAssertEqual(raw["general"]?["startup_command"] as? String, "neofetch")
    }

    func testParseEmptyContent() {
        let config = ConfigFileParser.parse("")
        XCTAssertNil(config.general)
        XCTAssertNil(config.appearance)
        XCTAssertNil(config.terminal)
    }

    // MARK: - Profile Sections

    func testParseProfileSections() {
        let content = """
        [profile.work]
        font_family = "SF Mono"
        font_size = 12
        color_scheme = "Solarized Dark"

        [profile.personal]
        font_family = "Menlo"
        font_size = 14
        shell = "/bin/fish"
        """
        let config = ConfigFileParser.parse(content)
        XCTAssertNotNil(config.profiles?["work"])
        XCTAssertEqual(config.profiles?["work"]?.fontFamily, "SF Mono")
        XCTAssertEqual(config.profiles?["work"]?.fontSize, 12)
        XCTAssertEqual(config.profiles?["work"]?.colorScheme, "Solarized Dark")

        XCTAssertNotNil(config.profiles?["personal"])
        XCTAssertEqual(config.profiles?["personal"]?.fontFamily, "Menlo")
        XCTAssertEqual(config.profiles?["personal"]?.fontSize, 14)
        XCTAssertEqual(config.profiles?["personal"]?.shell, "/bin/fish")
    }

    // MARK: - Serialization Round-Trip

    func testSerializationRoundTrip() {
        let original = Chau7ConfigFile(
            general: .init(shell: "/bin/zsh", startupCommand: "neofetch", closeOnExit: true),
            appearance: .init(fontFamily: "Menlo", fontSize: 13, cursorStyle: "block", cursorBlink: false, opacity: 0.95),
            terminal: .init(scrollbackLines: 10000, bellEnabled: true, bellSound: "default"),
            keybindings: ["cmd+t": "newTab", "cmd+w": "closeTab"],
            profiles: ["work": .init(fontFamily: "SF Mono", fontSize: 12)]
        )

        let serialized = ConfigFileParser.serialize(original)
        let parsed = ConfigFileParser.parse(serialized)

        XCTAssertEqual(parsed.general?.shell, original.general?.shell)
        XCTAssertEqual(parsed.general?.startupCommand, original.general?.startupCommand)
        XCTAssertEqual(parsed.general?.closeOnExit, original.general?.closeOnExit)
        XCTAssertEqual(parsed.appearance?.fontFamily, original.appearance?.fontFamily)
        XCTAssertEqual(parsed.appearance?.fontSize, original.appearance?.fontSize)
        XCTAssertEqual(parsed.appearance?.cursorStyle, original.appearance?.cursorStyle)
        XCTAssertEqual(parsed.appearance?.cursorBlink, original.appearance?.cursorBlink)
        XCTAssertEqual(parsed.appearance?.opacity, original.appearance?.opacity)
        XCTAssertEqual(parsed.terminal?.scrollbackLines, original.terminal?.scrollbackLines)
        XCTAssertEqual(parsed.terminal?.bellEnabled, original.terminal?.bellEnabled)
        XCTAssertEqual(parsed.terminal?.bellSound, original.terminal?.bellSound)
        XCTAssertEqual(parsed.keybindings, original.keybindings)
        XCTAssertEqual(parsed.profiles?["work"]?.fontFamily, "SF Mono")
        XCTAssertEqual(parsed.profiles?["work"]?.fontSize, 12)
    }

    // MARK: - parseRaw Type Inference

    func testParseRawReturnsCorrectTypes() {
        let content = """
        [mixed]
        str_val = "hello"
        int_val = 42
        bool_val = true
        double_val = 3.14
        unquoted_str = world
        """
        let raw = ConfigFileParser.parseRaw(content)
        let section = raw["mixed"]!

        XCTAssertTrue(section["str_val"] is String)
        XCTAssertEqual(section["str_val"] as? String, "hello")

        XCTAssertTrue(section["int_val"] is Int)
        XCTAssertEqual(section["int_val"] as? Int, 42)

        XCTAssertTrue(section["bool_val"] is Bool)
        XCTAssertEqual(section["bool_val"] as? Bool, true)

        XCTAssertTrue(section["double_val"] is Double)
        XCTAssertEqual(section["double_val"] as? Double, 3.14)

        XCTAssertTrue(section["unquoted_str"] is String)
        XCTAssertEqual(section["unquoted_str"] as? String, "world")
    }

    // MARK: - Typed Chau7ConfigFile

    func testParseIntoTypedConfig() {
        let content = """
        [general]
        shell = "/bin/zsh"
        startup_command = "neofetch"
        default_directory = "~/Projects"
        close_on_exit = true
        confirm_close = false

        [appearance]
        font_family = "Menlo"
        font_size = 13
        color_scheme = "Solarized Dark"
        cursor_style = "beam"
        cursor_blink = true
        opacity = 0.9
        minimal_mode = false

        [terminal]
        scrollback_lines = 5000
        bell_enabled = false
        bell_sound = "ping"
        word_wrap = true
        mouse_reporting = true
        sixel_enabled = false
        kitty_graphics = true

        [keybindings]
        cmd+t = "newTab"
        cmd+w = "closeTab"
        """
        let config = ConfigFileParser.parse(content)

        // General
        XCTAssertEqual(config.general?.shell, "/bin/zsh")
        XCTAssertEqual(config.general?.startupCommand, "neofetch")
        XCTAssertEqual(config.general?.defaultDirectory, "~/Projects")
        XCTAssertEqual(config.general?.closeOnExit, true)
        XCTAssertEqual(config.general?.confirmClose, false)

        // Appearance
        XCTAssertEqual(config.appearance?.fontFamily, "Menlo")
        XCTAssertEqual(config.appearance?.fontSize, 13)
        XCTAssertEqual(config.appearance?.colorScheme, "Solarized Dark")
        XCTAssertEqual(config.appearance?.cursorStyle, "beam")
        XCTAssertEqual(config.appearance?.cursorBlink, true)
        XCTAssertEqual(config.appearance?.opacity, 0.9)
        XCTAssertEqual(config.appearance?.minimalMode, false)

        // Terminal
        XCTAssertEqual(config.terminal?.scrollbackLines, 5000)
        XCTAssertEqual(config.terminal?.bellEnabled, false)
        XCTAssertEqual(config.terminal?.bellSound, "ping")
        XCTAssertEqual(config.terminal?.wordWrap, true)
        XCTAssertEqual(config.terminal?.mouseReporting, true)
        XCTAssertEqual(config.terminal?.sixelEnabled, false)
        XCTAssertEqual(config.terminal?.kittyGraphics, true)

        // Keybindings
        XCTAssertEqual(config.keybindings?["cmd+t"], "newTab")
        XCTAssertEqual(config.keybindings?["cmd+w"], "closeTab")
    }

    // MARK: - Global Keys (no section)

    func testParseGlobalKeysOutsideSection() {
        let content = """
        some_key = "some_value"

        [general]
        shell = "/bin/zsh"
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["__global__"]?["some_key"] as? String, "some_value")
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
    }

    // MARK: - Malformed Lines

    func testSkipsMalformedLines() {
        let content = """
        [general]
        shell = "/bin/zsh"
        this has no equals sign
        startup_command = "neofetch"
        """
        let raw = ConfigFileParser.parseRaw(content)
        XCTAssertEqual(raw["general"]?["shell"] as? String, "/bin/zsh")
        XCTAssertEqual(raw["general"]?["startup_command"] as? String, "neofetch")
        // Malformed line should be silently skipped
        XCTAssertEqual(raw["general"]?.count, 2)
    }

    // MARK: - Serialize Empty Config

    func testSerializeEmptyConfig() {
        let config = Chau7ConfigFile()
        let serialized = ConfigFileParser.serialize(config)
        XCTAssertTrue(serialized.contains("# Chau7 Configuration"))
    }

    // MARK: - Multiple Profiles

    func testSerializeEscapesSpecialCharacters() {
        let config = Chau7ConfigFile(
            general: .init(shell: "/bin/zsh", startupCommand: "echo \"hello\\nworld\"")
        )
        let serialized = ConfigFileParser.serialize(config)
        // Backslash and quote should be escaped
        XCTAssertTrue(serialized.contains("\\\\"))
        XCTAssertTrue(serialized.contains("\\\""))
    }

    func testMultipleProfiles() {
        let content = """
        [profile.dev]
        font_family = "Fira Code"
        font_size = 14

        [profile.presentation]
        font_family = "SF Mono"
        font_size = 24
        color_scheme = "Light"

        [profile.ssh]
        shell = "/bin/bash"
        """
        let config = ConfigFileParser.parse(content)

        XCTAssertEqual(config.profiles?.count, 3)
        XCTAssertEqual(config.profiles?["dev"]?.fontFamily, "Fira Code")
        XCTAssertEqual(config.profiles?["dev"]?.fontSize, 14)
        XCTAssertEqual(config.profiles?["presentation"]?.fontFamily, "SF Mono")
        XCTAssertEqual(config.profiles?["presentation"]?.fontSize, 24)
        XCTAssertEqual(config.profiles?["presentation"]?.colorScheme, "Light")
        XCTAssertEqual(config.profiles?["ssh"]?.shell, "/bin/bash")
    }
}
