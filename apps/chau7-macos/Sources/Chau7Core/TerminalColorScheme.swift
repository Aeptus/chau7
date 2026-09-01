import Foundation

// MARK: - Terminal Color Scheme

/// Pure-data terminal color scheme with all 16 ANSI colors plus background,
/// foreground, cursor, and selection colors, stored as hex strings.
///
/// This lives in `Chau7Core` (no AppKit/UIKit) so it can be shared by both the
/// macOS app and the iOS remote app. Platform-specific color conversions
/// (`NSColor` on macOS, `UIColor` on iOS) are provided by extensions in the
/// respective app targets.
public struct TerminalColorScheme: Codable, Identifiable, Equatable, Sendable {
    public var id: String {
        name
    }

    public let name: String
    public let background: String // Hex color
    public let foreground: String
    public let cursor: String
    public let selection: String
    public let black: String
    public let red: String
    public let green: String
    public let yellow: String
    public let blue: String
    public let magenta: String
    public let cyan: String
    public let white: String
    public let brightBlack: String
    public let brightRed: String
    public let brightGreen: String
    public let brightYellow: String
    public let brightBlue: String
    public let brightMagenta: String
    public let brightCyan: String
    public let brightWhite: String

    public init(
        name: String,
        background: String,
        foreground: String,
        cursor: String,
        selection: String,
        black: String,
        red: String,
        green: String,
        yellow: String,
        blue: String,
        magenta: String,
        cyan: String,
        white: String,
        brightBlack: String,
        brightRed: String,
        brightGreen: String,
        brightYellow: String,
        brightBlue: String,
        brightMagenta: String,
        brightCyan: String,
        brightWhite: String
    ) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.black = black
        self.red = red
        self.green = green
        self.yellow = yellow
        self.blue = blue
        self.magenta = magenta
        self.cyan = cyan
        self.white = white
        self.brightBlack = brightBlack
        self.brightRed = brightRed
        self.brightGreen = brightGreen
        self.brightYellow = brightYellow
        self.brightBlue = brightBlue
        self.brightMagenta = brightMagenta
        self.brightCyan = brightCyan
        self.brightWhite = brightWhite
    }

    // MARK: - Preset Schemes

    public static let `default` = TerminalColorScheme(
        name: "Default",
        background: "#1E1E1E", foreground: "#D4D4D4", cursor: "#FFFFFF", selection: "#264F78",
        black: "#000000", red: "#CD3131", green: "#0DBC79", yellow: "#E5E510",
        blue: "#2472C8", magenta: "#BC3FBC", cyan: "#11A8CD", white: "#E5E5E5",
        brightBlack: "#666666", brightRed: "#F14C4C", brightGreen: "#23D18B", brightYellow: "#F5F543",
        brightBlue: "#3B8EEA", brightMagenta: "#D670D6", brightCyan: "#29B8DB", brightWhite: "#FFFFFF"
    )

    public static let solarizedDark = TerminalColorScheme(
        name: "Solarized Dark",
        background: "#002B36", foreground: "#839496", cursor: "#93A1A1", selection: "#073642",
        black: "#073642", red: "#DC322F", green: "#859900", yellow: "#B58900",
        blue: "#268BD2", magenta: "#D33682", cyan: "#2AA198", white: "#EEE8D5",
        brightBlack: "#002B36", brightRed: "#CB4B16", brightGreen: "#586E75", brightYellow: "#657B83",
        brightBlue: "#839496", brightMagenta: "#6C71C4", brightCyan: "#93A1A1", brightWhite: "#FDF6E3"
    )

    public static let solarizedLight = TerminalColorScheme(
        name: "Solarized Light",
        background: "#FDF6E3", foreground: "#657B83", cursor: "#586E75", selection: "#EEE8D5",
        black: "#073642", red: "#DC322F", green: "#859900", yellow: "#B58900",
        blue: "#268BD2", magenta: "#D33682", cyan: "#2AA198", white: "#EEE8D5",
        brightBlack: "#002B36", brightRed: "#CB4B16", brightGreen: "#586E75", brightYellow: "#657B83",
        brightBlue: "#839496", brightMagenta: "#6C71C4", brightCyan: "#93A1A1", brightWhite: "#FDF6E3"
    )

    public static let dracula = TerminalColorScheme(
        name: "Dracula",
        background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A",
        black: "#21222C", red: "#FF5555", green: "#50FA7B", yellow: "#F1FA8C",
        blue: "#BD93F9", magenta: "#FF79C6", cyan: "#8BE9FD", white: "#F8F8F2",
        brightBlack: "#6272A4", brightRed: "#FF6E6E", brightGreen: "#69FF94", brightYellow: "#FFFFA5",
        brightBlue: "#D6ACFF", brightMagenta: "#FF92DF", brightCyan: "#A4FFFF", brightWhite: "#FFFFFF"
    )

    public static let nord = TerminalColorScheme(
        name: "Nord",
        background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E",
        black: "#3B4252", red: "#BF616A", green: "#A3BE8C", yellow: "#EBCB8B",
        blue: "#81A1C1", magenta: "#B48EAD", cyan: "#88C0D0", white: "#E5E9F0",
        brightBlack: "#4C566A", brightRed: "#BF616A", brightGreen: "#A3BE8C", brightYellow: "#EBCB8B",
        brightBlue: "#81A1C1", brightMagenta: "#B48EAD", brightCyan: "#8FBCBB", brightWhite: "#ECEFF4"
    )

    public static let monokai = TerminalColorScheme(
        name: "Monokai",
        background: "#272822", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#49483E",
        black: "#272822", red: "#F92672", green: "#A6E22E", yellow: "#F4BF75",
        blue: "#66D9EF", magenta: "#AE81FF", cyan: "#A1EFE4", white: "#F8F8F2",
        brightBlack: "#75715E", brightRed: "#F92672", brightGreen: "#A6E22E", brightYellow: "#F4BF75",
        brightBlue: "#66D9EF", brightMagenta: "#AE81FF", brightCyan: "#A1EFE4", brightWhite: "#F9F8F5"
    )

    public static let gruvboxDark = TerminalColorScheme(
        name: "Gruvbox Dark",
        background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945",
        black: "#282828", red: "#CC241D", green: "#98971A", yellow: "#D79921",
        blue: "#458588", magenta: "#B16286", cyan: "#689D6A", white: "#A89984",
        brightBlack: "#928374", brightRed: "#FB4934", brightGreen: "#B8BB26", brightYellow: "#FABD2F",
        brightBlue: "#83A598", brightMagenta: "#D3869B", brightCyan: "#8EC07C", brightWhite: "#EBDBB2"
    )

    public static let tokyoNight = TerminalColorScheme(
        name: "Tokyo Night",
        background: "#1A1B26", foreground: "#A9B1D6", cursor: "#C0CAF5", selection: "#33467C",
        black: "#15161E", red: "#F7768E", green: "#9ECE6A", yellow: "#E0AF68",
        blue: "#7AA2F7", magenta: "#BB9AF7", cyan: "#7DCFFF", white: "#A9B1D6",
        brightBlack: "#414868", brightRed: "#F7768E", brightGreen: "#9ECE6A", brightYellow: "#E0AF68",
        brightBlue: "#7AA2F7", brightMagenta: "#BB9AF7", brightCyan: "#7DCFFF", brightWhite: "#C0CAF5"
    )

    /// All available preset color schemes
    public static let allPresets: [TerminalColorScheme] = [
        .default, .solarizedDark, .solarizedLight, .dracula, .nord, .monokai, .gruvboxDark, .tokyoNight
    ]

    /// A unique signature for this color scheme based on all colors
    public var signature: String {
        [
            name, background, foreground, cursor, selection,
            black, red, green, yellow, blue, magenta, cyan, white,
            brightBlack, brightRed, brightGreen, brightYellow, brightBlue,
            brightMagenta, brightCyan, brightWhite
        ].joined(separator: "|")
    }

    // MARK: - FFI Color Bytes

    /// Converts a hex color string to an 8-bit RGB triplet, using `ColorParsing`.
    /// Falls back to black for invalid hex.
    public func rgb888(_ hex: String) -> (UInt8, UInt8, UInt8) {
        guard let rgb = ColorParsing.parseHex(hex) else { return (0, 0, 0) }
        return (
            UInt8((rgb.red * 255).rounded()),
            UInt8((rgb.green * 255).rounded()),
            UInt8((rgb.blue * 255).rounded())
        )
    }

    /// Foreground color as an 8-bit RGB triplet for the FFI `set_colors` call.
    public var foregroundRGB888: (UInt8, UInt8, UInt8) {
        rgb888(foreground)
    }

    /// Background color as an 8-bit RGB triplet for the FFI `set_colors` call.
    public var backgroundRGB888: (UInt8, UInt8, UInt8) {
        rgb888(background)
    }

    /// Cursor color as an 8-bit RGB triplet for the FFI `set_colors` call.
    public var cursorRGB888: (UInt8, UInt8, UInt8) {
        rgb888(cursor)
    }

    /// The 16 ANSI palette colors packed as 48 bytes (3 per color) in the exact
    /// order the Rust FFI (`chau7_terminal_set_colors`) expects:
    /// black, red, green, yellow, blue, magenta, cyan, white, then the 8 bright
    /// variants. Matches `RustTerminalView.applyColorScheme` on macOS.
    public var paletteBytes: [UInt8] {
        let ordered = [
            black, red, green, yellow, blue, magenta, cyan, white,
            brightBlack, brightRed, brightGreen, brightYellow,
            brightBlue, brightMagenta, brightCyan, brightWhite
        ]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(48)
        for hex in ordered {
            let (r, g, b) = rgb888(hex)
            bytes.append(r)
            bytes.append(g)
            bytes.append(b)
        }
        return bytes
    }
}
