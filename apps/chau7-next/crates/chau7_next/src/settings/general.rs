//! General (`GeneralSettingsView.swift`): startup directory, launch at login,
//! app language, config file loading and iCloud sync (the app theme is in
//! `appearance.rs`).
//!
//! Keys the Swift `config.toml` has (`[general] default_directory`) stay
//! there; the rest only Chau7 Next reads, under `[next]`.

use chau7_next_core::config::RawValue;
use chau7_next_core::l10n::numbers::RegionalNumberFormat;

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// `app.language` (`AppLanguage`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum AppLanguage {
    #[default]
    System,
    English,
    French,
    Spanish,
    Arabic,
    Hebrew,
}

impl AppLanguage {
    pub const ALL: [AppLanguage; 6] = [
        AppLanguage::System,
        AppLanguage::English,
        AppLanguage::French,
        AppLanguage::Spanish,
        AppLanguage::Arabic,
        AppLanguage::Hebrew,
    ];

    /// Raw value (`AppLanguage.rawValue`): "system" or the language code.
    pub fn id(self) -> &'static str {
        match self {
            AppLanguage::System => "system",
            AppLanguage::English => "en",
            AppLanguage::French => "fr",
            AppLanguage::Spanish => "es",
            AppLanguage::Arabic => "ar",
            AppLanguage::Hebrew => "he",
        }
    }

    pub fn from_id(id: &str) -> Option<AppLanguage> {
        Self::ALL.into_iter().find(|l| l.id() == id)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            AppLanguage::System => "System Default",
            AppLanguage::English => "English",
            AppLanguage::French => "Français",
            AppLanguage::Spanish => "Español",
            AppLanguage::Arabic => "العربية",
            AppLanguage::Hebrew => "עברית",
        }
    }

    /// Right-to-left languages.
    pub fn is_rtl(self) -> bool {
        matches!(self, AppLanguage::Arabic | AppLanguage::Hebrew)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct GeneralSettings {
    /// `[general] default_directory`; `None` starts in the home folder.
    pub default_directory: Option<String>,
    /// `app.language` (`[next] app_language`). Stored and applied by the
    /// Localization module; the interface strings are English until then.
    pub app_language: AppLanguage,
    /// usage.regionalNumberFormat: numeric display independent of language.
    pub regional_number_format: RegionalNumberFormat,
    /// `app.launchAtLogin` (`[next] launch_at_login`). The login item itself
    /// is registered with the OS (`platform::login_item`).
    pub launch_at_login: bool,
    /// `feature.configFile` (`[next] load_config_files`): reload the config
    /// file when it changes and apply per-repo `.chau7/config.toml`.
    pub load_config_files: bool,
    /// `sync.iCloudEnabled` (`[next] icloud_sync`).
    pub icloud_sync: bool,
    /// `allowProtectedFolderAccess` (`[next] allow_protected_folder_access`):
    /// background repo detection may read Downloads, Desktop, Documents...
    pub allow_protected_folder_access: bool,
    /// `bugReport.contactName` (`[next] bug_report_contact_name`): remembered
    /// between reports by "Remember for future reports".
    pub bug_report_contact_name: String,
    /// `bugReport.contactHandle` (`[next] bug_report_contact_handle`).
    pub bug_report_contact_handle: String,
    /// `bugReport.issueEndpoint` (`[next] bug_report_issue_endpoint`): the
    /// HTTPS address reports are posted to. Empty: not configured.
    pub bug_report_issue_endpoint: String,
}

impl Default for GeneralSettings {
    fn default() -> Self {
        Self {
            default_directory: None,
            app_language: AppLanguage::System,
            regional_number_format: RegionalNumberFormat::default(),
            launch_at_login: false,
            load_config_files: true,
            icloud_sync: false,
            allow_protected_folder_access: true,
            bug_report_contact_name: String::new(),
            bug_report_contact_handle: String::new(),
            bug_report_issue_endpoint: String::new(),
        }
    }
}

impl GeneralSettings {
    /// The remembered report contact and endpoint, kept by "Reset to
    /// Defaults" (the Swift reset does not touch `bugReport.*`).
    pub fn remembered_bug_report_fields(&self) -> (String, String, String) {
        (
            self.bug_report_contact_name.clone(),
            self.bug_report_contact_handle.clone(),
            self.bug_report_issue_endpoint.clone(),
        )
    }

    pub fn restore_bug_report_fields(&mut self, fields: (String, String, String)) {
        (
            self.bug_report_contact_name,
            self.bug_report_contact_handle,
            self.bug_report_issue_endpoint,
        ) = fields;
    }
}

/// Undo `toml_string`: the raw config parser strips the quotes but keeps
/// the escapes.
fn toml_unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c == '\\'
            && let Some(next) = chars.clone().next()
            && (next == '\\' || next == '"')
        {
            out.push(next);
            chars.next();
        } else {
            out.push(c);
        }
    }
    out
}

/// A TOML basic string: backslashes and quotes escaped, line breaks flattened.
fn toml_string(value: &str) -> String {
    let flat = value.replace(['\n', '\r'], " ");
    let escaped = flat.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

impl SettingsDomain for GeneralSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(general) = &src.file.general {
            self.default_directory = general.default_directory.clone().filter(|s| !s.is_empty());
        }
        if let Some(language) = src
            .next("app_language")
            .and_then(RawValue::as_str)
            .and_then(AppLanguage::from_id)
        {
            self.app_language = language;
        }
        if let Some(format) = src
            .next("regional_number_format")
            .and_then(RawValue::as_str)
            .and_then(RegionalNumberFormat::from_id)
        {
            self.regional_number_format = format;
        }
        if let Some(v) = src.next("launch_at_login").and_then(RawValue::as_bool) {
            self.launch_at_login = v;
        }
        if let Some(v) = src.next("load_config_files").and_then(RawValue::as_bool) {
            self.load_config_files = v;
        }
        if let Some(v) = src.next("icloud_sync").and_then(RawValue::as_bool) {
            self.icloud_sync = v;
        }
        if let Some(v) = src
            .next("allow_protected_folder_access")
            .and_then(RawValue::as_bool)
        {
            self.allow_protected_folder_access = v;
        }
        for (key, field) in [
            ("bug_report_contact_name", &mut self.bug_report_contact_name),
            (
                "bug_report_contact_handle",
                &mut self.bug_report_contact_handle,
            ),
            (
                "bug_report_issue_endpoint",
                &mut self.bug_report_issue_endpoint,
            ),
        ] {
            if let Some(v) = src.next(key).and_then(RawValue::as_str) {
                *field = toml_unescape(v);
            }
        }
    }

    /// Edited in the Shell section of the settings window (SET-019).
    /// The default directory is edited in the Shell section (SET-019).
    fn save(&self, out: &mut ConfigSink) {
        let general = out.file.general.get_or_insert_with(Default::default);
        general.default_directory = Some(self.default_directory.clone().unwrap_or_default());
        out.set_next("app_language", format!("\"{}\"", self.app_language.id()));
        out.set_next(
            "regional_number_format",
            format!("\"{}\"", self.regional_number_format.id()),
        );
        out.set_next("launch_at_login", self.launch_at_login);
        out.set_next("load_config_files", self.load_config_files);
        out.set_next("icloud_sync", self.icloud_sync);
        out.set_next(
            "allow_protected_folder_access",
            self.allow_protected_folder_access,
        );
        out.set_next(
            "bug_report_contact_name",
            toml_string(&self.bug_report_contact_name),
        );
        out.set_next(
            "bug_report_contact_handle",
            toml_string(&self.bug_report_contact_handle),
        );
        out.set_next(
            "bug_report_issue_endpoint",
            toml_string(&self.bug_report_issue_endpoint),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn loads_default_directory() {
        let general: GeneralSettings = load_text("[general]\ndefault_directory = \"~/code\"\n");
        assert_eq!(general.default_directory.as_deref(), Some("~/code"));
        let empty: GeneralSettings = load_text("[general]\ndefault_directory = \"\"\n");
        assert_eq!(empty.default_directory, None);
    }

    #[test]
    fn round_trips() {
        assert_eq!(
            round_trip(&GeneralSettings::default()),
            GeneralSettings::default()
        );
        let changed = GeneralSettings {
            default_directory: None,
            app_language: AppLanguage::French,
            regional_number_format: RegionalNumberFormat::European,
            launch_at_login: true,
            load_config_files: false,
            icloud_sync: true,
            allow_protected_folder_access: false,
            bug_report_contact_name: "Ada \"A\" Lovelace".into(),
            bug_report_contact_handle: "ada@example.com".into(),
            bug_report_issue_endpoint: "https://issues.example.com/report".into(),
        };
        assert_eq!(round_trip(&changed), changed);
    }

    #[test]
    fn bug_report_fields_are_empty_by_default_and_survive_reset() {
        let mut d = GeneralSettings::default();
        assert!(d.bug_report_contact_name.is_empty());
        assert!(d.bug_report_contact_handle.is_empty());
        assert!(d.bug_report_issue_endpoint.is_empty());
        d.bug_report_contact_name = "Ada".into();
        let kept = d.remembered_bug_report_fields();
        d = GeneralSettings::default();
        d.restore_bug_report_fields(kept);
        assert_eq!(d.bug_report_contact_name, "Ada");
    }

    #[test]
    fn defaults_follow_swift() {
        let d = GeneralSettings::default();
        assert_eq!(d.app_language, AppLanguage::System);
        assert!(!d.launch_at_login);
        // `feature.configFile` defaults to on.
        assert!(d.load_config_files);
        assert!(!d.icloud_sync);
        assert!(d.allow_protected_folder_access);
    }

    #[test]
    fn number_format_defaults_and_persistence_match_swift() {
        assert_eq!(
            GeneralSettings::default().regional_number_format,
            RegionalNumberFormat::French
        );
        for format in RegionalNumberFormat::ALL {
            let settings = GeneralSettings {
                regional_number_format: format,
                ..Default::default()
            };
            assert_eq!(round_trip(&settings).regional_number_format, format);
        }
    }

    #[test]
    fn spanish_is_selectable_and_persisted() {
        assert!(AppLanguage::ALL.contains(&AppLanguage::Spanish));
        assert_eq!(AppLanguage::from_id("es"), Some(AppLanguage::Spanish));
        assert_eq!(AppLanguage::Spanish.display_name(), "Español");
        let settings = GeneralSettings {
            app_language: AppLanguage::Spanish,
            ..Default::default()
        };
        assert_eq!(round_trip(&settings).app_language, AppLanguage::Spanish);
    }

    #[test]
    fn ids_match_swift_raw_values() {
        assert_eq!(AppLanguage::French.id(), "fr");
        assert_eq!(AppLanguage::from_id("he"), Some(AppLanguage::Hebrew));
        assert_eq!(AppLanguage::from_id("de"), None);
        assert!(AppLanguage::Arabic.is_rtl() && !AppLanguage::French.is_rtl());
    }
}
