//! Productivity (`ProductivitySettingsView.swift`) and the link settings of
//! `InputSettingsView.swift`: snippets, clipboard history, bookmarks, search
//! defaults, Cmd-click paths and URLs.
//!
//! Swift keeps these in UserDefaults (`feature.*`), not in `config.toml`, so
//! every key lives under `[next]`.

use chau7_next_core::config::RawValue;
use chau7_next_core::snippet_store::DEFAULT_REPO_SNIPPET_PATH;

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// `feature.snippetInsertMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnippetInsertMode {
    /// "Expand (type)": placeholders become Tab stops.
    Expand,
    /// "Paste": the text goes in as written, without Tab stops.
    Paste,
}

impl SnippetInsertMode {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Expand => "expand",
            Self::Paste => "paste",
        }
    }
}

/// `feature.urlHandler`: the browser a Cmd-clicked URL opens in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UrlHandler {
    System,
    Safari,
    Chrome,
    Firefox,
    Edge,
    Brave,
    Arc,
}

impl UrlHandler {
    pub const ALL: [UrlHandler; 7] = [
        Self::System,
        Self::Safari,
        Self::Chrome,
        Self::Firefox,
        Self::Edge,
        Self::Brave,
        Self::Arc,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Safari => "safari",
            Self::Chrome => "chrome",
            Self::Firefox => "firefox",
            Self::Edge => "edge",
            Self::Brave => "brave",
            Self::Arc => "arc",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|h| h.raw() == raw)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::System => "System Default",
            Self::Safari => "Safari",
            Self::Chrome => "Google Chrome",
            Self::Firefox => "Firefox",
            Self::Edge => "Microsoft Edge",
            Self::Brave => "Brave",
            Self::Arc => "Arc",
        }
    }

    /// macOS bundle identifier; `None` means the system default browser.
    pub fn bundle_identifier(self) -> Option<&'static str> {
        match self {
            Self::System => None,
            Self::Safari => Some("com.apple.Safari"),
            Self::Chrome => Some("com.google.Chrome"),
            Self::Firefox => Some("org.mozilla.firefox"),
            Self::Edge => Some("com.microsoft.edgemac"),
            Self::Brave => Some("com.brave.Browser"),
            Self::Arc => Some("company.thebrowser.Browser"),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProductivitySettings {
    /// `feature.snippetsEnabled`.
    pub snippets_enabled: bool,
    /// `feature.repoSnippetsEnabled`.
    pub repo_snippets_enabled: bool,
    /// `feature.repoSnippetPath`, relative to the git root.
    pub repo_snippet_path: String,
    /// `feature.snippetInsertMode`.
    pub snippet_insert_mode: SnippetInsertMode,
    /// `feature.snippetPlaceholders`.
    pub snippet_placeholders: bool,
    /// `feature.clipboardHistory`.
    pub clipboard_history_enabled: bool,
    /// `feature.clipboardHistoryMax`, 1 to 1000.
    pub clipboard_history_max: usize,
    /// `feature.bookmarksEnabled`.
    pub bookmarks_enabled: bool,
    /// `feature.maxBookmarks`, 1 to 200.
    pub max_bookmarks_per_tab: usize,
    /// `feature.semanticSearch`.
    pub semantic_search: bool,
    /// `search.defaultCaseSensitive`.
    pub find_case_sensitive: bool,
    /// `search.defaultRegex`.
    pub find_regex: bool,
    /// `feature.cmdClickPaths`: Cmd-click opens paths and URLs.
    pub cmd_click_paths: bool,
    /// `feature.cmdClickOpensInternalEditor`.
    pub cmd_click_internal_editor: bool,
    /// `feature.defaultEditor`; empty means `$EDITOR`, then the system default.
    pub default_editor: String,
    /// `feature.urlHandler`.
    pub url_handler: UrlHandler,
}

impl Default for ProductivitySettings {
    fn default() -> Self {
        Self {
            snippets_enabled: true,
            repo_snippets_enabled: true,
            repo_snippet_path: DEFAULT_REPO_SNIPPET_PATH.to_string(),
            snippet_insert_mode: SnippetInsertMode::Expand,
            snippet_placeholders: true,
            clipboard_history_enabled: true,
            clipboard_history_max: 50,
            bookmarks_enabled: true,
            max_bookmarks_per_tab: 20,
            semantic_search: false,
            find_case_sensitive: false,
            find_regex: false,
            cmd_click_paths: true,
            cmd_click_internal_editor: true,
            default_editor: String::new(),
            url_handler: UrlHandler::System,
        }
    }
}

impl ProductivitySettings {
    /// Entries Clipboard History keeps; 0 when it is off.
    pub fn clipboard_limit(&self) -> usize {
        if self.clipboard_history_enabled {
            self.clipboard_history_max
        } else {
            0
        }
    }
}

fn load_bool(src: &ConfigSource, key: &str, target: &mut bool) {
    if let Some(v) = src.next(key).and_then(RawValue::as_bool) {
        *target = v;
    }
}

fn load_string(src: &ConfigSource, key: &str) -> Option<String> {
    match src.next(key)? {
        RawValue::String(s) => Some(s.clone()),
        RawValue::Int(i) => Some(i.to_string()),
        RawValue::Double(d) => Some(d.to_string()),
        RawValue::Bool(b) => Some(b.to_string()),
    }
}

impl SettingsDomain for ProductivitySettings {
    fn load(&mut self, src: &ConfigSource) {
        load_bool(src, "snippets_enabled", &mut self.snippets_enabled);
        load_bool(
            src,
            "repo_snippets_enabled",
            &mut self.repo_snippets_enabled,
        );
        if let Some(path) = load_string(src, "repo_snippet_path") {
            self.repo_snippet_path = path.trim().to_string();
        }
        if let Some(mode) = load_string(src, "snippet_insert_mode") {
            self.snippet_insert_mode = if mode == "paste" {
                SnippetInsertMode::Paste
            } else {
                SnippetInsertMode::Expand
            };
        }
        load_bool(src, "snippet_placeholders", &mut self.snippet_placeholders);
        load_bool(
            src,
            "clipboard_history_enabled",
            &mut self.clipboard_history_enabled,
        );
        if let Some(v) = src.next("clipboard_history_max").and_then(RawValue::as_int) {
            if v == 0 {
                // Older files used 0 for "off".
                self.clipboard_history_enabled = false;
            } else {
                self.clipboard_history_max = v.clamp(1, 1000) as usize;
            }
        }
        load_bool(src, "bookmarks_enabled", &mut self.bookmarks_enabled);
        if let Some(v) = src.next("max_bookmarks").and_then(RawValue::as_int) {
            self.max_bookmarks_per_tab = v.clamp(1, 200) as usize;
        }
        load_bool(src, "semantic_search", &mut self.semantic_search);
        load_bool(src, "find_case_sensitive", &mut self.find_case_sensitive);
        load_bool(src, "find_regex", &mut self.find_regex);
        load_bool(src, "cmd_click_paths", &mut self.cmd_click_paths);
        load_bool(
            src,
            "cmd_click_internal_editor",
            &mut self.cmd_click_internal_editor,
        );
        if let Some(editor) = load_string(src, "default_editor") {
            self.default_editor = editor.trim().to_string();
        }
        if let Some(handler) =
            load_string(src, "url_handler").and_then(|h| UrlHandler::from_raw(&h))
        {
            self.url_handler = handler;
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next("snippets_enabled", self.snippets_enabled);
        out.set_next("repo_snippets_enabled", self.repo_snippets_enabled);
        out.set_next(
            "repo_snippet_path",
            format!("\"{}\"", self.repo_snippet_path),
        );
        out.set_next(
            "snippet_insert_mode",
            format!("\"{}\"", self.snippet_insert_mode.raw()),
        );
        out.set_next("snippet_placeholders", self.snippet_placeholders);
        out.set_next("clipboard_history_enabled", self.clipboard_history_enabled);
        out.set_next("clipboard_history_max", self.clipboard_history_max);
        out.set_next("bookmarks_enabled", self.bookmarks_enabled);
        out.set_next("max_bookmarks", self.max_bookmarks_per_tab);
        out.set_next("semantic_search", self.semantic_search);
        out.set_next("find_case_sensitive", self.find_case_sensitive);
        out.set_next("find_regex", self.find_regex);
        out.set_next("cmd_click_paths", self.cmd_click_paths);
        out.set_next("cmd_click_internal_editor", self.cmd_click_internal_editor);
        out.set_next("default_editor", format!("\"{}\"", self.default_editor));
        out.set_next("url_handler", format!("\"{}\"", self.url_handler.raw()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn defaults_follow_swift() {
        let p = ProductivitySettings::default();
        assert!(p.snippets_enabled && p.repo_snippets_enabled);
        assert_eq!(p.repo_snippet_path, DEFAULT_REPO_SNIPPET_PATH);
        assert_eq!(p.snippet_insert_mode, SnippetInsertMode::Expand);
        assert!(p.snippet_placeholders);
        assert_eq!((p.clipboard_history_max, p.max_bookmarks_per_tab), (50, 20));
        assert!(!p.semantic_search && !p.find_case_sensitive && !p.find_regex);
        assert!(p.cmd_click_paths && p.cmd_click_internal_editor);
        assert!(p.default_editor.is_empty());
        assert_eq!(p.url_handler, UrlHandler::System);
    }

    #[test]
    fn round_trips() {
        let p = ProductivitySettings {
            snippets_enabled: false,
            repo_snippets_enabled: false,
            repo_snippet_path: "tools/snips".into(),
            snippet_insert_mode: SnippetInsertMode::Paste,
            snippet_placeholders: false,
            clipboard_history_enabled: false,
            clipboard_history_max: 700,
            bookmarks_enabled: false,
            max_bookmarks_per_tab: 99,
            semantic_search: true,
            find_case_sensitive: true,
            find_regex: true,
            cmd_click_paths: false,
            cmd_click_internal_editor: false,
            default_editor: "/usr/local/bin/code".into(),
            url_handler: UrlHandler::Arc,
        };
        assert_eq!(round_trip(&p), p);
    }

    #[test]
    fn clamps_sizes() {
        let p: ProductivitySettings =
            load_text("[next]\nclipboard_history_max = 9000\nmax_bookmarks = 0\n");
        assert_eq!(p.clipboard_history_max, 1000);
        assert_eq!(p.max_bookmarks_per_tab, 1);
    }

    #[test]
    fn old_zero_clipboard_size_means_off() {
        let p: ProductivitySettings = load_text("[next]\nclipboard_history_max = 0\n");
        assert!(!p.clipboard_history_enabled);
        assert_eq!(p.clipboard_limit(), 0);
        assert_eq!(ProductivitySettings::default().clipboard_limit(), 50);
    }

    #[test]
    fn url_handlers_have_bundle_ids() {
        assert_eq!(UrlHandler::System.bundle_identifier(), None);
        assert_eq!(
            UrlHandler::Chrome.bundle_identifier(),
            Some("com.google.Chrome")
        );
        assert_eq!(UrlHandler::from_raw("brave"), Some(UrlHandler::Brave));
        assert_eq!(UrlHandler::from_raw("nope"), None);
    }
}
