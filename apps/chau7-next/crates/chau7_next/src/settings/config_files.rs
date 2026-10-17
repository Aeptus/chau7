//! The config file as a living thing (`ConfigFileWatcher.swift`): reload
//! when it changes on disk, and a per-repo `.chau7/config.toml` that overrides
//! the global one for the directory of the active tab.
//!
//! `Settings` (the global the whole app reads) is the *effective* settings:
//! the global file plus the repo overrides. The settings window edits and
//! saves the *base* kept here, so repo overrides never leak into the global
//! file.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use gpui::{App, BorrowAppContext, Global};

use super::{GeneralSettings, Settings, SettingsDomain};
use chau7_next_core::config;
use chau7_next_core::data_root::repo_config_path;

/// What identifies a version of a file on disk: change time and size, or
/// `None` when it does not exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileStamp(Option<(SystemTime, u64)>);

impl FileStamp {
    pub fn of(path: &Path) -> FileStamp {
        FileStamp(
            std::fs::metadata(path)
                .ok()
                .map(|m| (m.modified().unwrap_or(SystemTime::UNIX_EPOCH), m.len())),
        )
    }
}

/// The base settings with the repo file's overrides on top. Like Swift, a
/// repo file only overrides the start directory, shell, font, color scheme,
/// cursor, scrollback and bell; its other keys are ignored.
pub fn with_repo_overrides(base: &Settings, repo_text: &str) -> Settings {
    let file = config::parse(repo_text);
    let mut raw = config::parse_raw(repo_text);
    // Keys only Chau7 Next reads (`[next]`) come from the global file only.
    raw.remove("next");
    let src = super::ConfigSource {
        file: &file,
        raw: &raw,
    };
    let mut effective = base.clone();
    // `load` applies only the keys the file has.
    effective.appearance.load(&src);
    effective.terminal.load(&src);
    let mut general = GeneralSettings::default();
    general.load(&src);
    if general.default_directory.is_some() {
        effective.general.default_directory = general.default_directory;
    }
    effective
}

/// Files being watched and the state shown in Settings > General.
pub struct ConfigFiles {
    /// The settings of the global file: what the settings window edits.
    pub base: Settings,
    /// Directory the repo config was resolved for (the active tab's).
    pub repo_directory: Option<PathBuf>,
    /// The repo file exists and overrides the global one.
    pub repo_active: bool,
    pub last_load: Option<SystemTime>,
    pub last_error: Option<String>,
    global_path: PathBuf,
    global_stamp: FileStamp,
    repo_stamp: FileStamp,
}

impl Global for ConfigFiles {}

impl ConfigFiles {
    pub fn new(global_path: PathBuf, base: Settings) -> Self {
        let global_stamp = FileStamp::of(&global_path);
        Self {
            base,
            repo_directory: None,
            repo_active: false,
            last_load: global_stamp.0.map(|_| SystemTime::now()),
            last_error: None,
            global_path,
            global_stamp,
            repo_stamp: FileStamp(None),
        }
    }

    pub fn global_path(&self) -> &Path {
        &self.global_path
    }

    /// The per-repo file for the resolved directory.
    pub fn repo_path(&self) -> Option<PathBuf> {
        self.repo_directory.as_deref().map(repo_config_path)
    }

    /// The effective settings: base plus the repo file.
    pub fn effective(&mut self) -> Settings {
        self.repo_active = false;
        self.repo_stamp = FileStamp(None);
        if self.base.general.load_config_files
            && let Some(path) = self.repo_path()
        {
            self.repo_stamp = FileStamp::of(&path);
            if let Ok(text) = std::fs::read_to_string(&path) {
                self.repo_active = true;
                return with_repo_overrides(&self.base, &text);
            }
        }
        self.base.clone()
    }

    /// Note that the app wrote the global file itself, so the watcher does
    /// not take it for an outside change.
    pub fn saved(&mut self) {
        self.global_stamp = FileStamp::of(&self.global_path);
    }
}

/// Install the config state at launch; `base` is what was loaded from disk.
pub fn init(cx: &mut App, path: PathBuf, base: Settings) {
    crate::protected_paths::set_allowed(base.general.allow_protected_folder_access);
    cx.set_global(ConfigFiles::new(path, base));
}

/// Recompute the effective settings and give them to the app.
pub fn apply(cx: &mut App) {
    let effective = cx.update_global(|files: &mut ConfigFiles, _| files.effective());
    crate::protected_paths::set_allowed(effective.general.allow_protected_folder_access);
    cx.set_global(effective);
    crate::l10n::settings_applied(cx);
    crate::apply_theme(cx);
    crate::history::apply_settings(cx);
    crate::cto::settings_applied(cx);
    for (_, ws) in crate::workspace::AppData::live(cx) {
        ws.update(cx, |ws, cx| ws.reload_settings(cx));
    }
    cx.refresh_windows();
}

/// Read the global file again (Reload Settings, or it changed on disk).
pub fn reload(cx: &mut App) {
    let root = cx.global::<crate::workspace::AppData>().root.clone();
    let base = Settings::load(&root);
    cx.update_global(|files: &mut ConfigFiles, _| {
        files.base = base;
        files.global_stamp = FileStamp::of(&files.global_path);
        files.last_load = Some(SystemTime::now());
        files.last_error = None;
    });
    apply(cx);
    let input = Settings::get(cx).input.clone();
    crate::actions::bind_shortcut_settings(&input, cx);
}

/// Called about once a second: reload when the global file changed, and
/// resolve the repo file for `active_directory`.
pub fn tick(cx: &mut App, active_directory: Option<PathBuf>) {
    let Some(files) = cx.try_global::<ConfigFiles>() else {
        return;
    };
    if !files.base.general.load_config_files {
        if files.repo_active {
            apply(cx);
        }
        return;
    }
    if FileStamp::of(&files.global_path) != files.global_stamp {
        log::info!("config file changed on disk: reloading");
        reload(cx);
        return;
    }
    let repo_stamp = active_directory
        .as_deref()
        .map(|d| FileStamp::of(&repo_config_path(d)))
        .unwrap_or(FileStamp(None));
    if active_directory != files.repo_directory || repo_stamp != files.repo_stamp {
        cx.update_global(|files: &mut ConfigFiles, _| files.repo_directory = active_directory);
        apply(cx);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_file_overrides_only_the_swift_keys() {
        let base = Settings::default();
        let text = "[appearance]\nfont_size = 17\ncursor_style = \"bar\"\n\n\
                    [terminal]\nscrollback_lines = 777\n\n\
                    [general]\ndefault_directory = \"/repo\"\n\n\
                    [next]\napp_theme = \"dark\"\nlaunch_at_login = true\n";
        let effective = with_repo_overrides(&base, text);
        assert_eq!(effective.appearance.font_size, 17.0);
        assert_eq!(effective.terminal.scrollback_lines, 777);
        assert_eq!(
            effective.general.default_directory.as_deref(),
            Some("/repo")
        );
        // `[next]` keys of a repo file do nothing.
        assert_eq!(effective.appearance.app_theme, base.appearance.app_theme);
        assert!(!effective.general.launch_at_login);
        // Keys the file lacks keep the base.
        assert_eq!(
            effective.appearance.font_family,
            base.appearance.font_family
        );
    }

    #[test]
    fn empty_repo_file_changes_nothing() {
        let base = Settings::default();
        assert_eq!(with_repo_overrides(&base, ""), base);
    }

    #[test]
    fn stamps_see_changes_and_absence() {
        let dir = std::env::temp_dir().join(format!("chau7-stamp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("config.toml");
        assert_eq!(FileStamp::of(&file), FileStamp(None));
        std::fs::write(&file, "a").unwrap();
        let first = FileStamp::of(&file);
        assert_ne!(first, FileStamp(None));
        std::fs::write(&file, "abc").unwrap();
        assert_ne!(FileStamp::of(&file), first);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn repo_path_is_inside_the_directory() {
        let path = repo_config_path(Path::new("/work/app"));
        assert!(path.starts_with("/work/app"));
        assert!(path.ends_with("config.toml"));
    }
}
