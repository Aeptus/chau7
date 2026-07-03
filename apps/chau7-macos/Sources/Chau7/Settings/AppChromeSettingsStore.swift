import Foundation

/// Owns the app-level chrome domain: app theme, app language, menu-bar-only
/// mode, window floating/opacity, launch at login, and font ligatures.
///
/// Extracted from `FeatureSettings` (which forwards) following the
/// store-behind-facade pattern of the other settings domains.
@Observable
final class AppChromeSettingsStore {

    enum Keys {
        static let appTheme = "app.theme"
        static let appLanguage = "app.language"
        static let launchAtLogin = "app.launchAtLogin"
        static let menuBarOnlyMode = "window.menuBarOnlyMode"
        static let windowFloating = "window.floating"
        static let windowOpacity = "window.opacity"
        static let enableLigatures = "terminal.enableLigatures"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - App Theme

    var appTheme: AppTheme {
        didSet {
            defaults.set(appTheme.rawValue, forKey: Keys.appTheme)
            NotificationCenter.default.post(name: .appThemeChanged, object: nil)
        }
    }

    // MARK: - Language Setting

    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            LocalizationManager.shared.currentLanguage = appLanguage
        }
    }

    // MARK: - Launch at Login

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            if oldValue != launchAtLogin {
                LaunchAtLoginManager.setEnabled(launchAtLogin)
            }
        }
    }

    // MARK: - Menu Bar Only Mode

    var menuBarOnlyMode: Bool {
        didSet { defaults.set(menuBarOnlyMode, forKey: Keys.menuBarOnlyMode) }
    }

    /// When true, the terminal window floats above other apps (.floating level).
    var windowFloating: Bool {
        didSet {
            defaults.set(windowFloating, forKey: Keys.windowFloating)
            NotificationCenter.default.post(name: .windowFloatingChanged, object: nil)
        }
    }

    // MARK: - Window Transparency

    var windowOpacity: Double {
        didSet {
            let clamped = max(0.3, min(windowOpacity, 1.0))
            if windowOpacity != clamped {
                windowOpacity = clamped
                return
            }
            defaults.set(windowOpacity, forKey: Keys.windowOpacity)
            NotificationCenter.default.post(name: .terminalOpacityChanged, object: nil)
        }
    }

    // MARK: - Font Ligatures

    /// Enable font ligature rendering (e.g., =>, ->, === in Fira Code, JetBrains Mono).
    var enableLigatures: Bool {
        didSet { defaults.set(enableLigatures, forKey: Keys.enableLigatures) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Menu Bar Only Mode
        self.menuBarOnlyMode = defaults.bool(forKey: Keys.menuBarOnlyMode)
        self.windowFloating = defaults.bool(forKey: Keys.windowFloating)

        // Window Opacity
        self.windowOpacity = defaults.object(forKey: Keys.windowOpacity) as? Double ?? 1.0

        // App Theme
        if let themeRaw = defaults.string(forKey: Keys.appTheme),
           let theme = AppTheme(rawValue: themeRaw) {
            self.appTheme = theme
        } else {
            self.appTheme = .system
        }

        // Language
        if let langRaw = defaults.string(forKey: Keys.appLanguage),
           let lang = AppLanguage(rawValue: langRaw) {
            self.appLanguage = lang
        } else {
            self.appLanguage = .system
        }

        // Launch at Login
        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        } else {
            self.launchAtLogin = LaunchAtLoginManager.isEnabled()
        }

        self.enableLigatures = defaults.bool(forKey: Keys.enableLigatures)
    }

    /// Reset by deriving from the loader (single source of defaults). Note the
    /// launch-at-login fallback is dynamic (mirrors the installed login item),
    /// so `FeatureSettings.resetAllToDefaults()` additionally forces it off.
    func resetToDefaults() {
        for key in [
            Keys.appTheme, Keys.appLanguage, Keys.launchAtLogin,
            Keys.menuBarOnlyMode, Keys.windowFloating, Keys.windowOpacity,
            Keys.enableLigatures
        ] {
            defaults.removeObject(forKey: key)
        }
        let fresh = AppChromeSettingsStore(defaults: defaults)
        appTheme = fresh.appTheme
        appLanguage = fresh.appLanguage
        launchAtLogin = fresh.launchAtLogin
        menuBarOnlyMode = fresh.menuBarOnlyMode
        windowFloating = fresh.windowFloating
        windowOpacity = fresh.windowOpacity
        enableLigatures = fresh.enableLigatures
    }
}
