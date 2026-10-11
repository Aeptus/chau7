# Localization

Swift: `apps/chau7-macos/Sources/Chau7/Localization/` (1 file, 366 lines), strings in `Sources/Chau7/Resources/<lang>.lproj/Localizable.strings`
Swift tests: `Localization/LocalizationTests`
Wave: 5 (see README.md)
Depends on: none

Lets the user pick the interface language. Every UI string in the Swift app goes
through `L(key, englishDefault)`, which looks the key up in the selected
language's `Localizable.strings` and falls back to the English default written in
the code.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| L10-001 | Interface in English, French, Arabic or Hebrew, or System Default (follows the macOS preferred language) | `Localization/Localization.swift` (`AppLanguage`, `LocalizationManager`), `Resources/*.lproj` | `LocalizationTests` | crates/chau7_next_core/src/l10n/mod.rs | done | Bundle localizations |
| L10-002 | App Language picker in Settings > General, saved as `app.language` (note: "Some changes may require restarting the app") | `Settings/Views/GeneralSettingsView.swift`, `Settings/FeatureSettings.swift` (`appLanguage`) |  | crates/chau7_next/src/settings_window/general.rs | done |  |
| L10-003 | Changing the language refreshes the settings window at once; menus and other views pick it up after a restart | `Localization/Localization.swift` (`refreshToken`, `LocalizedViewModifier`, `languageDidChange`) |  | crates/chau7_next/src/l10n.rs | done |  |
| L10-004 | Right-to-left layout for Arabic and Hebrew (applied to the settings window and other views using `.localized()`) | `Localization/Localization.swift` (`isRTL`, `layoutDirection`) |  | crates/chau7_next/src/l10n.rs | done |  |
| L10-005 | Strings missing from a language fall back to the English default from the code | `Localization/Localization.swift` (`localizedString`) |  | crates/chau7_next_core/src/l10n/mod.rs | done |  |
| L10-006 | Dates, numbers, percentages and file sizes formatted for the chosen language | `Localization/Localization.swift` (`LocalizedFormatters`) |  | crates/chau7_next_core/src/l10n/formatters.rs | done |  |

## Notes

- String counts (`Localizable.strings`): English 1219 keys; French, Arabic and
  Hebrew 1216 each. The three keys missing from fr, ar and he are
  `settings.about.licenseSummary`, `settings.about.openAcknowledgments`,
  `settings.about.stackSummary` (so `testLocalizationKeyParity` should currently
  fail). The code references about 1805 distinct keys through `L("...")`, so
  roughly 590 strings exist only as English defaults in the code.
- Not everything is localized: the welcome screen, the quit and URL scheme
  alerts, and several status bar labels are hard coded in English.
- L10-006: only `LocalizedFormatters.fileSize` has a caller (Debug console);
  the rest are unused helpers.
- L10-004: RTL is applied through `.localized()`, used by
  `SettingsRootView`, `ProfileSelectorBar`, `GeneralSettingsView` and
  `ProfilesBackupSettingsView`; other windows stay left to right.
- Chau7 Next is English only and hard codes its strings. A port could reuse the
  `.strings` files (simple `"key" = "value";` pairs) through a small loader in
  `chau7_next_core`, keeping the same keys so translations are shared.
- Resource lookup (`Chau7Resources.bundle`, see `Utilities.md` UTL-013) finds
  `en.lproj` both in `Chau7.app` and in the SwiftPM build folder.
