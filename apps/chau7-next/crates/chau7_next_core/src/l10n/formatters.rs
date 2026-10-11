//! `LocalizedFormatters`: dates, numbers, percentages and file sizes for the
//! five interface languages (CLDR conventions for en, fr, es, ar and he; Arabic
//! uses Arabic-Indic digits). Every function takes the language, so callers
//! pass `l10n::current()` and tests pass any.

use chrono::{Datelike, NaiveDateTime, Timelike};

use super::Lang;

const NNBSP: char = '\u{202F}';

fn arabic_digits(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            '0'..='9' => char::from_u32('٠' as u32 + (c as u32 - '0' as u32)).unwrap_or(c),
            other => other,
        })
        .collect()
}

/// Digits in the script of the language.
fn digits(lang: Lang, text: String) -> String {
    if lang == Lang::Ar {
        arabic_digits(&text)
    } else {
        text
    }
}

fn separators(lang: Lang) -> (&'static str, &'static str) {
    // (grouping, decimal)
    match lang {
        Lang::En | Lang::He => (",", "."),
        Lang::Fr => ("\u{202F}", ","),
        Lang::Es => (".", ","),
        Lang::Ar => ("٬", "٫"),
    }
}

fn group(int_part: &str, sep: &str) -> String {
    let n = int_part.len();
    let mut out = String::new();
    for (i, c) in int_part.chars().enumerate() {
        if i > 0 && (n - i).is_multiple_of(3) {
            out.push_str(sep);
        }
        out.push(c);
    }
    out
}

/// A number with grouping and at most `max_fraction` decimals (trailing zeros
/// dropped), e.g. `1,234.5` / `1 234,5` / `١٬٢٣٤٫٥`.
pub fn decimal(lang: Lang, value: f64, max_fraction: usize) -> String {
    let (sep, dec) = separators(lang);
    let negative = value < 0.0;
    let text = format!("{:.*}", max_fraction, value.abs());
    let (int_part, frac) = match text.split_once('.') {
        Some((i, f)) => (i.to_string(), f.trim_end_matches('0').to_string()),
        None => (text, String::new()),
    };
    let mut out = String::new();
    if negative && (!int_part.trim_matches('0').is_empty() || !frac.is_empty()) {
        out.push('-');
    }
    // Foundation's Spanish locale groups only numbers of five or more
    // digits (1234,5; 10.000,5), unlike English and French.
    if lang == Lang::Es && int_part.len() < 5 {
        out.push_str(&int_part);
    } else {
        out.push_str(&group(&int_part, sep));
    }
    if !frac.is_empty() {
        out.push_str(dec);
        out.push_str(&frac);
    }
    digits(lang, out)
}

/// An integer with grouping (`LocalizedFormatters.integer`).
pub fn integer(lang: Lang, value: i64) -> String {
    decimal(lang, value as f64, 0)
}

/// A percentage from a fraction (0.256 is 25.6%), at most one decimal
/// (`LocalizedFormatters.percent`).
pub fn percent(lang: Lang, fraction: f64) -> String {
    let number = decimal(lang, fraction * 100.0, 1);
    match lang {
        Lang::En | Lang::He => format!("{number}%"),
        Lang::Fr => format!("{number}{NNBSP}%"),
        Lang::Es => format!("{number}\u{00A0}%"),
        Lang::Ar => format!("{number}\u{066A}\u{061C}"),
    }
}

/// A byte count the way `ByteCountFormatter` (file style, decimal units)
/// writes it: "512 bytes", "12.3 KB", "150 KB", "1.5 MB", "2 Ko".
pub fn file_size(lang: Lang, bytes: u64) -> String {
    let units: [&str; 5] = match lang {
        Lang::En | Lang::Es => ["KB", "MB", "GB", "TB", "PB"],
        Lang::Fr => ["Ko", "Mo", "Go", "To", "Po"],
        Lang::Ar => ["ك.ب", "م.ب", "ج.ب", "ت.ب", "ب.ب"],
        Lang::He => ["ק״ב", "מ״ב", "ג״ב", "ט״ב", "פ״ב"],
    };
    if bytes < 1000 {
        let word = match (lang, bytes) {
            (Lang::En | Lang::Es, 1) => "byte",
            (Lang::En | Lang::Es, _) => "bytes",
            (Lang::Fr, _) => "octets",
            (Lang::Ar, _) => "بايت",
            (Lang::He, _) => "בייטים",
        };
        return digits(lang, format!("{bytes} {word}"));
    }
    let mut value = bytes as f64 / 1000.0;
    let mut unit = 0;
    while value >= 1000.0 && unit + 1 < units.len() {
        value /= 1000.0;
        unit += 1;
    }
    let fraction = if value >= 100.0 { 0 } else { 1 };
    format!("{} {}", decimal(lang, value, fraction), units[unit])
}

fn months(lang: Lang, short: bool) -> [&'static str; 12] {
    match (lang, short) {
        (Lang::En, false) => [
            "January",
            "February",
            "March",
            "April",
            "May",
            "June",
            "July",
            "August",
            "September",
            "October",
            "November",
            "December",
        ],
        (Lang::En, true) => [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ],
        (Lang::Fr, false) => [
            "janvier",
            "février",
            "mars",
            "avril",
            "mai",
            "juin",
            "juillet",
            "août",
            "septembre",
            "octobre",
            "novembre",
            "décembre",
        ],
        (Lang::Fr, true) => [
            "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.",
            "nov.", "déc.",
        ],
        (Lang::Es, false) => [
            "enero",
            "febrero",
            "marzo",
            "abril",
            "mayo",
            "junio",
            "julio",
            "agosto",
            "septiembre",
            "octubre",
            "noviembre",
            "diciembre",
        ],
        (Lang::Es, true) => [
            "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic",
        ],
        (Lang::Ar, _) => [
            "يناير",
            "فبراير",
            "مارس",
            "أبريل",
            "مايو",
            "يونيو",
            "يوليو",
            "أغسطس",
            "سبتمبر",
            "أكتوبر",
            "نوفمبر",
            "ديسمبر",
        ],
        (Lang::He, false) => [
            "ינואר",
            "פברואר",
            "מרץ",
            "אפריל",
            "מאי",
            "יוני",
            "יולי",
            "אוגוסט",
            "ספטמבר",
            "אוקטובר",
            "נובמבר",
            "דצמבר",
        ],
        (Lang::He, true) => [
            "ינו׳", "פבר׳", "מרץ", "אפר׳", "מאי", "יוני", "יולי", "אוג׳", "ספט׳", "אוק׳", "נוב׳",
            "דצמ׳",
        ],
    }
}

/// "1/12/24", "12/01/2024", "١٢‏/١‏/٢٠٢٤", "12.1.2024".
pub fn short_date(lang: Lang, t: NaiveDateTime) -> String {
    let (y, m, d) = (t.year(), t.month(), t.day());
    let text = match lang {
        Lang::En => format!("{m}/{d}/{:02}", y.rem_euclid(100)),
        Lang::Fr => format!("{d:02}/{m:02}/{y}"),
        Lang::Es => format!("{d}/{m}/{:02}", y.rem_euclid(100)),
        Lang::Ar => format!("{d}\u{200F}/{m}\u{200F}/{y}"),
        Lang::He => format!("{d}.{m}.{y}"),
    };
    digits(lang, text)
}

/// "Jan 12, 2024", "12 janv. 2024".
pub fn medium_date(lang: Lang, t: NaiveDateTime) -> String {
    let month = months(lang, true)[t.month0() as usize];
    let (y, d) = (t.year(), t.day());
    let text = match lang {
        Lang::En => format!("{month} {d}, {y}"),
        Lang::Fr | Lang::Ar | Lang::Es => format!("{d} {month} {y}"),
        Lang::He => format!("{d} ב{month} {y}"),
    };
    digits(lang, text)
}

/// "January 12, 2024", "12 janvier 2024".
pub fn long_date(lang: Lang, t: NaiveDateTime) -> String {
    let month = months(lang, false)[t.month0() as usize];
    let (y, d) = (t.year(), t.day());
    let text = match lang {
        Lang::En => format!("{month} {d}, {y}"),
        Lang::Fr | Lang::Ar => format!("{d} {month} {y}"),
        Lang::Es => format!("{d} de {month} de {y}"),
        Lang::He => format!("{d} ב{month} {y}"),
    };
    digits(lang, text)
}

fn clock(lang: Lang, t: NaiveDateTime, seconds: bool) -> String {
    let (h, m, s) = (t.hour(), t.minute(), t.second());
    let text = match lang {
        Lang::En | Lang::Ar => {
            let h12 = match h % 12 {
                0 => 12,
                other => other,
            };
            let mark = match (lang, h < 12) {
                (Lang::En, true) => "AM",
                (Lang::En, false) => "PM",
                (_, true) => "ص",
                (_, false) => "م",
            };
            if seconds {
                format!("{h12}:{m:02}:{s:02}{NNBSP}{mark}")
            } else {
                format!("{h12}:{m:02}{NNBSP}{mark}")
            }
        }
        Lang::Fr => {
            if seconds {
                format!("{h:02}:{m:02}:{s:02}")
            } else {
                format!("{h:02}:{m:02}")
            }
        }
        Lang::He | Lang::Es => {
            if seconds {
                format!("{h}:{m:02}:{s:02}")
            } else {
                format!("{h}:{m:02}")
            }
        }
    };
    digits(lang, text)
}

/// "3:45 PM", "15:45".
pub fn short_time(lang: Lang, t: NaiveDateTime) -> String {
    clock(lang, t, false)
}

/// "3:45:30 PM", "15:45:30".
pub fn medium_time(lang: Lang, t: NaiveDateTime) -> String {
    clock(lang, t, true)
}

/// Medium date and short time.
pub fn date_time(lang: Lang, t: NaiveDateTime) -> String {
    format!("{}, {}", medium_date(lang, t), short_time(lang, t))
}
