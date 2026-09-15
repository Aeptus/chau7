import AppKit
import Chau7Core
import Foundation

// MARK: - Terminal Color Scheme (AppKit color conversion)

/// macOS-only `NSColor` conversion + caching for `TerminalColorScheme`.
///
/// The pure-data `TerminalColorScheme` struct (hex fields, presets, signature,
/// FFI byte helpers) lives in `Chau7Core` so it can be shared with the iOS
/// remote app. This extension adds the AppKit-coupled bits used only on macOS.
extension TerminalColorScheme {

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
