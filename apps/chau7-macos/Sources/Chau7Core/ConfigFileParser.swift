import Foundation

/// Parsed configuration from a .chau7 config file.
/// Supports a TOML-like format with sections, key=value pairs, and basic types.
public struct Chau7ConfigFile: Codable, Equatable, Sendable {
    public var general: GeneralConfig?
    public var appearance: AppearanceConfig?
    public var terminal: TerminalConfig?
    public var keybindings: [String: String]?
    public var profiles: [String: ProfileConfig]?

    public init(
        general: GeneralConfig? = nil,
        appearance: AppearanceConfig? = nil,
        terminal: TerminalConfig? = nil,
        keybindings: [String: String]? = nil,
        profiles: [String: ProfileConfig]? = nil
    ) {
        self.general = general
        self.appearance = appearance
        self.terminal = terminal
        self.keybindings = keybindings
        self.profiles = profiles
    }

    public struct GeneralConfig: Codable, Equatable, Sendable {
        public var shell: String?
        public var startupCommand: String?
        public var defaultDirectory: String?
        public var closeOnExit: Bool?
        public var confirmClose: Bool?

        public init(
            shell: String? = nil,
            startupCommand: String? = nil,
            defaultDirectory: String? = nil,
            closeOnExit: Bool? = nil,
            confirmClose: Bool? = nil
        ) {
            self.shell = shell
            self.startupCommand = startupCommand
            self.defaultDirectory = defaultDirectory
            self.closeOnExit = closeOnExit
            self.confirmClose = confirmClose
        }
    }

    public struct AppearanceConfig: Codable, Equatable, Sendable {
        public var fontFamily: String?
        public var fontSize: Int?
        public var colorScheme: String?
        public var cursorStyle: String?
        public var cursorBlink: Bool?
        public var opacity: Double?
        public var minimalMode: Bool?

        public init(
            fontFamily: String? = nil,
            fontSize: Int? = nil,
            colorScheme: String? = nil,
            cursorStyle: String? = nil,
            cursorBlink: Bool? = nil,
            opacity: Double? = nil,
            minimalMode: Bool? = nil
        ) {
            self.fontFamily = fontFamily
            self.fontSize = fontSize
            self.colorScheme = colorScheme
            self.cursorStyle = cursorStyle
            self.cursorBlink = cursorBlink
            self.opacity = opacity
            self.minimalMode = minimalMode
        }
    }

    public struct TerminalConfig: Codable, Equatable, Sendable {
        public var scrollbackLines: Int?
        public var bellEnabled: Bool?
        public var bellSound: String?
        public var wordWrap: Bool?
        public var mouseReporting: Bool?
        public var sixelEnabled: Bool?
        public var kittyGraphics: Bool?

        public init(
            scrollbackLines: Int? = nil,
            bellEnabled: Bool? = nil,
            bellSound: String? = nil,
            wordWrap: Bool? = nil,
            mouseReporting: Bool? = nil,
            sixelEnabled: Bool? = nil,
            kittyGraphics: Bool? = nil
        ) {
            self.scrollbackLines = scrollbackLines
            self.bellEnabled = bellEnabled
            self.bellSound = bellSound
            self.wordWrap = wordWrap
            self.mouseReporting = mouseReporting
            self.sixelEnabled = sixelEnabled
            self.kittyGraphics = kittyGraphics
        }
    }

    public struct ProfileConfig: Codable, Equatable, Sendable {
        public var fontFamily: String?
        public var fontSize: Int?
        public var colorScheme: String?
        public var shell: String?

        public init(
            fontFamily: String? = nil,
            fontSize: Int? = nil,
            colorScheme: String? = nil,
            shell: String? = nil
        ) {
            self.fontFamily = fontFamily
            self.fontSize = fontSize
            self.colorScheme = colorScheme
            self.shell = shell
        }
    }
}

/// Parser for TOML-like configuration files.
/// Supports: [sections], key = value, strings, integers, booleans, arrays.
public enum ConfigFileParser {

    public enum ParseError: Error, Equatable, Sendable {
        case invalidLine(Int, String)
        case duplicateSection(String)
        case invalidValue(String, String)
    }

    // MARK: - Helpers

    private static func escapeValue(_ v: String) -> String {
        v.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Parse TOML-like config content into a dictionary structure
    public static func parseRaw(_ content: String) -> [String: [String: Any]] {
        var sections: [String: [String: String]] = [:]
        var currentSection = "__global__"
        sections[currentSection] = [:]

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }

            // Section header
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let name = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentSection = name
                if sections[currentSection] == nil {
                    sections[currentSection] = [:]
                }
                continue
            }

            // Key = Value
            guard let eqIdx = trimmed.firstIndex(of: "=") else {
                continue // Skip malformed lines silently
            }

            let key = String(trimmed[trimmed.startIndex ..< eqIdx]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)

            // Strip quotes from string values
            let value: String
            if (rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")) ||
                (rawValue.hasPrefix("'") && rawValue.hasSuffix("'")) {
                value = String(rawValue.dropFirst().dropLast())
            } else {
                value = rawValue
            }

            sections[currentSection]?[key] = value
        }

        // Convert to [String: Any] with type inference
        var result: [String: [String: Any]] = [:]
        for (section, pairs) in sections {
            var converted: [String: Any] = [:]
            for (key, value) in pairs {
                converted[key] = inferType(value)
            }
            result[section] = converted
        }

        return result
    }

    /// Parse config content into a typed Chau7ConfigFile
    public static func parse(_ content: String) -> Chau7ConfigFile {
        var config = Chau7ConfigFile()
        let raw = parseRaw(content)

        // Map sections to config struct
        if let general = raw["general"] {
            config.general = Chau7ConfigFile.GeneralConfig(
                shell: general["shell"] as? String,
                startupCommand: general["startup_command"] as? String,
                defaultDirectory: general["default_directory"] as? String,
                closeOnExit: general["close_on_exit"] as? Bool,
                confirmClose: general["confirm_close"] as? Bool
            )
        }

        if let appearance = raw["appearance"] {
            config.appearance = Chau7ConfigFile.AppearanceConfig(
                fontFamily: appearance["font_family"] as? String,
                fontSize: appearance["font_size"] as? Int,
                colorScheme: appearance["color_scheme"] as? String,
                cursorStyle: appearance["cursor_style"] as? String,
                cursorBlink: appearance["cursor_blink"] as? Bool,
                opacity: appearance["opacity"] as? Double,
                minimalMode: appearance["minimal_mode"] as? Bool
            )
        }

        if let terminal = raw["terminal"] {
            config.terminal = Chau7ConfigFile.TerminalConfig(
                scrollbackLines: terminal["scrollback_lines"] as? Int,
                bellEnabled: terminal["bell_enabled"] as? Bool,
                bellSound: terminal["bell_sound"] as? String,
                wordWrap: terminal["word_wrap"] as? Bool,
                mouseReporting: terminal["mouse_reporting"] as? Bool,
                sixelEnabled: terminal["sixel_enabled"] as? Bool,
                kittyGraphics: terminal["kitty_graphics"] as? Bool
            )
        }

        if let keybindings = raw["keybindings"] {
            config.keybindings = keybindings.compactMapValues { $0 as? String }
        }

        // Parse [profile.name] sections
        config.profiles = [:]
        for (key, values) in raw where key.hasPrefix("profile.") {
            let profileName = String(key.dropFirst("profile.".count))
            config.profiles?[profileName] = Chau7ConfigFile.ProfileConfig(
                fontFamily: values["font_family"] as? String,
                fontSize: values["font_size"] as? Int,
                colorScheme: values["color_scheme"] as? String,
                shell: values["shell"] as? String
            )
        }

        return config
    }

    /// Serialize a config file back to TOML-like format
    public static func serialize(_ config: Chau7ConfigFile) -> String {
        var lines: [String] = ["# Chau7 Configuration", "# https://github.com/your/chau7", ""]

        if let g = config.general {
            lines.append("[general]")
            if let v = g.shell { lines.append("shell = \"\(escapeValue(v))\"") }
            if let v = g.startupCommand { lines.append("startup_command = \"\(escapeValue(v))\"") }
            if let v = g.defaultDirectory { lines.append("default_directory = \"\(escapeValue(v))\"") }
            if let v = g.closeOnExit { lines.append("close_on_exit = \(v)") }
            if let v = g.confirmClose { lines.append("confirm_close = \(v)") }
            lines.append("")
        }

        if let a = config.appearance {
            lines.append("[appearance]")
            if let v = a.fontFamily { lines.append("font_family = \"\(escapeValue(v))\"") }
            if let v = a.fontSize { lines.append("font_size = \(v)") }
            if let v = a.colorScheme { lines.append("color_scheme = \"\(escapeValue(v))\"") }
            if let v = a.cursorStyle { lines.append("cursor_style = \"\(escapeValue(v))\"") }
            if let v = a.cursorBlink { lines.append("cursor_blink = \(v)") }
            if let v = a.opacity { lines.append("opacity = \(v)") }
            if let v = a.minimalMode { lines.append("minimal_mode = \(v)") }
            lines.append("")
        }

        if let t = config.terminal {
            lines.append("[terminal]")
            if let v = t.scrollbackLines { lines.append("scrollback_lines = \(v)") }
            if let v = t.bellEnabled { lines.append("bell_enabled = \(v)") }
            if let v = t.bellSound { lines.append("bell_sound = \"\(escapeValue(v))\"") }
            if let v = t.wordWrap { lines.append("word_wrap = \(v)") }
            if let v = t.mouseReporting { lines.append("mouse_reporting = \(v)") }
            if let v = t.sixelEnabled { lines.append("sixel_enabled = \(v)") }
            if let v = t.kittyGraphics { lines.append("kitty_graphics = \(v)") }
            lines.append("")
        }

        if let kb = config.keybindings, !kb.isEmpty {
            lines.append("[keybindings]")
            for (key, value) in kb.sorted(by: { $0.key < $1.key }) {
                lines.append("\(key) = \"\(escapeValue(value))\"")
            }
            lines.append("")
        }

        if let profiles = config.profiles {
            for (name, p) in profiles.sorted(by: { $0.key < $1.key }) {
                lines.append("[profile.\(name)]")
                if let v = p.fontFamily { lines.append("font_family = \"\(escapeValue(v))\"") }
                if let v = p.fontSize { lines.append("font_size = \(v)") }
                if let v = p.colorScheme { lines.append("color_scheme = \"\(escapeValue(v))\"") }
                if let v = p.shell { lines.append("shell = \"\(escapeValue(v))\"") }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func inferType(_ value: String) -> Any {
        // Boolean
        let lower = value.lowercased()
        if lower == "true" { return true }
        if lower == "false" { return false }

        // Integer
        if let intVal = Int(value) { return intVal }

        // Double
        if let dblVal = Double(value), value.contains(".") { return dblVal }

        // String (default)
        return value
    }
}

extension ConfigFileParser.ParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLine(let line, let content):
            return "Invalid config at line \(line): \(content)"
        case .duplicateSection(let name):
            return "Duplicate config section: [\(name)]"
        case .invalidValue(let key, let value):
            return "Invalid value for '\(key)': \(value)"
        }
    }
}
