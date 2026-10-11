//! Localization (`Localization/Localization.swift`): the same
//! `Localizable.strings` tables as the Swift app (copied unchanged into
//! `strings/`, a test checks they still match the Swift originals), looked up
//! by the same keys, with the English default from the code as the fallback.
//!
//! - [`Lang`] is a resolved interface language; [`resolve`] maps the
//!   `app.language` setting ("system", "en", "fr", "ar", "he") and the OS
//!   preferred languages to one (L10-001).
//! - [`l`] / [`lf`] are `L(key, default)`; [`tr`] translates a literal English
//!   UI string by finding the key whose English text it is (L10-005).
//! - [`Lang::is_rtl`] drives the right-to-left layout (L10-004).
//! - [`formatters`] formats dates, numbers, percentages and file sizes
//!   (L10-006).

use std::collections::HashMap;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, Ordering};

pub mod format;
pub mod formatters;

pub use format::{Arg, format_printf};

/// An interface language with a translation table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Lang {
    En,
    Fr,
    Ar,
    He,
}

impl Lang {
    pub const ALL: [Lang; 4] = [Lang::En, Lang::Fr, Lang::Ar, Lang::He];

    /// The language code (`en.lproj`, `fr.lproj`, ...).
    pub fn code(self) -> &'static str {
        match self {
            Lang::En => "en",
            Lang::Fr => "fr",
            Lang::Ar => "ar",
            Lang::He => "he",
        }
    }

    /// The language of a locale or language identifier ("fr", "fr-FR",
    /// "ar_EG", "iw"), if the app has a translation for it.
    pub fn from_tag(tag: &str) -> Option<Lang> {
        let primary = tag
            .split(['-', '_', '.', '@'])
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        match primary.as_str() {
            "en" => Some(Lang::En),
            "fr" => Some(Lang::Fr),
            "ar" => Some(Lang::Ar),
            "he" | "iw" => Some(Lang::He),
            _ => None,
        }
    }

    /// Arabic and Hebrew are written right to left (`AppLanguage.isRTL`).
    pub fn is_rtl(self) -> bool {
        matches!(self, Lang::Ar | Lang::He)
    }

    fn index(self) -> u8 {
        match self {
            Lang::En => 0,
            Lang::Fr => 1,
            Lang::Ar => 2,
            Lang::He => 3,
        }
    }

    fn from_index(index: u8) -> Lang {
        match index {
            1 => Lang::Fr,
            2 => Lang::Ar,
            3 => Lang::He,
            _ => Lang::En,
        }
    }
}

/// The first of the OS preferred languages the app is translated into, else
/// English (`Bundle.preferredLocalizations.first ?? "en"`).
pub fn system_language(preferred: &[String]) -> Lang {
    preferred
        .iter()
        .find_map(|tag| Lang::from_tag(tag))
        .unwrap_or(Lang::En)
}

/// The language for the `app.language` setting: "system" (or an unknown
/// value) follows the OS preferred languages.
pub fn resolve(setting: &str, preferred: &[String]) -> Lang {
    match setting {
        "en" | "fr" | "ar" | "he" => Lang::from_tag(setting).unwrap_or(Lang::En),
        _ => system_language(preferred),
    }
}

static CURRENT: AtomicU8 = AtomicU8::new(0);

/// The language the interface is in right now.
pub fn current() -> Lang {
    Lang::from_index(CURRENT.load(Ordering::Relaxed))
}

/// Switch the interface language (`LocalizationManager.currentLanguage`).
pub fn set_current(lang: Lang) {
    CURRENT.store(lang.index(), Ordering::Relaxed);
}

/// Whether the interface is right to left now.
pub fn is_rtl() -> bool {
    current().is_rtl()
}

/// A parsed `Localizable.strings` file.
pub type Table = HashMap<String, String>;

/// Parse the `"key" = "value";` pairs of a `.strings` file. Comments (`//`,
/// `/* */`) are skipped; `\"`, `\\`, `\n`, `\t`, `\r` and `\Uxxxx` unescaped.
pub fn parse_strings(text: &str) -> Table {
    let mut table = Table::new();
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    let mut pending_key: Option<String> = None;
    while i < chars.len() {
        let c = chars[i];
        if c == '/' && chars.get(i + 1) == Some(&'/') {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
        } else if c == '/' && chars.get(i + 1) == Some(&'*') {
            i += 2;
            while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                i += 1;
            }
            i += 2;
        } else if c == '"' {
            i += 1;
            let mut out = String::new();
            while i < chars.len() && chars[i] != '"' {
                if chars[i] == '\\' && i + 1 < chars.len() {
                    i += 1;
                    match chars[i] {
                        'n' => out.push('\n'),
                        't' => out.push('\t'),
                        'r' => out.push('\r'),
                        'U' | 'u' => {
                            let hex: String = chars[i + 1..].iter().take(4).collect();
                            match u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                                Some(ch) => {
                                    out.push(ch);
                                    i += hex.chars().count();
                                }
                                None => out.push(chars[i]),
                            }
                        }
                        other => out.push(other),
                    }
                } else {
                    out.push(chars[i]);
                }
                i += 1;
            }
            i += 1;
            match pending_key.take() {
                None => pending_key = Some(out),
                Some(key) => {
                    table.insert(key, out);
                }
            }
        } else {
            if c == ';' {
                pending_key = None;
            }
            i += 1;
        }
    }
    table
}

const EN: &str = include_str!("strings/en.strings");
const FR: &str = include_str!("strings/fr.strings");
const AR: &str = include_str!("strings/ar.strings");
const HE: &str = include_str!("strings/he.strings");

/// The source text of a language's table (for the sync test with Swift).
pub fn table_source(lang: Lang) -> &'static str {
    match lang {
        Lang::En => EN,
        Lang::Fr => FR,
        Lang::Ar => AR,
        Lang::He => HE,
    }
}

/// The translation table of a language.
pub fn table(lang: Lang) -> &'static Table {
    static TABLES: OnceLock<[Table; 4]> = OnceLock::new();
    let tables = TABLES.get_or_init(|| Lang::ALL.map(|lang| parse_strings(table_source(lang))));
    &tables[lang.index() as usize]
}

/// `L(key, default)` in a given language: the translation, else the English
/// default from the code, else (no default) the English table, else the key.
pub fn localized(lang: Lang, key: &str, default: &str) -> String {
    if let Some(value) = table(lang).get(key) {
        return value.clone();
    }
    if !default.is_empty() {
        return default.to_string();
    }
    table(Lang::En)
        .get(key)
        .cloned()
        .unwrap_or_else(|| key.to_string())
}

/// `L(key, default)` in the current language.
pub fn l(key: &str, default: &str) -> String {
    localized(current(), key, default)
}

/// `L(key, default, args...)`: the localized format string filled with
/// `args` (`%@`, `%d`, `%1$@`, `%.1f`, ...).
pub fn lf(key: &str, default: &str, args: &[Arg]) -> String {
    format_printf(&l(key, default), args)
}

fn normalize(text: &str) -> String {
    text.trim()
        .trim_end_matches(['…', ':'])
        .trim_end_matches("...")
        .trim()
        .to_lowercase()
}

/// English text to the key whose English value it is.
struct Reverse {
    exact: HashMap<&'static str, &'static str>,
    loose: HashMap<String, &'static str>,
}

/// Keys whose English text is generic but whose translation only fits one
/// place ("System Default" is "Langue du système" in French). They are only
/// reached by key (`l`), never by looking up the English text, so a "System
/// Default" shell or browser choice is not called a language.
const KEYED_ONLY: &[&str] = &["language.system"];

fn reverse() -> &'static Reverse {
    static REVERSE: OnceLock<Reverse> = OnceLock::new();
    REVERSE.get_or_init(|| {
        let en = table(Lang::En);
        let fr = table(Lang::Fr);
        let mut keys: Vec<&'static String> = en
            .keys()
            .filter(|k| !KEYED_ONLY.contains(&k.as_str()))
            .collect();
        keys.sort();
        let mut exact: HashMap<&'static str, &'static str> = HashMap::new();
        let mut loose: HashMap<String, &'static str> = HashMap::new();
        for key in keys {
            let value = en[key].as_str();
            // A key whose French text differs from the English text (it was
            // translated) wins over a key that never was.
            let translated = |k: &str| fr.get(k).is_some_and(|f| f.as_str() != en[k].as_str());
            let take = |old: Option<&&'static str>| match old {
                None => true,
                Some(old) => translated(key) && !translated(old),
            };
            if take(exact.get(value)) {
                exact.insert(value, key.as_str());
            }
            let norm = normalize(value);
            if !norm.is_empty() && take(loose.get(&norm)) {
                loose.insert(norm, key.as_str());
            }
        }
        Reverse { exact, loose }
    })
}

/// The key of the English text of a UI string, if the Swift app has one.
pub fn key_for_english(text: &str) -> Option<&'static str> {
    let r = reverse();
    aliases()
        .get(text)
        .copied()
        .or_else(|| r.exact.get(text).copied())
        .or_else(|| r.loose.get(&normalize(text)).copied())
}

/// English texts of Chau7 Next that differ a little from the Swift default
/// of a key (`strings/aliases.tsv`: text, tab, key).
fn aliases() -> &'static HashMap<&'static str, &'static str> {
    static ALIASES: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    ALIASES.get_or_init(|| {
        include_str!("strings/aliases.tsv")
            .lines()
            .filter_map(|line| line.split_once('\t'))
            .collect()
    })
}

/// Translate a literal English UI string into `lang`: finds the Swift key
/// whose English text this is and returns that key's translation; any other
/// text (not localized in Swift, or no translation) stays as written.
pub fn translate(lang: Lang, text: &str) -> String {
    let out = translate_inner(lang, text);
    if text.contains("Chau7 Next") && !out.contains("Chau7 Next") {
        return out.replace("Chau7", "Chau7 Next");
    }
    out
}

fn translate_inner(lang: Lang, text: &str) -> String {
    if lang == Lang::En || text.is_empty() {
        return text.to_string();
    }
    let Some(key) = key_for_english(text) else {
        // Chau7 Next's own name: look the text up as written for Chau7 and
        // put the name back in the translation.
        if text.contains("Chau7 Next") {
            let swift = text.replace("Chau7 Next", "Chau7");
            if key_for_english(&swift).is_some() {
                let out = translate(lang, &swift);
                if out != swift {
                    return out.replace("Chau7", "Chau7 Next");
                }
            }
        }
        return text.to_string();
    };
    let Some(value) = table(lang).get(key) else {
        return text.to_string();
    };
    if table(Lang::En).get(key).map(String::as_str) == Some(text) {
        return value.clone();
    }
    // Matched loosely (case, trailing ellipsis or colon): keep the caller's
    // ending.
    let suffix = ["…", "...", ":"]
        .into_iter()
        .find(|s| text.trim_end().ends_with(s))
        .unwrap_or("");
    let stem = value
        .trim_end()
        .trim_end_matches(['…', ':'])
        .trim_end_matches("...");
    // An all-caps section header ("TERMINAL") stays in capitals.
    let has_letters = text.chars().any(char::is_alphabetic);
    if has_letters && !text.chars().any(char::is_lowercase) {
        return format!("{}{suffix}", stem.to_uppercase());
    }
    format!("{stem}{suffix}")
}

/// [`translate`] into the current language.
pub fn tr(text: &str) -> String {
    translate(current(), text)
}

/// A relative age from seconds ("5 minutes ago"), with the `time.*` keys.
pub fn relative_age(seconds: u64) -> String {
    let n = |key: &str, default: &str, value: u64| lf(key, default, &[Arg::Int(value as i64)]);
    match seconds {
        0..=9 => l("time.just.now", "Just now"),
        10..=59 => n("time.seconds.ago", "%d seconds ago", seconds),
        60..=119 => l("time.minute.ago", "1 minute ago"),
        120..=3599 => n("time.minutes.ago", "%d minutes ago", seconds / 60),
        3600..=7199 => l("time.hour.ago", "1 hour ago"),
        7200..=86399 => n("time.hours.ago", "%d hours ago", seconds / 3600),
        86400..=172799 => l("time.day.ago", "1 day ago"),
        _ => n("time.days.ago", "%d days ago", seconds / 86400),
    }
}

#[cfg(test)]
mod tests;
