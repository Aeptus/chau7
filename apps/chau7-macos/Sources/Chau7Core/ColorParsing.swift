import Foundation

// MARK: - Color Parsing

/// Pure functions for parsing color values.
/// Extracted for testability.
public enum ColorParsing {

    /// RGB color components
    public struct RGB: Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// Creates RGB from 0-255 integer values
        public init(r: Int, g: Int, b: Int) {
            self.red = Double(r) / 255.0
            self.green = Double(g) / 255.0
            self.blue = Double(b) / 255.0
        }
    }

    // MARK: - Hex Parsing

    /// Parses a hex color string to RGB components
    /// - Parameter hex: Hex color string (with or without #)
    /// - Returns: RGB components (0.0-1.0) or nil if invalid
    public static func parseHex(_ hex: String) -> RGB? {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "#", with: "")

        // Validate length
        guard sanitized.count == 6 || sanitized.count == 3 else {
            return nil
        }

        // Expand 3-char hex to 6-char
        if sanitized.count == 3 {
            sanitized = sanitized.map { "\($0)\($0)" }.joined()
        }

        // Validate hex characters
        guard sanitized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        var rgb: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgb)

        return RGB(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }

    /// Converts RGB to hex string
    /// - Parameter rgb: RGB color components
    /// - Returns: Hex color string with # prefix
    public static func toHex(_ rgb: RGB) -> String {
        let r = Int(rgb.red * 255)
        let g = Int(rgb.green * 255)
        let b = Int(rgb.blue * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Validation

    /// Checks if a string is a valid hex color
    public static func isValidHex(_ hex: String) -> Bool {
        parseHex(hex) != nil
    }

    /// Checks if a character is a valid hex digit
    public static func isHexDigit(_ char: Character) -> Bool {
        char.isHexDigit
    }

    // MARK: - Color Manipulation

    /// Adjusts the brightness of a color
    /// - Parameters:
    ///   - rgb: Original RGB color
    ///   - factor: Brightness factor (1.0 = no change, >1 = brighter, <1 = darker)
    /// - Returns: Adjusted RGB color, clamped to valid range
    public static func adjustBrightness(_ rgb: RGB, factor: Double) -> RGB {
        RGB(
            red: min(1.0, max(0.0, rgb.red * factor)),
            green: min(1.0, max(0.0, rgb.green * factor)),
            blue: min(1.0, max(0.0, rgb.blue * factor))
        )
    }

    /// Calculates the luminance of a color (0.0-1.0)
    public static func luminance(_ rgb: RGB) -> Double {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    /// Determines if a color is considered "light"
    public static func isLight(_ rgb: RGB) -> Bool {
        luminance(rgb) > 0.5
    }
}
