import Foundation
import AppKit

// MARK: - Terminal Color Scheme

/// Represents a terminal color scheme with all 16 ANSI colors plus background, foreground, cursor, and selection colors.
/// Includes caching for performance optimization when converting hex values to NSColor.
struct TerminalColorScheme: Codable, Identifiable, Equatable {
    var id: String {
        name
    }

    let name: String
    let background: String // Hex color
    let foreground: String
    let cursor: String
    let selection: String
    let black: String
    let red: String
    let green: String
    let yellow: String
    let blue: String
    let magenta: String
    let cyan: String
    let white: String
    let brightBlack: String
    let brightRed: String
    let brightGreen: String
    let brightYellow: String
    let brightBlue: String
    let brightMagenta: String
    let brightCyan: String
    let brightWhite: String

    // MARK: - Preset Schemes

    static let `default` = TerminalColorScheme(
        name: "Default",
        background: "#1E1E1E", foreground: "#D4D4D4", cursor: "#FFFFFF", selection: "#264F78",
        black: "#000000", red: "#CD3131", green: "#0DBC79", yellow: "#E5E510",
        blue: "#2472C8", magenta: "#BC3FBC", cyan: "#11A8CD", white: "#E5E5E5",
        brightBlack: "#666666", brightRed: "#F14C4C", brightGreen: "#23D18B", brightYellow: "#F5F543",
        brightBlue: "#3B8EEA", brightMagenta: "#D670D6", brightCyan: "#29B8DB", brightWhite: "#FFFFFF"
    )

    static let solarizedDark = TerminalColorScheme(
        name: "Solarized Dark",
        background: "#002B36", foreground: "#839496", cursor: "#93A1A1", selection: "#073642",
        black: "#073642", red: "#DC322F", green: "#859900", yellow: "#B58900",
        blue: "#268BD2", magenta: "#D33682", cyan: "#2AA198", white: "#EEE8D5",
        brightBlack: "#002B36", brightRed: "#CB4B16", brightGreen: "#586E75", brightYellow: "#657B83",
        brightBlue: "#839496", brightMagenta: "#6C71C4", brightCyan: "#93A1A1", brightWhite: "#FDF6E3"
    )

    static let solarizedLight = TerminalColorScheme(
        name: "Solarized Light",
        background: "#FDF6E3", foreground: "#657B83", cursor: "#586E75", selection: "#EEE8D5",
        black: "#073642", red: "#DC322F", green: "#859900", yellow: "#B58900",
        blue: "#268BD2", magenta: "#D33682", cyan: "#2AA198", white: "#EEE8D5",
        brightBlack: "#002B36", brightRed: "#CB4B16", brightGreen: "#586E75", brightYellow: "#657B83",
        brightBlue: "#839496", brightMagenta: "#6C71C4", brightCyan: "#93A1A1", brightWhite: "#FDF6E3"
    )

    static let dracula = TerminalColorScheme(
        name: "Dracula",
        background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A",
        black: "#21222C", red: "#FF5555", green: "#50FA7B", yellow: "#F1FA8C",
        blue: "#BD93F9", magenta: "#FF79C6", cyan: "#8BE9FD", white: "#F8F8F2",
        brightBlack: "#6272A4", brightRed: "#FF6E6E", brightGreen: "#69FF94", brightYellow: "#FFFFA5",
        brightBlue: "#D6ACFF", brightMagenta: "#FF92DF", brightCyan: "#A4FFFF", brightWhite: "#FFFFFF"
    )

    static let nord = TerminalColorScheme(
        name: "Nord",
        background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E",
        black: "#3B4252", red: "#BF616A", green: "#A3BE8C", yellow: "#EBCB8B",
        blue: "#81A1C1", magenta: "#B48EAD", cyan: "#88C0D0", white: "#E5E9F0",
        brightBlack: "#4C566A", brightRed: "#BF616A", brightGreen: "#A3BE8C", brightYellow: "#EBCB8B",
        brightBlue: "#81A1C1", brightMagenta: "#B48EAD", brightCyan: "#8FBCBB", brightWhite: "#ECEFF4"
    )

    static let monokai = TerminalColorScheme(
        name: "Monokai",
        background: "#272822", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#49483E",
        black: "#272822", red: "#F92672", green: "#A6E22E", yellow: "#F4BF75",
        blue: "#66D9EF", magenta: "#AE81FF", cyan: "#A1EFE4", white: "#F8F8F2",
        brightBlack: "#75715E", brightRed: "#F92672", brightGreen: "#A6E22E", brightYellow: "#F4BF75",
        brightBlue: "#66D9EF", brightMagenta: "#AE81FF", brightCyan: "#A1EFE4", brightWhite: "#F9F8F5"
    )

    static let gruvboxDark = TerminalColorScheme(
        name: "Gruvbox Dark",
        background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945",
        black: "#282828", red: "#CC241D", green: "#98971A", yellow: "#D79921",
        blue: "#458588", magenta: "#B16286", cyan: "#689D6A", white: "#A89984",
        brightBlack: "#928374", brightRed: "#FB4934", brightGreen: "#B8BB26", brightYellow: "#FABD2F",
        brightBlue: "#83A598", brightMagenta: "#D3869B", brightCyan: "#8EC07C", brightWhite: "#EBDBB2"
    )

    static let tokyoNight = TerminalColorScheme(
        name: "Tokyo Night",
        background: "#1A1B26", foreground: "#A9B1D6", cursor: "#C0CAF5", selection: "#33467C",
        black: "#15161E", red: "#F7768E", green: "#9ECE6A", yellow: "#E0AF68",
        blue: "#7AA2F7", magenta: "#BB9AF7", cyan: "#7DCFFF", white: "#A9B1D6",
        brightBlack: "#414868", brightRed: "#F7768E", brightGreen: "#9ECE6A", brightYellow: "#E0AF68",
        brightBlue: "#7AA2F7", brightMagenta: "#BB9AF7", brightCyan: "#7DCFFF", brightWhite: "#C0CAF5"
    )

    /// All available preset color schemes
    static let allPresets: [TerminalColorScheme] = [
        .default, .solarizedDark, .solarizedLight, .dracula, .nord, .monokai, .gruvboxDark, .tokyoNight
    ]

    // MARK: - Color Cache (Performance Optimization)

    /// Thread-safe cache for parsed NSColor values to avoid repeated hex parsing
    private static var colorCache: [String: NSColor] = [:]
    private static let colorCacheLock = NSLock()

    /// Converts a hex color string to NSColor, using caching for performance.
    /// - Parameter hex: Hex color string (e.g., "#FF0000" or "FF0000")
    /// - Returns: NSColor representation
    func nsColor(for hex: String) -> NSColor {
        // Check cache first (thread-safe)
        Self.colorCacheLock.lock()
        if let cached = Self.colorCache[hex] {
            Self.colorCacheLock.unlock()
            return cached
        }
        Self.colorCacheLock.unlock()

        // Parse hex string
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        let color = NSColor(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )

        // Cache the result (thread-safe)
        Self.colorCacheLock.lock()
        Self.colorCache[hex] = color
        Self.colorCacheLock.unlock()

        return color
    }

    /// Clears the color cache (call when color scheme changes significantly)
    static func clearColorCache() {
        colorCacheLock.lock()
        colorCache.removeAll()
        colorCacheLock.unlock()
    }

    /// A unique signature for this color scheme based on all colors
    var signature: String {
        [
            name, background, foreground, cursor, selection,
            black, red, green, yellow, blue, magenta, cyan, white,
            brightBlack, brightRed, brightGreen, brightYellow, brightBlue,
            brightMagenta, brightCyan, brightWhite
        ].joined(separator: "|")
    }
}

// MARK: - Convenience Accessors

extension TerminalColorScheme {
    /// Returns the background color as NSColor
    var backgroundNSColor: NSColor {
        nsColor(for: background)
    }

    /// Returns the foreground color as NSColor
    var foregroundNSColor: NSColor {
        nsColor(for: foreground)
    }

    /// Returns the cursor color as NSColor
    var cursorNSColor: NSColor {
        nsColor(for: cursor)
    }

    /// Returns the selection color as NSColor
    var selectionNSColor: NSColor {
        nsColor(for: selection)
    }
}
