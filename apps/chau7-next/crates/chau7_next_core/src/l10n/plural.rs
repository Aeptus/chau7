//! Swift's Localizable.stringsdict rules, including Arabic and Hebrew counts.
use std::collections::HashMap;
use std::sync::OnceLock;

use super::{Arg, Lang, format_printf};

type Rules = HashMap<String, plist::Dictionary>;

pub(super) fn source(lang: Lang) -> &'static str {
    match lang {
        Lang::En => include_str!("strings/en.stringsdict"),
        Lang::Fr => include_str!("strings/fr.stringsdict"),
        Lang::Es => include_str!("strings/es.stringsdict"),
        Lang::Ar => include_str!("strings/ar.stringsdict"),
        Lang::He => include_str!("strings/he.stringsdict"),
    }
}

fn tables() -> &'static [Rules; 5] {
    static TABLES: OnceLock<[Rules; 5]> = OnceLock::new();
    TABLES.get_or_init(|| {
        Lang::ALL.map(|lang| {
            plist::Value::from_reader_xml(source(lang).as_bytes())
                .expect("valid bundled Swift plural table")
                .into_dictionary()
                .expect("plural table is a dictionary")
                .into_iter()
                .filter_map(|(key, value)| value.into_dictionary().map(|d| (key, d)))
                .collect()
        })
    })
}

fn category(lang: Lang, count: i64) -> &'static str {
    let n = count.unsigned_abs();
    match lang {
        Lang::Ar => match n {
            0 => "zero",
            1 => "one",
            2 => "two",
            _ if (3..=10).contains(&(n % 100)) => "few",
            _ if (11..=99).contains(&(n % 100)) => "many",
            _ => "other",
        },
        Lang::He if n == 2 => "two",
        Lang::Fr if n <= 1 => "one",
        _ if n == 1 => "one",
        _ => "other",
    }
}

pub(super) fn format(lang: Lang, key: &str, args: &[Arg]) -> Option<String> {
    let entry = tables()[lang.index() as usize].get(key)?;
    let mut format = entry
        .get("NSStringLocalizedFormatKey")?
        .as_string()?
        .to_string();
    // The current Swift resources use one count argument, followed by optional
    // explicitly positioned arguments (for example the list of running apps).
    let count = match args.first()? {
        Arg::Int(n) => *n,
        _ => return None,
    };
    for (name, rule) in entry {
        let Some(rule) = rule.as_dictionary() else {
            continue;
        };
        let token = format!("%#@{name}@");
        if !format.contains(&token) {
            continue;
        }
        let variant = rule
            .get(category(lang, count))
            .or_else(|| rule.get("other"))?
            .as_string()?;
        let rendered = format_printf(variant, &[Arg::Int(count)]).replace('%', "%%");
        format = format.replace(&token, &rendered);
    }
    Some(format_printf(&format, args))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arabic_counts_select_every_category() {
        let expected = [
            (0, "لا ملفات"),
            (1, "ملف واحد"),
            (2, "ملفان"),
            (3, "3 ملفات"),
            (11, "11 ملفًا"),
            (100, "100 ملف"),
        ];
        for (n, text) in expected {
            assert_eq!(
                format(Lang::Ar, "panel.changedFiles.fileCount", &[Arg::Int(n)]).unwrap(),
                text
            );
        }
    }

    #[test]
    fn french_zero_and_spanish_one_follow_their_locale() {
        assert_eq!(category(Lang::Fr, 0), "one");
        assert_eq!(category(Lang::Es, 0), "other");
        assert_eq!(
            format(Lang::Es, "panel.changedFiles.fileCount", &[Arg::Int(1)]).unwrap(),
            "1 archivo"
        );
        assert_eq!(
            format(Lang::Es, "panel.changedFiles.fileCount", &[Arg::Int(2)]).unwrap(),
            "2 archivos"
        );
    }

    #[test]
    fn plural_does_not_consume_a_positioned_second_argument() {
        let out = format(
            Lang::En,
            "alert.quit.message",
            &[Arg::Int(1), Arg::from("claude")],
        )
        .unwrap();
        assert!(out.contains("claude"), "{out}");
        assert!(out.starts_with("1 running process"), "{out}");
    }
}
