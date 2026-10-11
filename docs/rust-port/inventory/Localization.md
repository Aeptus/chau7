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
| L10-001 | Interface in English, French, Arabic, Hebrew or Spanish, or System Default | `Localization/Localization.swift`; `Resources/*.lproj` | `LocalizationTests` | crates/chau7_next_core/src/l10n/mod.rs | done | Bundle localizations |
| L10-002 | App Language picker in Settings > General, saved as `app.language` (note: "Some changes may require restarting the app") | `Settings/Views/GeneralSettingsView.swift`, `Settings/FeatureSettings.swift` (`appLanguage`) |  | crates/chau7_next/src/settings_window/general.rs | done |  |
| L10-003 | Changing the language refreshes the settings window at once; menus and other views pick it up after a restart | `Localization/Localization.swift` (`refreshToken`, `LocalizedViewModifier`, `languageDidChange`) |  | crates/chau7_next/src/l10n.rs | done |  |
| L10-004 | Right-to-left layout for Arabic and Hebrew (applied to the settings window and other views using `.localized()`) | `Localization/Localization.swift` (`isRTL`, `layoutDirection`) |  | crates/chau7_next/src/l10n.rs | done |  |
| L10-005 | Strings missing from a language fall back to the English default from the code | `Localization/Localization.swift` (`localizedString`) |  | crates/chau7_next_core/src/l10n/mod.rs | done |  |
| L10-006 | Dates and file sizes follow interface language; integer/decimal/percent/currency follow independent Regional Number Format (L10-009) | `Localization/Localization.swift` (`LocalizedFormatters`) |  | chau7_next_core/src/l10n/formatters.rs; chau7_next_core/src/l10n/numbers.rs | done |  |

| L10-007 | Spanish is selectable and follows System Default language matching with English fallback | `Localization/Localization.swift`; `Resources/es.lproj/Localizable.strings` | LocalizationTests | chau7_next_core/src/l10n/mod.rs; chau7_next_core/src/l10n/strings/es.strings; chau7_next/src/settings_window/general.rs | done |  |
| L10-008 | Plural rules in all language stringsdict tables format counts with locale-specific singular/plural rather than raw English substitutions | `Localization/Localization.swift`; `Resources/*.lproj/Localizable.stringsdict` | LocalizationTests | chau7_next_core/src/l10n/plural.rs; chau7_next_core/src/app_shell.rs; chau7_next_core/src/command_center.rs; chau7_next/src/app_actions.rs; chau7_next/src/status_bar/mod.rs; chau7_next/src/workspace/menus.rs | done |  |

| L10-009 | Regional Number Format independent from interface language affects integer/decimal/percent/currency, persists and invalidates cached formatters | `Localization/Localization.swift`; `Utilities/RegionalNumberFormat.swift`; `Settings/TerminalBehaviorStore.swift` |  | chau7_next_core/src/l10n/numbers.rs; chau7_next/src/settings/general.rs; chau7_next/src/settings_window/ai.rs; chau7_next/src/main.rs | done |  |

## Notes
- Current Swift Localizable.strings contains 2,748 keys in each of English, French, Spanish, Arabic and Hebrew. Next bundles all five tables and preserves every Swift key/value, checked per key with concise failure messages. Nineteen declared source-default supplemental keys cover current Settings/FDA status text absent from Swift tables; an explicit evidence whitelist rejects any unknown extras. The app source-key scan rejects missing Next English keys.
- L10-008 is implemented: all 41 current stringsdict entries across five languages use the plural backend. Actual quit alerts, group-close menu and status panel/fallback menu now route counted labels through it. Focused tests cover five locales, complete counts before attention card truncation, duplicate process names and literal format-like text. Full native language acceptance remains on the hand-test checklist.
- L10-009 is implemented: French/European/US regional choice is independent from app language, defaults to French, persists and applies at startup and live updates. Helpers include currency two-decimal and precise small-cost formatting. Tests compare actual Foundation examples. Next uses fresh policy-based formatting, without Swift's formatter cache architecture.
- RTL follows the selected Arabic/Hebrew UI language. Native screen/layout acceptance remains separate.
- Evidence: l10n::tests::{tables_match_the_swift_resources,next_status_defaults_have_current_swift_source_evidence}; app source-key coverage; l10n::numbers::tests::{raw_values_defaults_and_locales_match_swift,foundation_number_and_currency_examples}. The settings/resource checkpoint passes all 20 focused localization tests.
