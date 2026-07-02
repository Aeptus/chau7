import AppKit
import Chau7Core
import Foundation

/// Owns the terminal appearance domain: font family/weight/size, custom
/// fonts, default zoom, and color schemes — loading, clamping, persistence,
/// and the appearance change signals.
///
/// Extracted from `FeatureSettings` (which forwards for source
/// compatibility) following the same store-behind-facade pattern as
/// `NotificationSettingsStore`.
@Observable
final class TerminalAppearanceStore {

    enum Keys {
        static let fontFamily = "terminal.fontFamily"
        static let fontWeight = "terminal.fontWeight"
        static let fontSize = "terminal.fontSize"
        static let customFontFamily = "terminal.customFontFamily"
        static let defaultZoomPercent = "terminal.defaultZoomPercent"
        static let colorSchemeName = "terminal.colorSchemeName"
        static let customColorScheme = "terminal.customColorScheme"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var fontFamily: String {
        didSet {
            defaults.set(fontFamily, forKey: Keys.fontFamily)
            // Don't post .terminalFontChanged here — that notification triggers
            // applyDefaultFontSize() which resets per-tab zoom. Font family changes
            // are picked up by SwiftUI's @Observable property tracking directly.
        }
    }

    /// NSFont weight value (0=ultralight, 5=regular, 9=bold, 14=ultra-heavy).
    /// Maps to NSFontManager weight parameter.
    var fontWeight: Int {
        didSet {
            let clamped = max(0, min(fontWeight, 14))
            if fontWeight != clamped { fontWeight = clamped
                return
            }
            defaults.set(fontWeight, forKey: Keys.fontWeight)
        }
    }

    var fontSize: Int {
        didSet {
            let clamped = max(8, min(fontSize, 72))
            if fontSize != clamped {
                fontSize = clamped
                return
            }
            defaults.set(fontSize, forKey: Keys.fontSize)
            NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
        }
    }

    var customFontFamily: String {
        didSet {
            defaults.set(customFontFamily, forKey: Keys.customFontFamily)
        }
    }

    var defaultZoomPercent: Int {
        didSet {
            let clamped = max(50, min(defaultZoomPercent, 200))
            if defaultZoomPercent != clamped {
                defaultZoomPercent = clamped
                return
            }
            defaults.set(defaultZoomPercent, forKey: Keys.defaultZoomPercent)
            NotificationCenter.default.post(name: .terminalZoomChanged, object: nil)
        }
    }

    var colorSchemeName: String {
        didSet {
            defaults.set(colorSchemeName, forKey: Keys.colorSchemeName)
            NotificationCenter.default.post(name: .terminalColorsChanged, object: nil)
        }
    }

    var customColorScheme: TerminalColorScheme? {
        didSet {
            if let scheme = customColorScheme,
               let data = JSONOperations.encode(scheme, context: "customColorScheme") {
                defaults.set(data, forKey: Keys.customColorScheme)
            } else {
                defaults.removeObject(forKey: Keys.customColorScheme)
            }
            NotificationCenter.default.post(name: .terminalColorsChanged, object: nil)
        }
    }

    var currentColorScheme: TerminalColorScheme {
        if colorSchemeName == "Custom", let custom = customColorScheme {
            return custom
        }
        return TerminalColorScheme.allPresets.first { $0.name == colorSchemeName } ?? .default
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fontFamily = defaults.string(forKey: Keys.fontFamily) ?? "SF Mono"
        self.fontWeight = defaults.object(forKey: Keys.fontWeight) as? Int ?? 5
        self.fontSize = defaults.object(forKey: Keys.fontSize) as? Int ?? 11
        self.customFontFamily = defaults.string(forKey: Keys.customFontFamily) ?? ""
        self.defaultZoomPercent = defaults.object(forKey: Keys.defaultZoomPercent) as? Int ?? 100
        self.colorSchemeName = defaults.string(forKey: Keys.colorSchemeName) ?? "Default"
        if let data = defaults.data(forKey: Keys.customColorScheme),
           let scheme = JSONOperations.decode(TerminalColorScheme.self, from: data, context: "customColorScheme") {
            self.customColorScheme = scheme
        } else {
            self.customColorScheme = nil
        }
    }

    // MARK: - Font catalog

    /// Available monospace fonts for the terminal, filtered by system availability.
    /// Computed property so the custom font (if valid) appears at the top.
    var availableFonts: [String] {
        var fonts = Self.builtinAvailableFonts
        let custom = customFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, !fonts.contains(custom),
           NSFontManager.shared.font(withFamily: custom, traits: [], weight: 5, size: 12) != nil {
            fonts.insert(custom, at: 0)
        }
        return fonts
    }

    /// Built-in monospace font list, filtered by system availability (computed once).
    private static let builtinAvailableFonts: [String] = {
        let monospacedFonts = [
            // macOS System Fonts
            "Menlo",
            "Monaco",
            "SF Mono",
            "Courier New",

            // Microsoft Fonts
            "Cascadia Code", // Modern Windows Terminal font with ligatures
            "Cascadia Mono", // Cascadia without ligatures
            "Consolas",

            // JetBrains
            "JetBrains Mono", // Popular IDE font with ligatures

            // Adobe/Google Fonts
            "Source Code Pro",
            "Roboto Mono",

            // Mozilla
            "Fira Code", // Popular font with ligatures
            "Fira Mono", // Fira without ligatures

            // IBM
            "IBM Plex Mono",

            // GitHub
            "Monaspace Neon", // GitHub's new font family
            "Monaspace Argon",
            "Monaspace Xenon",
            "Monaspace Radon",
            "Monaspace Krypton",

            // Vercel
            "Geist Mono", // Modern, clean terminal font

            // Other Popular Open Source
            "Hack", // Designed for source code
            "Inconsolata", // Humanist monospace
            "Anonymous Pro",
            "Ubuntu Mono",
            "Droid Sans Mono",
            "DejaVu Sans Mono",
            "Liberation Mono",
            "PT Mono",
            "Oxygen Mono",
            "Space Mono", // Google Fonts - quirky
            "Overpass Mono",
            "Share Tech Mono",
            "Cousine",
            "Cutive Mono",

            // Iosevka Family (highly customizable)
            "Iosevka",
            "Iosevka Term",
            "Iosevka Fixed",

            // Victor Mono (cursive italics)
            "Victor Mono",

            // Fantasque Sans Mono (playful)
            "Fantasque Sans Mono",

            // Input (customizable)
            "Input Mono",
            "Input Mono Narrow",
            "Input Mono Condensed",

            // Recursive (variable font)
            "Recursive Mono Linear",
            "Rec Mono Linear",

            // Comic/Fun
            "Comic Mono", // Comic Sans but monospace

            // Maple Mono
            "Maple Mono",
            "Maple Mono NF", // Nerd Font version

            // Commit Mono
            "Commit Mono",

            // Nerd Font variants (include powerline symbols)
            "MesloLGS NF", // Popular for Oh My Zsh
            "MesloLGM NF",
            "MesloLGL NF",
            "Hack Nerd Font",
            "FiraCode Nerd Font",
            "JetBrainsMono Nerd Font",
            "CaskaydiaCove Nerd Font",
            "Iosevka Nerd Font",
            "UbuntuMono Nerd Font",
            "RobotoMono Nerd Font",
            "SourceCodePro Nerd Font",
            "Symbols Nerd Font",

            // Premium/Commercial fonts (user must install)
            "Operator Mono", // Hoefler&Co - cursive italics
            "Dank Mono", // Stylish with ligatures
            "MonoLisa", // Designed for long coding sessions
            "Berkeley Mono", // Retro feel
            "Gintronic", // Modern geometric
            "Pragmata Pro", // Compact and dense
            "Cartograph CF", // Warm, readable
            "Codelia", // Playful
            "Comic Code", // Professional Comic Sans
            "Ellograph CF", // Elegant
            "Lilex", // Modern and clean

            // Coding-specific fonts
            "Sudo",
            "Agave",
            "Cozette", // Bitmap-style
            "Terminus", // Classic bitmap
            "Tamzen",
            "Tamsyn",
            "GoMono", // Go language official font
            "Noto Sans Mono", // Google's universal font
            "Intel One Mono" // Intel's open source font
        ]
        let fontManager = NSFontManager.shared
        // SF Mono is system-restricted: NSFontManager returns nil for it, but
        // it's always available via NSFont.monospacedSystemFont(). Keep it unconditionally.
        return monospacedFonts.filter {
            $0 == "SF Mono" || fontManager.font(withFamily: $0, traits: [], weight: 5, size: 12) != nil
        }
    }()
}
