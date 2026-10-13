//! Process-local settings acceptance choices; never changes the OS language.
use crate::settings::AppLanguage;
use chau7_next_core::{
    l10n::{self, Lang, numbers::RegionalNumberFormat},
    settings_search::SettingsSection,
};

pub(super) const LANGUAGE_ENV: &str = "CHAU7_NEXT_NATIVE_SETTINGS_LANGUAGE";
pub(super) const NUMBER_FORMAT_ENV: &str = "CHAU7_NEXT_NATIVE_SETTINGS_NUMBER_FORMAT";
pub(super) struct LocaleCase {
    pub setting: AppLanguage,
    pub preferred: Vec<String>,
    pub resolved: Lang,
}
impl LocaleCase {
    pub fn new(requested: &str, preferred: Vec<String>) -> Result<Self, String> {
        let setting = AppLanguage::from_id(requested)
            .ok_or_else(|| format!("unsupported native Settings language: {requested}"))?;
        Ok(Self {
            setting,
            resolved: l10n::resolve(setting.id(), &preferred),
            preferred,
        })
    }
    pub fn queries(&self) -> Vec<QuerySpec> {
        let mut cases = if self.setting == AppLanguage::English {
            vec![
                QuerySpec::english(
                    "restored",
                    SettingsSection::ScrollbackPerf,
                    "restoredScrollback",
                ),
                QuerySpec::english("config file", SettingsSection::General, "configFile"),
                QuerySpec::english("cursor", SettingsSection::Shell, "cursor"),
            ]
        } else {
            TITLES
                .iter()
                .map(|&(key, default, section, anchor)| QuerySpec {
                    query: l10n::localized(self.resolved, key, default),
                    expected: Some((section, anchor)),
                    title_key: Some(key),
                    fallback: !l10n::table(self.resolved).contains_key(key),
                })
                .collect()
        };
        cases.extend([
            QuerySpec::empty("no-such-current-setting-12345"),
            QuerySpec::empty(""),
        ]);
        cases
    }
}

/// A regional usage-number preference, resolved independently of app language.
#[derive(Clone, Copy)]
pub(super) struct RegionalNumberFormatCase {
    pub setting: RegionalNumberFormat,
}
impl RegionalNumberFormatCase {
    pub fn new(requested: Option<&str>) -> Result<Self, String> {
        let requested = requested.unwrap_or("fr");
        let setting = RegionalNumberFormat::from_id(requested).ok_or_else(|| {
            format!("unsupported native Settings regional number format: {requested}")
        })?;
        Ok(Self { setting })
    }
}

const TITLES: &[(&str, &str, SettingsSection, &str)] = &[
    (
        "settings.search.restoredScrollback.title",
        "Restored Scrollback",
        SettingsSection::ScrollbackPerf,
        "restoredScrollback",
    ),
    (
        "settings.search.configFile.title",
        "Config File",
        SettingsSection::General,
        "configFile",
    ),
    (
        "settings.search.cursor.title",
        "Cursor Style",
        SettingsSection::Shell,
        "cursor",
    ),
];
pub(super) struct QuerySpec {
    pub query: String,
    pub expected: Option<(SettingsSection, &'static str)>,
    pub title_key: Option<&'static str>,
    pub fallback: bool,
}
impl QuerySpec {
    fn english(query: &str, section: SettingsSection, anchor: &'static str) -> Self {
        Self {
            query: query.into(),
            expected: Some((section, anchor)),
            title_key: None,
            fallback: false,
        }
    }
    fn empty(query: &str) -> Self {
        Self {
            query: query.into(),
            expected: None,
            title_key: None,
            fallback: false,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::settings_search::{matching_settings_in, sections_matching_in};
    fn swift_table(lang: Lang) -> l10n::Table {
        let source = match lang {
            Lang::En => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../chau7-macos/Sources/Chau7/Resources/en.lproj/Localizable.strings"
            )),
            Lang::Fr => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../chau7-macos/Sources/Chau7/Resources/fr.lproj/Localizable.strings"
            )),
            Lang::Ar => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../chau7-macos/Sources/Chau7/Resources/ar.lproj/Localizable.strings"
            )),
            Lang::Es => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../chau7-macos/Sources/Chau7/Resources/es.lproj/Localizable.strings"
            )),
            Lang::He => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../chau7-macos/Sources/Chau7/Resources/he.lproj/Localizable.strings"
            )),
        };
        l10n::parse_strings(source)
    }
    #[test]
    fn native_choices_follow_actual_resolution_and_reject_unknown_variants() {
        let preferred = vec!["fr-FR".into(), "ar".into()];
        let system = LocaleCase::new("system", preferred.clone()).unwrap();
        assert_eq!(system.resolved, Lang::Fr);
        assert_eq!(system.preferred, preferred);
        assert_eq!(
            LocaleCase::new("ar", preferred.clone()).unwrap().resolved,
            Lang::Ar
        );
        assert!(
            LocaleCase::new("ar", preferred.clone())
                .unwrap()
                .resolved
                .is_rtl()
        );
        let spanish = LocaleCase::new("es", preferred.clone()).unwrap();
        assert_eq!(spanish.setting, AppLanguage::Spanish);
        assert_eq!(spanish.resolved, Lang::Es);
        assert!(!spanish.resolved.is_rtl());
        assert!(LocaleCase::new("unexpected", preferred).is_err());
        assert_eq!(
            LocaleCase::new("system", vec![]).unwrap().resolved,
            Lang::En
        );
        assert_eq!(LANGUAGE_ENV, "CHAU7_NEXT_NATIVE_SETTINGS_LANGUAGE");
    }
    #[test]
    fn native_choices_cover_every_production_language_including_hebrew() {
        for setting in AppLanguage::ALL {
            let case = LocaleCase::new(setting.id(), vec!["fr-FR".into()]).unwrap();
            assert_eq!(case.setting, setting);
            assert_eq!(case.resolved.is_rtl(), setting.is_rtl());
        }
        let hebrew = LocaleCase::new("he", vec!["en-US".into()]).unwrap();
        assert_eq!(hebrew.setting, AppLanguage::Hebrew);
        assert_eq!(hebrew.resolved, Lang::He);
        assert!(hebrew.resolved.is_rtl());
    }

    #[test]
    fn regional_number_format_choices_are_typed_and_reject_unknown_values() {
        for (id, expected) in [
            ("fr", RegionalNumberFormat::French),
            ("eu", RegionalNumberFormat::European),
            ("us", RegionalNumberFormat::UnitedStates),
        ] {
            assert_eq!(
                RegionalNumberFormatCase::new(Some(id)).unwrap().setting,
                expected
            );
        }
        assert_eq!(
            RegionalNumberFormatCase::new(None).unwrap().setting,
            RegionalNumberFormat::French
        );
        assert!(RegionalNumberFormatCase::new(Some("es")).is_err());
    }
    #[test]
    fn number_format_environment_name_matches_fixture_contract() {
        assert_eq!(
            NUMBER_FORMAT_ENV,
            "CHAU7_NEXT_NATIVE_SETTINGS_NUMBER_FORMAT"
        );
    }
    #[test]
    fn five_queries_keep_english_exact_and_localized_source_goldens() {
        let swift_metadata = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../chau7-macos/Sources/Chau7/Settings/SettingsSearch.swift"
        ));
        for (key, default, _, _) in TITLES {
            assert!(
                swift_metadata.contains(&format!("title: L(\"{key}\", \"{default}\")")),
                "source default: {key}"
            );
        }
        for requested in AppLanguage::ALL.map(AppLanguage::id) {
            let case = LocaleCase::new(requested, vec!["fr-FR".into()]).unwrap();
            let queries = case.queries();
            assert_eq!(queries.len(), 5);
            if requested == "en" {
                assert_eq!(
                    queries.iter().map(|s| s.query.as_str()).collect::<Vec<_>>(),
                    [
                        "restored",
                        "config file",
                        "cursor",
                        "no-such-current-setting-12345",
                        ""
                    ]
                );
            }
            for spec in &queries {
                let first = sections_matching_in(case.resolved, &spec.query)
                    .first()
                    .map(|(section, _)| *section);
                if let Some((section, anchor)) = spec.expected {
                    assert_eq!(first, Some(section), "{requested}: {}", spec.query);
                    assert_eq!(
                        matching_settings_in(case.resolved, section, &spec.query)[0].anchor_id,
                        anchor,
                        "{requested}: {}",
                        spec.query
                    );
                } else {
                    assert!(first.is_none(), "{requested}: {}", spec.query);
                }
                if let Some(key) = spec.title_key {
                    let (_, default, _, _) = TITLES.iter().find(|t| t.0 == key).unwrap();
                    let swift = swift_table(case.resolved);
                    assert_eq!(
                        spec.query,
                        swift
                            .get(key)
                            .map_or_else(|| default.to_string(), Clone::clone),
                        "{}: {key}",
                        case.resolved.code()
                    );
                    assert_eq!(
                        spec.fallback,
                        !swift.contains_key(key),
                        "{requested}: {key}"
                    );
                }
            }
        }
    }
}
