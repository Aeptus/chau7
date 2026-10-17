//! Snippets: loading, saving and inserting. The model and the storage rules
//! (`snippet_store` in `chau7_next_core`) are shared with the tests; this
//! file adds the settings, the clock, the clipboard and the git root.
//!
//! Sources, highest priority first: the focused tab's git repo
//! (`<git root>/<repo snippet path>/<id>.json`), Profile
//! (`~/.chau7-next/snippets/default/`) and User (`.../global/`). The Swift
//! app's folders are copied once at first launch (see `DataRoot`) and never
//! written. A repo's own snippet files are read only too: edits made in
//! Chau7 Next go to its per-repo overlay (`DataRoot::repo_overlays_dir`).

pub mod form;
pub mod manager;

use std::path::{Path, PathBuf};

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::snippet_store::{self, Insertion, SnippetEntry, SnippetPaths, TokenContext};
use gpui::{App, ClipboardItem};

use crate::settings::{ProductivitySettings, SnippetInsertMode};

/// Where each source lives, from the settings.
pub fn paths(root: &DataRoot, settings: &ProductivitySettings) -> SnippetPaths {
    SnippetPaths {
        global: root.user_snippets_dir(),
        profile: root.profile_snippets_dir(),
        repo_relative: settings.repo_snippet_path.clone(),
        overlays: root.repo_overlays_dir(),
    }
}

/// Split the single-file store of earlier Chau7 Next builds
/// (`~/.chau7-next/snippets.json`, a private file) into one file per snippet
/// and delete it. Runs at launch.
pub fn migrate_legacy_files(root: &DataRoot) {
    let migrated =
        snippet_store::migrate_legacy_file(&root.snippets_file(), &root.user_snippets_dir(), true);
    if migrated > 0 {
        crate::settings_window::invalidate_snippets(root);
        log::info!("snippets: split snippets.json into {migrated} files");
    }
}

/// The repo whose snippets show now: only when snippets and repo snippets
/// are on, and the repo is not in a protected folder (Downloads, Desktop,
/// Documents, ...) while "Allow Protected Folders" is off.
pub fn active_repo(settings: &ProductivitySettings, git_root: Option<&Path>) -> Option<PathBuf> {
    if !settings.snippets_enabled || !settings.repo_snippets_enabled {
        return None;
    }
    let root = git_root?;
    if crate::protected_paths::should_skip(root) {
        return None;
    }
    Some(root.to_path_buf())
}

/// All entries for the current settings and repo; empty when snippets are off.
pub fn load_entries(
    root: &DataRoot,
    settings: &ProductivitySettings,
    git_root: Option<&Path>,
) -> Vec<SnippetEntry> {
    if !settings.snippets_enabled {
        return Vec::new();
    }
    let paths = paths(root, settings);
    let repo = active_repo(settings, git_root);
    let repo_snippets = repo
        .as_deref()
        .map(|r| snippet_store::load_repo(&paths, r))
        .unwrap_or_default();
    snippet_store::merge_entries(
        &paths,
        snippet_store::load_dir(&paths.global),
        snippet_store::load_dir(&paths.profile),
        repo_snippets,
        repo.as_deref(),
    )
}

/// Text and tab stops to insert for a body typed in the tab at `cwd`.
pub fn prepare_insertion(
    body: &str,
    cwd: &str,
    root: &DataRoot,
    settings: &ProductivitySettings,
    cx: &App,
) -> Insertion {
    let clipboard = || {
        cx.read_from_clipboard()
            .and_then(|item: ClipboardItem| item.text())
            .unwrap_or_default()
    };
    let home = root.home().to_string_lossy().to_string();
    let ctx = TokenContext {
        cwd,
        home: &home,
        now: snippet_store::local_now(),
        clipboard: &clipboard,
    };
    let env = |key: &str| std::env::var(key).unwrap_or_default();
    snippet_store::prepare_insertion(
        body,
        &ctx,
        &env,
        settings.snippet_insert_mode == SnippetInsertMode::Paste,
        settings.snippet_placeholders,
    )
}

/// Save a form's draft: a new snippet, or an edit (which may move the file).
pub fn save_draft(
    root: &DataRoot,
    settings: &ProductivitySettings,
    entry: Option<&SnippetEntry>,
    draft: &snippet_store::SnippetDraft,
    active_repo: Option<&Path>,
) -> Result<(), String> {
    let paths = paths(root, settings);
    let now = snippet_store::now_utc();
    let result = match entry {
        Some(entry) => snippet_store::update_snippet(&paths, entry, draft, active_repo, now),
        None => snippet_store::create_snippet(&paths, draft, active_repo, now),
    }
    .map(|_| ())
    .map_err(|e| e.to_string());
    crate::settings_window::invalidate_snippets(root);
    result
}

pub fn delete_entry(root: &DataRoot, settings: &ProductivitySettings, entry: &SnippetEntry) {
    snippet_store::delete_snippet(&paths(root, settings), entry);
    crate::settings_window::invalidate_snippets(root);
}

pub fn toggle_pin(root: &DataRoot, settings: &ProductivitySettings, entry: &SnippetEntry) {
    if let Err(err) =
        snippet_store::toggle_pin(&paths(root, settings), entry, snippet_store::now_utc())
    {
        log::warn!("snippets: pin failed: {err}");
    }
    crate::settings_window::invalidate_snippets(root);
}

/// "Migrate Snippets to Clean JSON": rewrite every snippet file of Chau7
/// Next's own folders pretty-printed with sorted keys, ISO 8601 dates and
/// empty fields omitted. A repo's own files belong to the Swift app (which
/// migrates them) and are left alone; only Chau7 Next's overlay of each repo
/// is rewritten. Returns what was rewritten, like `user (3 snippets)`.
pub fn migrate_to_clean_json(
    root: &DataRoot,
    settings: &ProductivitySettings,
    repos: &[PathBuf],
) -> Vec<String> {
    migrate_legacy_files(root);
    let paths = paths(root, settings);
    let mut done = Vec::new();
    for (label, dir) in [
        ("global", paths.global.clone()),
        ("default", paths.profile.clone()),
    ] {
        let count = snippet_store::rewrite_clean(&dir);
        if count > 0 {
            done.push(format!("{label} ({count} snippets)"));
        }
    }
    for repo in repos {
        let dir = paths.repo_write_dir(repo);
        if !dir.exists() {
            continue;
        }
        let count = snippet_store::rewrite_clean(&dir);
        if count > 0 {
            let name = repo.file_name().map(|n| n.to_string_lossy().to_string());
            done.push(format!("repo:{} ({count})", name.unwrap_or_default()));
        }
    }
    crate::settings_window::invalidate_snippets(root);
    done
}

/// Ask the OS for access to the protected folders (a directory listing makes
/// macOS show its permission prompt). Returns the folders that could be read.
#[allow(dead_code)]
pub fn request_protected_folder_access(home: &Path) -> Vec<PathBuf> {
    ["Downloads", "Desktop", "Documents"]
        .into_iter()
        .map(|name| home.join(name))
        .filter(|dir| std::fs::read_dir(dir).is_ok())
        .collect()
}

/// System Settings page for Files and Folders permissions.
#[allow(dead_code)]
pub const FILES_AND_FOLDERS_SETTINGS_URL: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders";

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-snip-app-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn off_means_no_entries_and_no_repo() {
        let root = DataRoot::with_home(temp("off"), true);
        let mut s = ProductivitySettings {
            snippets_enabled: false,
            ..Default::default()
        };
        assert!(load_entries(&root, &s, None).is_empty());
        assert!(active_repo(&s, Some(Path::new("/r"))).is_none());
        s.snippets_enabled = true;
        s.repo_snippets_enabled = false;
        assert!(active_repo(&s, Some(Path::new("/r"))).is_none());
        let _ = std::fs::remove_dir_all(root.home());
    }

    #[test]
    fn legacy_user_file_is_split_and_removed() {
        let root = DataRoot::with_home(temp("legacy"), true);
        root.ensure_dirs().unwrap();
        std::fs::write(
            root.snippets_file(),
            r#"{"version":1,"snippets":[{"id":"a","title":"A","body":"ls"}]}"#,
        )
        .unwrap();
        migrate_legacy_files(&root);
        assert!(!root.snippets_file().exists());
        let entries = load_entries(&root, &ProductivitySettings::default(), None);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].snippet.id, "a");
        let _ = std::fs::remove_dir_all(root.home());
    }

    #[test]
    fn repo_layout_with_custom_path() {
        let root = DataRoot::with_home(temp("repo"), true);
        let repo = root.home().join("repo");
        let s = ProductivitySettings {
            repo_snippet_path: "tools/snips".into(),
            ..Default::default()
        };
        let p = paths(&root, &s);
        snippet_store::save_snippet(
            &p.repo_dir(&repo),
            &snippet_store::Snippet::new("r", "Repo one", "x"),
        )
        .unwrap();
        let entries = load_entries(&root, &s, Some(&repo));
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].source, snippet_store::SnippetSource::Repo);
        assert!(entries[0].source_path.ends_with("tools/snips/r.json"));
        // Clean JSON leaves the repo's own file alone.
        let file = p.repo_dir(&repo).join("r.json");
        std::fs::write(
            &file,
            r#"{"id":"r","title":"Repo one","body":"x","tags":[]}"#,
        )
        .unwrap();
        let before = std::fs::read(&file).unwrap();
        migrate_to_clean_json(&root, &s, std::slice::from_ref(&repo));
        assert_eq!(std::fs::read(&file).unwrap(), before);
        let _ = std::fs::remove_dir_all(root.home());
    }
}
