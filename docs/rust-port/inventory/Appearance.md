# Appearance

Swift: `apps/chau7-macos/Sources/Chau7/Appearance/` (4 files, 306 lines)
Swift tests: `Appearance/MinimalModeTests`, `Terminal/ColorParsingTests` (hex parsing shared with color schemes)
Wave: 1
Depends on: Settings (the values live in `FeatureSettings`)

Color schemes for terminal content, the app's light or dark theme, the eight
tab colors, and minimal mode. The settings that change how the window looks
(font, cursor, opacity, blur) live in `Settings/FeatureSettings.swift` and the
window code, and are listed here so that all appearance parity is in one place.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| APR-001 | Eight color scheme presets in this order: Default, Solarized Dark, Solarized Light, Dracula, Nord, Monokai, Gruvbox Dark, Tokyo Night (background, foreground, cursor, selection, 16 ANSI colors) | `Appearance/TerminalColorScheme.swift` | `ColorParsingTests` | `chau7_next_core/src/color_schemes.rs` | done | |
| APR-002 | Custom color scheme: scheme name "Custom" uses a user-edited scheme saved as JSON | `Appearance/TerminalColorScheme.swift`, `Settings/FeatureSettings.swift` (`customColorScheme`, `currentColorScheme`) |  | `chau7_next_core/src/color_schemes.rs` (`resolve`, `from_json`), `chau7_next/src/settings/appearance.rs` | done |  |
| APR-003 | The chosen scheme applies live to every terminal: foreground, background, cursor and palette to the emulator, selection color to the renderer | `Appearance/TerminalColorScheme.swift`, `RustBackend/RustTerminalView.swift` (`applyColorScheme`) | | `chau7_next/src/terminal/session.rs` (`apply_colors`), `chau7_next/src/terminal/view.rs` (selection and cursor colors) | done | |
| APR-004 | App theme System / Light / Dark sets the appearance of every window (terminal windows, settings, splash, debug console) | `Appearance/AppTheme.swift`, `App/AppDelegate.swift` (`applyAppTheme`) |  | `chau7_next/src/platform/window_style.rs` (`set_app_theme`), `chau7_next/src/theme.rs` (`app_is_dark`, `Chrome::panels`), `chau7_next/src/main.rs` (`apply_theme`) | done | NSAppearance |
| APR-005 | Eight tab colors (blue, teal, green, yellow, orange, pink, purple, gray) with fixed RGB values, used by the tab tint, rename color picker and restore | `Appearance/TabColor.swift` | | `chau7_next_core/src/tabs_state.rs` (`TabColor`), `chau7_next/src/theme.rs` (`tab_color`) | done | |
| APR-006 | Automatic tab color by detected AI tool (registry colors and custom detection rule colors) from the command line that starts, when "auto tab theme" is on | `Appearance/TabColor.swift`, `Settings/FeatureSettings.swift` (`isAutoTabThemeEnabled`, `aiModelColors`) |  | chau7_next_core/src/tabs_state.rs (auto_color_for_command, effective_color), chau7_next/src/workspace/mod.rs (CommandStarted, auto color), chau7_next/src/workspace/tab_bar_view.rs (effective_color), chau7_next/src/settings/ai.rs (color_rules) | done |  |
| APR-007 | Terminal font family (installed monospaced fonts; "SF Mono" uses the system monospaced font) and size 8 to 72 pt, applied live | `Settings/FeatureSettings.swift` (`fontFamily`, `fontSize`), `RustBackend/RustFFITypes.swift` (`TerminalFont.resolveFont`) | | `chau7_next/src/settings/` (`font_family`, `font_size` 6 to 72, `fallback_fonts`) | done | |
| APR-008 | Minimal mode: toggle plus four options (hide tab bar when there is one tab, title bar, status bar, sidebar), saved across launches, with a settings page | `Appearance/MinimalMode.swift`, `Settings/Views/MinimalModeSettingsView.swift` | `MinimalModeTests` | `chau7_next/src/settings/minimal_mode.rs`, `chau7_next/src/settings_window/minimal_mode.rs`, `chau7_next/src/workspace/tab_bar_view.rs` (`tab_bar_visible`, `title_bar_visible`) | done |  |
| APR-009 | High contrast: colors switch when macOS "Increase contrast" is on | `Utilities/AccessibilityUtilities.swift` (`HighContrastModifier`) |  | `chau7_next/src/theme.rs` (`high_contrast`), `chau7_next/src/platform/system.rs` | done | NSWorkspace accessibilityDisplayShouldIncreaseContrast |
| APR-010 | Window opacity 30 % to 100 %: the whole terminal window (text, tab bar and background) fades | `Settings/FeatureSettings.swift` (`windowOpacity`), `App/AppDelegate.swift` (`applyWindowOpacity`) |  | `chau7_next/src/platform/window_style.rs` (`set_window_alpha`), `chau7_next/src/workspace/window.rs` (`apply_window_style`), `chau7_next/src/theme.rs` (`content_opacity`) | done | NSWindow alphaValue |
| APR-011 | Background blur: terminal windows sit on a behind-window HUD vibrancy view at all times; the toolbar uses a within-window HUD material. Chau7 Next: GPUI's blurred window background, always on macOS; the tab bar and title bar are a translucent dark HUD tint over that blur with a fixed HUD palette (light text) whatever the color scheme, like Swift (`Chrome::tab_bar`). On Linux and Windows, where gpui-component draws the window buttons in the app theme's colors, the HUD is used only when the app is dark, else the scheme's chrome | `App/AppDelegate.swift` (`OverlayBlurView`), `Overlay/Chau7OverlayView.swift` (`ToolbarBackgroundView`) |  | chau7_next/src/workspace/window.rs (background_appearance), chau7_next/src/theme.rs (Chrome::tab_bar), chau7_next/src/workspace/mod.rs | done | NSVisualEffectView |
| APR-012 | Cursor style block / underline / bar and blinking on or off, applied live | `Settings/FeatureSettings.swift` (`cursorStyle`, `cursorBlink`), `RustBackend/RustTerminalView.swift` (`applyCursorStyle`) | | `chau7_next/src/settings/` (`cursor_shape`, `cursor_blink`), `chau7_next/src/terminal/view.rs` (530 ms blink) | done | |
| APR-013 | "Default zoom" percent (50 to 200) scales the font size for new tabs and for Actual Size | `Settings/FeatureSettings.swift` (`defaultZoomPercent`), `Terminal/Session/TerminalSessionModel.swift` (`applyDefaultFontSize`) |  | `chau7_next/src/settings/appearance.rs` (`zoomed_font_size`), `chau7_next/src/workspace/font.rs`, `chau7_next/src/terminal/view.rs` | done |  |
| APR-014 | Font weight, custom font family and ligatures settings | `Settings/FeatureSettings.swift` (`fontWeight`, `customFontFamily`, `enableLigatures`) |  | `chau7_next/src/terminal/paint.rs` (`terminal_font`, `ns_font_weight`), `chau7_next/src/settings_window/text.rs` | done |  |
| APR-015 | Cursor color override and cursor blink rate settings | `Settings/FeatureSettings.swift` (`cursorColor`, `cursorBlinkRate`) |  | `chau7_next/src/terminal/paint.rs` (`cursor_color`), `chau7_next/src/settings/appearance.rs` (`blink_interval`) | done |  |
| APR-016 | Floating window (stays above other apps) | `Settings/FeatureSettings.swift` (`windowFloating`) |  | `chau7_next/src/platform/window_style.rs` (`set_window_floating`), `chau7_next/src/workspace/window.rs` | done | NSWindow level |

## Notes

- **Settings keys** (UserDefaults): `feature.minimalMode`,
  `minimal.hideTabBar`, `minimal.hideTitleBar`, `minimal.hideStatusBar`,
  `minimal.hideSidebar` (the four default to true), `window.floating`,
  `terminal.fontWeight`, `terminal.enableLigatures`; others through
  `FeatureSettings.Keys` (`colorSchemeName`, `customColorScheme`,
  `windowOpacity`, `appTheme`, `fontFamily`, `fontSize`, `defaultZoomPercent`).
  config.toml carries `[appearance] font_family, font_size, color_scheme,
  cursor_style, cursor_blink, opacity`, which Chau7 Next reads and writes.
- **Notifications posted** (other modules react): `terminalColorsChanged`,
  `terminalFontChanged`, `terminalZoomChanged`, `terminalOpacityChanged`,
  `appThemeChanged`, `minimalModeChanged`.
- **Dormant Swift features.** Several rows describe settings that Swift stores
  but does not apply yet. Port them only together with the behavior:
  - Minimal mode (APR-008): nothing observes `minimalModeChanged` and no key
    binds the advertised Cmd+Shift+M, so the toggle changes nothing on screen.
  - High contrast (APR-009): `HighContrastModifier` and `.highContrast(...)`
    exist but no view uses them; there is no high-contrast setting.
  - Font weight, custom font family, ligatures (APR-014): `resolveFont` always
    asks for weight 5 and ignores the other two.
  - Cursor color and blink rate (APR-015): stored only; the renderer uses the
    scheme's cursor color.
- **Padding.** Swift has no padding setting (fixed insets in the renderer).
  Chau7 Next adds `[next] padding` (0 to 40 px, default 4) in its settings
  window; nothing to port.
- **Opacity.** Swift sets `NSWindow.alphaValue`, so text fades with the
  background. Chau7 Next does the same on macOS (`platform::window_style`);
  on Linux and Windows only the terminal background is see-through.
- **Chrome colors.** Chau7 Next derives tab bar and panel colors from the
  scheme background (`theme.rs` `Chrome`). Swift uses fixed dark overlay colors
  (`Chau7OverlayView.swift` `overlayPanelBackground` etc.) plus the system
  appearance from APR-004.
