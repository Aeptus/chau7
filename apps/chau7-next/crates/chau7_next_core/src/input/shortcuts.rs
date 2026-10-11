//! Custom keyboard shortcuts: the default list, the Vim and Emacs presets,
//! conflicts, display strings and JSON export.
//!
//! Ports `KeyboardShortcut` (`Settings/FeatureSettings.swift`) and the parts
//! of `Settings/KeybindingsManager.swift` that are plain logic
//! (`KeyAction` names, `fromShortcutAction`, `KeyBinding.parse`).
//!
//! Two naming schemes exist in Swift: shortcut actions as stored (`find`,
//! `snippets`, `clear`, ...) and `KeyAction` raw values (`toggleSearch`,
//! `showSnippets`, ...). [`canonical_action`] accepts both.

use serde::{Deserialize, Serialize};

/// One shortcut: an action name with its key and modifiers
/// (`"cmd"`, `"shift"`, `"ctrl"`, `"opt"`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyboardShortcut {
    pub action: String,
    pub key: String,
    pub modifiers: Vec<String>,
}

impl KeyboardShortcut {
    pub fn new(action: &str, key: &str, modifiers: &[&str]) -> Self {
        Self {
            action: action.to_string(),
            key: key.to_string(),
            modifiers: modifiers.iter().map(|m| m.to_string()).collect(),
        }
    }

    fn has(&self, modifier: &str) -> bool {
        self.modifiers.iter().any(|m| m == modifier)
    }

    /// "⌃⌥⇧⌘K", as in the Swift settings.
    pub fn display_string(&self) -> String {
        let mut out = String::new();
        for (name, symbol) in [("ctrl", "⌃"), ("opt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")] {
            if self.has(name) {
                out.push_str(symbol);
            }
        }
        out.push_str(&display_key(&self.key));
        out
    }

    /// Config file form: "ctrl+opt+shift+cmd+k".
    pub fn config_keys(&self) -> String {
        let mut parts: Vec<String> = ["ctrl", "opt", "shift", "cmd"]
            .iter()
            .filter(|m| self.has(m))
            .map(|m| m.to_string())
            .collect();
        parts.push(self.key.to_lowercase());
        parts.join("+")
    }

    /// Same key and the same set of modifiers.
    pub fn same_keys(&self, other: &Self) -> bool {
        let mut a = normalized_modifiers(&self.modifiers);
        let mut b = normalized_modifiers(&other.modifiers);
        a.sort();
        b.sort();
        self.key.eq_ignore_ascii_case(&other.key) && a == b
    }
}

fn display_key(key: &str) -> String {
    match key {
        "up" => "↑".into(),
        "down" => "↓".into(),
        "left" => "←".into(),
        "right" => "→".into(),
        other => other.to_uppercase(),
    }
}

fn normalized_modifiers(modifiers: &[String]) -> Vec<String> {
    modifiers
        .iter()
        .filter_map(|m| normalize_modifier(m))
        .map(str::to_string)
        .collect()
}

fn normalize_modifier(part: &str) -> Option<&'static str> {
    Some(match part.trim().to_lowercase().as_str() {
        "ctrl" | "control" => "ctrl",
        "cmd" | "command" => "cmd",
        "opt" | "option" | "alt" => "opt",
        "shift" => "shift",
        _ => return None,
    })
}

/// Parse "cmd+shift+t" (config format) into key and modifiers (Swift
/// `KeyBinding.parse`). `None` without a key.
pub fn parse_keys(keys: &str, action: &str) -> Option<KeyboardShortcut> {
    let mut modifiers = Vec::new();
    let mut key = None;
    for part in keys.to_lowercase().split('+') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        match normalize_modifier(part) {
            Some(m) => modifiers.push(m.to_string()),
            None => key = Some(part.to_string()),
        }
    }
    Some(KeyboardShortcut {
        action: action.to_string(),
        key: key?,
        modifiers,
    })
}

/// `FeatureSettings.defaultShortcuts`.
pub fn default_shortcuts() -> Vec<KeyboardShortcut> {
    use KeyboardShortcut as S;
    vec![
        S::new("newTab", "t", &["cmd"]),
        S::new("closeTab", "w", &["cmd"]),
        S::new("find", "f", &["cmd"]),
        S::new("findNext", "g", &["cmd"]),
        S::new("copy", "c", &["cmd"]),
        S::new("paste", "v", &["cmd"]),
        S::new("newWindow", "n", &["cmd"]),
        S::new("zoomIn", "=", &["cmd"]),
        S::new("zoomOut", "-", &["cmd"]),
        S::new("zoomReset", "0", &["cmd"]),
        S::new("nextTab", "]", &["cmd", "shift"]),
        S::new("previousTab", "[", &["cmd", "shift"]),
        S::new("findPrevious", "g", &["cmd", "shift"]),
        S::new("clear", "k", &["cmd", "opt"]),
        S::new("snippets", "s", &["cmd", "opt"]),
        S::new("renameTab", "r", &["cmd", "opt"]),
        S::new("debugConsole", "l", &["cmd", "opt"]),
        S::new("splitHorizontal", "d", &["cmd"]),
        S::new("splitVertical", "d", &["cmd", "opt"]),
        S::new("openTextEditor", "e", &["cmd", "opt"]),
        S::new("previousInputLine", "up", &["cmd"]),
        S::new("nextInputLine", "down", &["cmd"]),
        S::new("refreshTabBar", "r", &["cmd", "opt", "shift"]),
    ]
}

/// Preset names (`KeybindingsManager.availablePresets`).
pub const PRESETS: [&str; 3] = ["default", "vim", "emacs"];

/// `KeyboardShortcut.shortcuts(for:)`: Vim uses Ctrl+L / Ctrl+H for next and
/// previous tab, Emacs Ctrl+N / Ctrl+P; anything else is the default list.
pub fn shortcuts_for_preset(preset: &str) -> Vec<KeyboardShortcut> {
    let (next, previous) = match preset {
        "vim" => ("l", "h"),
        "emacs" => ("n", "p"),
        _ => return default_shortcuts(),
    };
    default_shortcuts()
        .into_iter()
        .map(|s| match s.action.as_str() {
            "nextTab" => KeyboardShortcut::new("nextTab", next, &["ctrl"]),
            "previousTab" => KeyboardShortcut::new("previousTab", previous, &["ctrl"]),
            _ => s,
        })
        .collect()
}

/// Other shortcuts using the same keys (`FeatureSettings.shortcutConflicts`).
pub fn conflicts<'a>(
    list: &'a [KeyboardShortcut],
    shortcut: &KeyboardShortcut,
) -> Vec<&'a KeyboardShortcut> {
    list.iter()
        .filter(|s| s.action != shortcut.action && s.same_keys(shortcut))
        .collect()
}

/// Replace the shortcut of the same action (`FeatureSettings.updateShortcut`;
/// `find` and `toggleSearch` name the same action); an action not in the
/// list is added.
pub fn update(list: &mut Vec<KeyboardShortcut>, shortcut: KeyboardShortcut) {
    let wanted = canonical_action(&shortcut.action);
    match list
        .iter_mut()
        .find(|s| canonical_action(&s.action) == wanted)
    {
        Some(existing) => *existing = shortcut,
        None => list.push(shortcut),
    }
}

/// The preset's list with the user's `[keybindings]` entries (keys, action)
/// applied: an action already listed gets the new keys, others are added.
pub fn effective_shortcuts(preset: &str, custom: &[(String, String)]) -> Vec<KeyboardShortcut> {
    let mut list = shortcuts_for_preset(preset);
    for (keys, action) in custom {
        if let Some(shortcut) = parse_keys(keys, action) {
            update(&mut list, shortcut);
        }
    }
    list
}

/// Shortcuts of `list` that the built-in default list does not already have
/// (what has to be bound on top of the default key map).
pub fn changed_from_defaults(list: &[KeyboardShortcut]) -> Vec<KeyboardShortcut> {
    let defaults = default_shortcuts();
    list.iter()
        .filter(|s| {
            !defaults.iter().any(|d| {
                canonical_action(&d.action) == canonical_action(&s.action) && d.same_keys(s)
            })
        })
        .cloned()
        .collect()
}

/// `[keybindings]` entries to write for `list`: one per shortcut that differs
/// from the preset.
pub fn config_entries(preset: &str, list: &[KeyboardShortcut]) -> Vec<(String, String)> {
    let base = shortcuts_for_preset(preset);
    list.iter()
        .filter(|s| {
            !base.iter().any(|b| {
                canonical_action(&b.action) == canonical_action(&s.action) && b.same_keys(s)
            })
        })
        .map(|s| (s.config_keys(), s.action.clone()))
        .collect()
}

/// Export as JSON (`FeatureSettings.exportKeybindings`).
pub fn export_json(list: &[KeyboardShortcut]) -> String {
    serde_json::to_string_pretty(list).unwrap_or_else(|_| "[]".into())
}

/// Import from JSON (`FeatureSettings.importKeybindings`); `None` when invalid.
pub fn import_json(text: &str) -> Option<Vec<KeyboardShortcut>> {
    serde_json::from_str(text).ok()
}

/// Map a Swift shortcut action name to the `KeyAction` raw value
/// (`KeyAction.fromShortcutAction`). Raw values map to themselves.
pub fn canonical_action(name: &str) -> &str {
    match name {
        "find" => "toggleSearch",
        "findNext" => "nextMatch",
        "findPrevious" => "previousMatch",
        "snippets" => "showSnippets",
        other => other,
    }
}

/// `KeyAction` raw values, in Swift order.
pub const KEY_ACTIONS: &[&str] = &[
    "newTab",
    "closeTab",
    "reopenClosedTab",
    "nextTab",
    "previousTab",
    "refreshTabBar",
    "selectTab1",
    "selectTab2",
    "selectTab3",
    "selectTab4",
    "selectTab5",
    "selectTab6",
    "selectTab7",
    "selectTab8",
    "selectTab9",
    "copy",
    "paste",
    "selectAll",
    "clear",
    "toggleSearch",
    "nextMatch",
    "previousMatch",
    "zoomIn",
    "zoomOut",
    "zoomReset",
    "toggleFullscreen",
    "interrupt",
    "eof",
    "suspend",
    "clearLine",
    "clearWord",
    "toggleBroadcast",
    "showClipboardHistory",
    "showBookmarks",
    "addBookmark",
    "showSnippets",
    "renameTab",
    "debugConsole",
    "splitHorizontal",
    "splitVertical",
    "openTextEditor",
    "showChangedFiles",
    "previousInputLine",
    "nextInputLine",
    "closeWindow",
    "newWindow",
];

/// Bytes sent by the terminal-signal actions (`KeybindingsManager.executeAction`).
pub fn control_action_bytes(action: &str) -> Option<&'static [u8]> {
    Some(match action {
        "interrupt" => b"\x03",
        "eof" => b"\x04",
        "suspend" => b"\x1a",
        "clearLine" => b"\x15",
        "clearWord" => b"\x17",
        _ => return None,
    })
}

/// Display name for a shortcut action (`KeyboardShortcut.actionDisplayName`,
/// then `KeyAction.displayName`); unknown names are returned as is.
pub fn action_display_name(action: &str) -> String {
    let name = match action {
        "newTab" => "New Tab",
        "closeTab" => "Close Tab",
        "nextTab" => "Next Tab",
        "previousTab" => "Previous Tab",
        "find" | "toggleSearch" => "Find",
        "findNext" | "nextMatch" => "Find Next",
        "findPrevious" | "previousMatch" => "Find Previous",
        "copy" => "Copy",
        "paste" => "Paste",
        "clear" => "Clear Scrollback",
        "zoomIn" => "Zoom In",
        "zoomOut" => "Zoom Out",
        "zoomReset" => "Reset Zoom",
        "snippets" | "showSnippets" => "Open Snippets",
        "renameTab" => "Rename Tab",
        "debugConsole" => "Debug Console",
        "newWindow" => "New Window",
        "splitHorizontal" => "Split Horizontal",
        "splitVertical" => "Split Vertical",
        "openTextEditor" => "Open Text Editor",
        "reopenClosedTab" => "Reopen Closed Tab",
        "refreshTabBar" => "Refresh Tab Bar",
        "selectAll" => "Select All",
        "toggleFullscreen" => "Toggle Fullscreen",
        "interrupt" => "Interrupt (SIGINT)",
        "eof" => "End of File",
        "suspend" => "Suspend",
        "clearLine" => "Clear Line",
        "clearWord" => "Clear Word",
        "toggleBroadcast" => "Toggle Broadcast",
        "showClipboardHistory" => "Clipboard History",
        "showBookmarks" => "Bookmarks",
        "addBookmark" => "Add Bookmark",
        "showChangedFiles" => "Show Changed Files",
        "previousInputLine" => "Previous Input Line",
        "nextInputLine" => "Next Input Line",
        "closeWindow" => "Close Window",
        other => {
            if let Some(n) = other.strip_prefix("selectTab") {
                return format!("Select Tab {n}");
            }
            return other.to_string();
        }
    };
    name.to_string()
}

/// Groups of the Keyboard Shortcuts window (`KeyboardShortcutsEditorView`).
pub const EDITOR_GROUPS: &[(&str, &[&str])] = &[
    (
        "Tabs",
        &["newTab", "closeTab", "nextTab", "previousTab", "renameTab"],
    ),
    (
        "Edit",
        &[
            "copy",
            "paste",
            "find",
            "findNext",
            "findPrevious",
            "snippets",
        ],
    ),
    ("View", &["zoomIn", "zoomOut", "zoomReset", "clear"]),
    (
        "Window",
        &[
            "newWindow",
            "splitHorizontal",
            "splitVertical",
            "openTextEditor",
            "debugConsole",
        ],
    ),
];

/// Shortcuts matching a search (action name or display name).
pub fn filter<'a>(list: &'a [KeyboardShortcut], query: &str) -> Vec<&'a KeyboardShortcut> {
    let query = query.trim().to_lowercase();
    list.iter()
        .filter(|s| {
            query.is_empty()
                || s.action.to_lowercase().contains(&query)
                || action_display_name(&s.action)
                    .to_lowercase()
                    .contains(&query)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Ports of `KeybindingsManagerTests` and `FeatureSettingsTests`.

    #[test]
    fn presets_are_listed() {
        assert_eq!(PRESETS, ["default", "vim", "emacs"]);
    }

    #[test]
    fn parse_simple_and_aliases() {
        let s = parse_keys("cmd+c", "copy").unwrap();
        assert_eq!(s.key, "c");
        assert_eq!(s.modifiers, vec!["cmd"]);
        let s = parse_keys("Command+Shift+Control+Option+T", "x").unwrap();
        assert_eq!(s.key, "t");
        assert_eq!(s.modifiers, vec!["cmd", "shift", "ctrl", "opt"]);
        assert_eq!(parse_keys("alt+b", "x").unwrap().modifiers, vec!["opt"]);
        assert!(parse_keys("", "x").is_none());
        assert!(parse_keys("cmd+shift", "x").is_none());
    }

    #[test]
    fn from_shortcut_action() {
        assert_eq!(canonical_action("newTab"), "newTab");
        assert_eq!(canonical_action("find"), "toggleSearch");
        assert_eq!(canonical_action("findNext"), "nextMatch");
        assert_eq!(canonical_action("findPrevious"), "previousMatch");
        assert_eq!(canonical_action("splitHorizontal"), "splitHorizontal");
        assert_eq!(canonical_action("snippets"), "showSnippets");
    }

    #[test]
    fn display_strings() {
        assert_eq!(
            KeyboardShortcut::new("newTab", "t", &["cmd"]).display_string(),
            "⌘T"
        );
        assert_eq!(
            KeyboardShortcut::new("x", "r", &["cmd", "opt", "shift"]).display_string(),
            "⌥⇧⌘R"
        );
        assert_eq!(action_display_name("newTab"), "New Tab");
        assert_eq!(action_display_name("unknownAction"), "unknownAction");
        assert_eq!(action_display_name("selectTab3"), "Select Tab 3");
    }

    #[test]
    fn default_shortcuts_contain_basics() {
        let list = default_shortcuts();
        assert!(!list.is_empty());
        for action in ["newTab", "closeTab", "copy", "paste", "find", "zoomIn"] {
            assert!(list.iter().any(|s| s.action == action), "{action}");
        }
    }

    #[test]
    fn vim_and_emacs_presets() {
        let vim = shortcuts_for_preset("vim");
        let next = vim.iter().find(|s| s.action == "nextTab").unwrap();
        assert_eq!(
            (next.key.as_str(), next.modifiers.clone()),
            ("l", vec!["ctrl".into()])
        );
        let prev = vim.iter().find(|s| s.action == "previousTab").unwrap();
        assert_eq!(prev.key, "h");
        let emacs = shortcuts_for_preset("emacs");
        assert_eq!(
            emacs.iter().find(|s| s.action == "nextTab").unwrap().key,
            "n"
        );
        assert_eq!(
            emacs
                .iter()
                .find(|s| s.action == "previousTab")
                .unwrap()
                .key,
            "p"
        );
        assert_eq!(shortcuts_for_preset("bogus"), default_shortcuts());
    }

    #[test]
    fn conflict_detection() {
        let list = default_shortcuts();
        let probe = KeyboardShortcut {
            action: "testConflict".into(),
            ..list[0].clone()
        };
        assert!(
            conflicts(&list, &probe)
                .iter()
                .any(|s| s.action == list[0].action)
        );
        // Modifier order does not matter.
        let a = KeyboardShortcut::new("a", "k", &["opt", "cmd"]);
        assert_eq!(conflicts(&list, &a)[0].action, "clear");
    }

    #[test]
    fn effective_and_config_round_trip() {
        let custom = vec![
            ("cmd+shift+n".to_string(), "newTab".to_string()),
            ("cmd+b".to_string(), "toggleBroadcast".to_string()),
            ("cmd+opt+f".to_string(), "find".to_string()),
        ];
        let list = effective_shortcuts("vim", &custom);
        let new_tab = list.iter().find(|s| s.action == "newTab").unwrap();
        assert_eq!(new_tab.config_keys(), "shift+cmd+n");
        assert!(list.iter().any(|s| s.action == "toggleBroadcast"));
        let changed = changed_from_defaults(&list);
        assert!(changed.iter().any(|s| s.action == "nextTab"));
        assert!(!changed.iter().any(|s| s.action == "closeTab"));
        let entries = config_entries("vim", &list);
        assert_eq!(entries.len(), 3);
        assert!(entries.contains(&("cmd+b".to_string(), "toggleBroadcast".to_string())));
    }

    #[test]
    fn json_export_import() {
        let list = default_shortcuts();
        let json = export_json(&list);
        assert!(json.contains("\"action\""));
        assert_eq!(import_json(&json).unwrap(), list);
        assert!(import_json("nope").is_none());
    }

    #[test]
    fn control_actions_and_filter() {
        assert_eq!(control_action_bytes("interrupt"), Some(&b"\x03"[..]));
        assert_eq!(control_action_bytes("clearWord"), Some(&b"\x17"[..]));
        assert_eq!(control_action_bytes("copy"), None);
        let list = default_shortcuts();
        assert_eq!(filter(&list, "zoom").len(), 3);
        assert_eq!(filter(&list, "").len(), list.len());
        assert!(KEY_ACTIONS.contains(&"interrupt"));
    }
}
