//! Localization glue (`Localization.swift`): applies the `app.language`
//! setting, translates UI strings and mirrors layouts for right-to-left
//! languages. The tables, lookup and formatters are in
//! `chau7_next_core::l10n`; every key used here is a key of the Swift
//! `Localizable.strings` (a test checks it).

use chau7_next_core::l10n::{self, Arg, Lang};
use gpui::{App, Div, Styled};

use crate::settings::{AppLanguage, Settings};

/// `L(key, default)`.
pub fn l(key: &str, default: &str) -> String {
    l10n::l(key, default)
}

/// `L(key, default, args...)`.
pub fn lf(key: &str, default: &str, args: &[Arg]) -> String {
    l10n::lf(key, default, args)
}

/// Translate a literal English UI string (see `l10n::translate`).
pub fn tr(text: &str) -> String {
    l10n::tr(text)
}

/// [`tr`], then the macOS wording adapted to this platform (modifier names,
/// "Reveal in Finder", "Mac"; see `shortcut_display::platform_text`).
pub fn ui(text: &str) -> String {
    platform(&tr(text))
}

/// Text written for macOS (shortcut symbols, Cmd+click) in this platform's
/// wording; unchanged on macOS.
pub fn platform(text: &str) -> String {
    chau7_next_core::shortcut_display::platform_text(text, std::env::consts::OS)
}

/// Whether the interface is right to left now.
pub fn is_rtl() -> bool {
    l10n::is_rtl()
}

/// The language for the `app.language` setting.
pub fn language_for(setting: AppLanguage) -> Lang {
    l10n::resolve(
        setting.id(),
        &crate::platform::system::preferred_languages(),
    )
}

/// Switch the interface to the `app.language` setting. Returns whether the
/// language changed.
pub fn apply_setting(setting: AppLanguage) -> bool {
    let lang = language_for(setting);
    let changed = l10n::current() != lang;
    l10n::set_current(lang);
    changed
}

/// Called whenever settings are applied: follows `app.language`; a change
/// rebuilds the menu bar (the Swift app needs a restart for it).
pub fn settings_applied(cx: &mut App) {
    let setting = Settings::get(cx).general.app_language;
    if apply_setting(setting) {
        let titles = cx
            .try_global::<crate::workspace::AppData>()
            .map(|d| d.menu_titles.clone())
            .unwrap_or_default();
        cx.set_menus(crate::actions::app_menus(&titles));
    }
}

/// A row that mirrors for right-to-left languages (children in reverse
/// order, `layoutDirection`). Only call on a `flex()` row container.
pub fn row_direction(div: Div) -> Div {
    if is_rtl() {
        div.flex_row_reverse()
    } else {
        div
    }
}

/// `window.prompt` (NSAlert) with the message, detail and button titles
/// translated. Answer indices are those of the English button order.
pub fn prompt(
    window: &mut gpui::Window,
    level: gpui::PromptLevel,
    message: &str,
    detail: Option<&str>,
    answers: &[&str],
    cx: &mut App,
) -> futures::channel::oneshot::Receiver<usize> {
    let message = tr(message);
    let detail = detail.map(tr);
    let answers: Vec<String> = answers.iter().map(|a| tr(a)).collect();
    let refs: Vec<&str> = answers.iter().map(String::as_str).collect();
    window.prompt(level, &message, detail.as_deref(), &refs, cx)
}

/// The display name of an app language; "System Default" is localized,
/// the others are written in their own language.
pub fn language_name(language: AppLanguage) -> String {
    match language {
        AppLanguage::System => l("language.system", "System Default"),
        other => other.display_name().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    /// Every key passed to `l10n::l`, `l10n::lf` or `l(` / `lf(` with a
    /// literal in the sources exists in the English table.
    #[test]
    fn every_key_used_in_rust_exists_in_the_english_table() {
        let re = regex::Regex::new(r#"\b(?:l10n::)?(?:l|lf)\(\s*"([A-Za-z][A-Za-z0-9_.]*)"\s*,"#)
            .unwrap();
        let en = l10n::table(Lang::En);
        let mut seen = 0;
        let mut stack = vec![Path::new(env!("CARGO_MANIFEST_DIR")).join("src")];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    let text = std::fs::read_to_string(&path).unwrap();
                    for cap in re.captures_iter(&text) {
                        if path.ends_with("l10n.rs") {
                            continue;
                        }
                        seen += 1;
                        assert!(
                            en.contains_key(&cap[1]),
                            "{}: key {:?} is not in the English table",
                            path.display(),
                            &cap[1]
                        );
                    }
                }
            }
        }
        assert!(seen > 0, "no localized lookups found");
    }

    #[test]
    fn language_choice_resolves() {
        assert_eq!(language_for(AppLanguage::French), Lang::Fr);
        assert_eq!(language_for(AppLanguage::Hebrew), Lang::He);
        assert!(language_for(AppLanguage::Arabic).is_rtl());
        // "System Default" always lands on a supported language.
        assert!(Lang::ALL.contains(&language_for(AppLanguage::System)));
    }

    #[test]
    fn system_default_name_is_localized() {
        assert_eq!(
            l10n::localized(Lang::Fr, "language.system", "System Default"),
            l10n::table(Lang::Fr)["language.system"]
        );
    }
}
