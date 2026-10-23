use chrono::NaiveDate;

use super::formatters as f;
use super::*;

fn when() -> chrono::NaiveDateTime {
    NaiveDate::from_ymd_opt(2024, 1, 12)
        .unwrap()
        .and_hms_opt(15, 45, 30)
        .unwrap()
}

/// Tests that change the global language run one at a time.
static LANGUAGE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn prefs(tags: &[&str]) -> Vec<String> {
    tags.iter().map(|t| t.to_string()).collect()
}

#[test]
fn parses_the_swift_tables() {
    assert!(table(Lang::En).len() > 1200);
    assert_eq!(table(Lang::En)["action.cancel"], "Cancel");
    assert_eq!(table(Lang::Fr)["action.cancel"], "Annuler");
    assert_eq!(table(Lang::En)["language.system"], "System Default");
}

#[test]
fn parse_handles_comments_and_escapes() {
    let t = parse_strings(
        "/* head */\n// line\n\"a\" = \"x \\\"q\\\"\\n\";\n\"b\" = \"%d // not a comment\";\n",
    );
    assert_eq!(t["a"], "x \"q\"\n");
    assert_eq!(t["b"], "%d // not a comment");
    assert_eq!(t.len(), 2);
}

// Supplemental defaults added for Chau7, taken from the former Swift
// StartHereSettingsView (fullDiskAccess from ProductivitySettingsView).
const NEXT_STATUS_DEFAULTS: &[(&str, &str)] = &[
    ("settings.profileBar.defaultSettings", "Default Settings"),
    ("settings.startHere.operationalState", "Operational State"),
    ("settings.startHere.activeProfile", "Active Profile"),
    ("settings.startHere.mcp.detail", "Max tabs: %d"),
    ("settings.productivity.permissions.fda.granted", "Granted"),
    (
        "settings.productivity.permissions.fda.granted.detail",
        "Child processes (codex, claude, shells) can reach protected folders like ~/Downloads.",
    ),
    ("settings.productivity.permissions.fda.denied", "Denied"),
    (
        "settings.productivity.permissions.fda.denied.detail",
        "Grant Full Disk Access to Chau7 Next so child processes can reach protected folders.",
    ),
    ("settings.productivity.permissions.fda.unknown", "Unknown"),
    (
        "settings.productivity.permissions.fda.unknown.detail",
        "Full Disk Access status could not be determined.",
    ),
    ("settings.startHere.protectedFolders.none", "None tracked"),
    ("settings.startHere.protectedFolders.ready", "Ready"),
    (
        "settings.startHere.protectedFolders.needsAccess",
        "%d need access",
    ),
    ("settings.startHere.permissions", "Permissions"),
    ("settings.startHere.protectedFolders", "Protected Folders"),
    (
        "settings.startHere.protectedFolders.detail",
        "%d protected roots tracked",
    ),
    ("settings.startHere.paths", "Paths"),
    (
        "settings.startHere.hint",
        "Use the sidebar or search to change any setting shown here. This page summarizes current state only.",
    ),
    (
        "settings.productivity.permissions.fullDiskAccess",
        "Full Disk Access",
    ),
];

// Summary defaults taken from the former Swift SettingsPageSummaryView.
const NEXT_SUMMARY_DEFAULTS: &[(&str, &str)] = &[
    ("Profile Auto-Switching", "Profile Auto-Switching"),
    ("settings.about.developmentVersion", "Development"),
    ("settings.about.support", "Support"),
    (
        "settings.about.support.detail",
        "GitHub, issues, documentation",
    ),
    ("settings.ai.autoTheme", "AI Tab Theme"),
    ("settings.ai.errorExplain", "Error Explanation"),
    ("settings.ai.numberFormat", "Number Format"),
    ("settings.ai.usageMonitoring", "Usage Monitoring"),
    ("settings.dangerous.highlightScope", "Highlight Scope"),
    ("settings.dangerous.lowPower", "Low Power"),
    ("settings.dangerous.patterns", "Patterns"),
    ("settings.dangerous.protectChau7", "Protect Chau7"),
    ("settings.editor.defaultEditor", "Default Editor"),
    ("settings.editor.internalEditor", "Internal Editor"),
    ("settings.general.icloudSync", "iCloud Sync"),
    ("settings.graphics.cache", "Cache"),
    ("settings.graphics.kitty", "Kitty Graphics"),
    ("settings.graphics.sixel", "Sixel"),
    ("settings.hover.aiSession", "AI Session"),
    ("settings.hover.footer", "Footer"),
    ("settings.hover.processes", "Processes"),
    ("settings.injection.localRules", "Repo-Local Rules"),
    ("settings.logs.telemetry", "AI Telemetry & Transcripts"),
    ("settings.logs.telemetryRetention.forever.short", "Forever"),
    ("settings.minimal.hideStatusBar", "Hide Status Bar"),
    ("settings.minimal.hideTabBar", "Hide Tab Bar"),
    ("settings.minimal.hideTitleBar", "Hide Title Bar"),
    ("settings.notifications.actions", "Actions"),
    ("settings.notifications.rateLimit", "Rate Limit"),
    ("settings.performance.activeRefresh", "Active Refresh"),
    ("settings.performance.renderer", "Renderer"),
    ("settings.performance.restoredScrollback", "Restored Lines"),
    ("settings.profileAutoSwitch.rules.count", "%d rules"),
    ("settings.profileBar.profiles", "Profiles"),
    ("settings.repositories.semanticSearch", "Semantic Search"),
    ("settings.shortcuts.helper", "Shortcut Helper"),
    ("settings.snippetsTools.bookmarks", "Bookmarks"),
    (
        "settings.snippetsTools.clipboardHistory",
        "Clipboard History",
    ),
    ("settings.snippetsTools.repoSnippets", "Repo Snippets"),
    ("settings.snippetsTools.snippets", "Snippets"),
    ("settings.ssh.connections", "Chau7 Connections"),
    ("settings.summary.accessibility", "%@ summary"),
    ("settings.summary.days", "%d days"),
    ("settings.summary.items", "%d items"),
    (
        "settings.summary.proxyNeeded",
        "Proxy applies AI context rules.",
    ),
    ("settings.summary.rateLimit", "%d/min, %ds cooldown"),
    ("settings.tabs.indicators.count", "%d visible"),
    ("settings.windows.windowBlur", "Window Blur"),
    ("ssh.lastSync.short", "Last Sync"),
    ("status.available", "Available"),
    ("status.configured", "Configured"),
    ("status.error", "Error"),
    ("status.hidden", "Hidden"),
    ("status.never", "Never"),
    ("status.unconfigured", "Unconfigured"),
    ("status.visible", "Visible"),
];

// Rust-specific tab navigation labels.
const NEXT_TAB_NAVIGATION_DEFAULTS: &[(&str, &str)] = &[
    ("tabs.idle.noRepository", "No repository"),
    (
        "settings.tabs.numberedShortcutsVisibleOnly",
        "Numbered Shortcuts Target Visible Tabs Only",
    ),
    (
        "settings.tabs.numberedShortcutsVisibleOnly.help",
        "Count only tabs shown in the tab bar when selecting a tab by number.",
    ),
    (
        "settings.search.numberedShortcutsVisibleOnly.keywords",
        "visible tabs,numbered shortcuts,command number,cmd,alt,function keys,idle,collapsed groups",
    ),
];

#[test]
fn other_languages_only_miss_the_known_keys() {
    let en = table(Lang::En);
    let known = [
        "settings.about.licenseSummary",
        "settings.about.openAcknowledgments",
        "settings.about.stackSummary",
    ];
    for lang in [Lang::Fr, Lang::Es, Lang::Ar, Lang::He] {
        let t = table(lang);
        for key in en.keys() {
            assert!(
                t.contains_key(key) || known.contains(&key.as_str()),
                "{} lacks {key}",
                lang.code()
            );
        }
        for key in t.keys() {
            assert!(en.contains_key(key), "{} has extra {key}", lang.code());
        }
    }
}

#[test]
fn fallback_to_the_english_default() {
    // Missing key: the default from the code.
    assert_eq!(localized(Lang::Fr, "no.such.key", "Fallback"), "Fallback");
    // Missing in fr/ar/he but present in English: the default (L10-005),
    // and with no default the English text. The Swift tables of October
    // 2026 translate every key, so this only runs when one is missing.
    for lang in [Lang::Fr, Lang::Es, Lang::Ar, Lang::He] {
        let en = table(Lang::En);
        if let Some(key) = en.keys().find(|k| !table(lang).contains_key(*k)) {
            assert_eq!(localized(lang, key, "Fallback"), "Fallback");
            assert_eq!(localized(lang, key, ""), en[key]);
        }
    }
    assert_eq!(localized(Lang::He, "no.such.key", ""), "no.such.key");
    // Present: the translation wins over the default.
    assert_eq!(localized(Lang::Fr, "action.cancel", "Cancel"), "Annuler");
}

#[test]
fn current_language_drives_l() {
    let _guard = LANGUAGE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    set_current(Lang::Fr);
    assert_eq!(l("action.cancel", "Cancel"), "Annuler");
    assert_eq!(tr("Cancel"), "Annuler");
    set_current(Lang::En);
    assert_eq!(l("action.cancel", "Cancel"), "Cancel");
    assert_eq!(tr("Cancel"), "Cancel");
}

#[test]
fn translate_matches_english_text() {
    assert_eq!(translate(Lang::Fr, "Cancel"), "Annuler");
    assert_eq!(
        translate(Lang::Fr, "Unknown text nobody has"),
        "Unknown text nobody has"
    );
    assert_eq!(translate(Lang::En, "Cancel"), "Cancel");
    // Loose match keeps the caller's ellipsis.
    let key = key_for_english("Add").unwrap();
    assert!(table(Lang::En).contains_key(key));
    assert!(translate(Lang::Fr, "Add…").ends_with('…'));
}

#[test]
fn system_default_is_not_a_language_outside_the_language_picker() {
    // The shell and browser "System Default" choices must not read as
    // "Langue du système"; the language picker asks by key.
    assert_ne!(translate(Lang::Fr, "System Default"), "Langue du système");
    assert_eq!(
        l10n_fr("language.system", "System Default"),
        "Langue du système"
    );
}

#[test]
fn all_caps_headers_stay_in_capitals() {
    assert_eq!(translate(Lang::Fr, "TERMINAL"), "TERMINAL");
    // Swift's French for the "Terminal" section ("Console" since 2026).
    let key = key_for_english("Terminal").unwrap();
    assert_eq!(translate(Lang::Fr, "Terminal"), table(Lang::Fr)[key]);
}

fn l10n_fr(key: &str, default: &str) -> String {
    localized(Lang::Fr, key, default)
}

#[test]
fn product_name_is_kept() {
    let out = translate(Lang::Fr, "About Chau7 Next");
    assert!(out.contains(crate::data_root::APP_NAME), "{out}");
    assert!(!out.contains("About"), "{out}");
    assert!(!out.contains("Chau7 Next Next"));
}

#[test]
fn system_default_follows_preferred_languages() {
    assert_eq!(resolve("system", &prefs(&["fr-FR", "en-US"])), Lang::Fr);
    assert_eq!(resolve("system", &prefs(&["de-DE", "ar-EG"])), Lang::Ar);
    assert_eq!(resolve("system", &prefs(&["iw-IL"])), Lang::He);
    assert_eq!(resolve("system", &prefs(&["de-DE", "ja"])), Lang::En);
    assert_eq!(resolve("system", &[]), Lang::En);
    assert_eq!(resolve("he", &prefs(&["fr"])), Lang::He);
    assert_eq!(resolve("en", &prefs(&["fr"])), Lang::En);
    assert_eq!(resolve("klingon", &prefs(&["fr"])), Lang::Fr);
}

#[test]
fn rtl_detection() {
    let _guard = LANGUAGE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    assert!(Lang::Ar.is_rtl());
    assert!(Lang::He.is_rtl());
    assert!(!Lang::En.is_rtl());
    assert!(!Lang::Fr.is_rtl());
    set_current(Lang::Ar);
    assert!(is_rtl());
    set_current(Lang::En);
    assert!(!is_rtl());
}

#[test]
fn printf_formats() {
    let _guard = LANGUAGE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    set_current(Lang::En);
    assert_eq!(format_printf("%d snippets", &[Arg::Int(3)]), "3 snippets");
    assert_eq!(format_printf("Tab %@", &["x".into()]), "Tab x");
    assert_eq!(
        format_printf("%2$@ then %1$@", &["a".into(), "b".into()]),
        "b then a"
    );
    assert_eq!(format_printf("100%% of %lld", &[Arg::Int(7)]), "100% of 7");
    assert_eq!(format_printf("%.1f MB", &[Arg::Float(1.26)]), "1.3 MB");
    assert_eq!(format_printf("%@ %@", &["a".into()]), "a %@");
    assert_eq!(
        lf("snippets.count", "%d snippets", &[Arg::Int(4)]),
        "4 snippets"
    );
}

#[test]
fn numbers_per_locale() {
    assert_eq!(f::integer(Lang::En, 1234567), "1,234,567");
    assert_eq!(f::integer(Lang::Fr, 1234567), "1\u{202F}234\u{202F}567");
    assert_eq!(f::integer(Lang::Ar, 1234), "١٬٢٣٤");
    assert_eq!(f::integer(Lang::He, 1234), "1,234");
    assert_eq!(f::decimal(Lang::En, 1234.5, 2), "1,234.5");
    assert_eq!(f::decimal(Lang::Fr, 1234.5, 2), "1\u{202F}234,5");
    assert_eq!(f::decimal(Lang::Ar, 1.25, 2), "١٫٢٥");
    assert_eq!(f::decimal(Lang::En, -12.0, 1), "-12");
}

#[test]
fn percentages_per_locale() {
    assert_eq!(f::percent(Lang::En, 0.256), "25.6%");
    assert_eq!(f::percent(Lang::Fr, 0.5), "50\u{202F}%");
    assert_eq!(f::percent(Lang::Ar, 0.5), "٥٠\u{066A}\u{061C}");
    assert_eq!(f::percent(Lang::He, 1.0), "100%");
}

#[test]
fn file_sizes_per_locale() {
    assert_eq!(f::file_size(Lang::En, 512), "512 bytes");
    assert_eq!(f::file_size(Lang::En, 1), "1 byte");
    assert_eq!(f::file_size(Lang::En, 150_000), "150 KB");
    assert_eq!(f::file_size(Lang::En, 12_345), "12.3 KB");
    assert_eq!(f::file_size(Lang::En, 1_500_000), "1.5 MB");
    assert_eq!(f::file_size(Lang::Fr, 2_000), "2 Ko");
    assert_eq!(f::file_size(Lang::Fr, 1_500_000), "1,5 Mo");
    assert_eq!(f::file_size(Lang::Fr, 10), "10 octets");
    assert_eq!(f::file_size(Lang::He, 3_000_000_000), "3 ג״ב");
    assert!(f::file_size(Lang::Ar, 1_500_000).starts_with("١٫٥"));
}

#[test]
fn dates_per_locale() {
    let t = when();
    assert_eq!(f::short_date(Lang::En, t), "1/12/24");
    assert_eq!(f::short_date(Lang::Fr, t), "12/01/2024");
    assert_eq!(f::short_date(Lang::He, t), "12.1.2024");
    assert_eq!(f::medium_date(Lang::En, t), "Jan 12, 2024");
    assert_eq!(f::medium_date(Lang::Fr, t), "12 janv. 2024");
    assert_eq!(f::long_date(Lang::En, t), "January 12, 2024");
    assert_eq!(f::long_date(Lang::Fr, t), "12 janvier 2024");
    assert_eq!(f::long_date(Lang::Ar, t), "١٢ يناير ٢٠٢٤");
    assert_eq!(f::long_date(Lang::He, t), "12 בינואר 2024");
    assert_eq!(f::short_time(Lang::En, t), "3:45\u{202F}PM");
    assert_eq!(f::short_time(Lang::Fr, t), "15:45");
    assert_eq!(f::medium_time(Lang::Fr, t), "15:45:30");
    assert_eq!(f::short_time(Lang::Ar, t), "٣:٤٥\u{202F}م");
    assert_eq!(f::date_time(Lang::Fr, t), "12 janv. 2024, 15:45");
}

#[test]
fn relative_ages() {
    let _guard = LANGUAGE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    set_current(Lang::Fr);
    assert_eq!(relative_age(5), table(Lang::Fr)["time.just.now"]);
    assert!(relative_age(300).contains('5'));
    set_current(Lang::En);
    assert_eq!(relative_age(300), "5 minutes ago");
    assert_eq!(relative_age(3600), "1 hour ago");
}

#[test]
fn spanish_resolution_and_formatting() {
    assert_eq!(resolve("system", &prefs(&["es-MX", "en"])), Lang::Es);
    assert_eq!(resolve("es", &prefs(&["fr"])), Lang::Es);
    assert_eq!(localized(Lang::Es, "action.cancel", "Cancel"), "Cancelar");
    assert_eq!(f::decimal(Lang::Es, 1234.5, 1), "1234,5");
    assert_eq!(f::decimal(Lang::Es, 10000.5, 1), "10.000,5");
    assert_eq!(f::percent(Lang::Es, 0.5), "50\u{00A0}%");
    assert_eq!(f::long_date(Lang::Es, when()), "12 de enero de 2024");
    assert_eq!(f::short_time(Lang::Es, when()), "15:45");
}

#[test]
fn next_status_defaults_are_the_english_table_values() {
    for (key, default) in NEXT_STATUS_DEFAULTS {
        assert_eq!(
            table(Lang::En)[*key],
            *default,
            "supplemental English default: {key}"
        );
    }
    assert_eq!(NEXT_STATUS_DEFAULTS.len(), 19);
}

#[test]
fn summary_defaults_are_the_english_table_values() {
    for (key, default) in NEXT_SUMMARY_DEFAULTS {
        assert_eq!(
            table(Lang::En)[*key],
            *default,
            "summary English fallback: {key}"
        );
    }
    assert_eq!(NEXT_SUMMARY_DEFAULTS.len(), 56);
}

#[test]
fn product_identity_matches_channel_for_literal_and_keyed_resources() {
    for lang in Lang::ALL {
        let literal = translate(lang, "About Chau7 Next");
        let keyed = localized(
            lang,
            "settings.productivity.permissions.fda.denied.detail",
            "",
        );
        for text in [literal, keyed] {
            assert!(
                text.contains(crate::data_root::APP_NAME),
                "{lang:?}: {text}"
            );
            if crate::data_root::PRODUCTION_CHANNEL {
                assert!(!text.contains("Chau7 Next"), "{lang:?}: {text}");
            }
        }
    }
}

#[test]
fn production_branding_does_not_rewrite_user_format_arguments() {
    let user_text = "Chau7 Next project";
    let text = localized_format(
        Lang::En,
        "test.missing.format",
        "%@",
        &[Arg::from(user_text)],
    );
    assert_eq!(text, user_text);
}

#[test]
fn tab_navigation_labels_are_translated() {
    for (key, default) in NEXT_TAB_NAVIGATION_DEFAULTS {
        assert_eq!(
            table(Lang::En).get(*key).map(String::as_str),
            Some(*default)
        );
        for lang in [Lang::Fr, Lang::Es, Lang::Ar, Lang::He] {
            let translated = table(lang)
                .get(*key)
                .expect("missing tab navigation translation");
            assert!(!translated.is_empty());
            assert_ne!(translated.as_str(), *default, "{}: {key}", lang.code());
        }
    }
}
