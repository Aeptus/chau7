//! Default key bindings and the user's custom shortcuts.
//!
//! macOS shortcuts follow the Swift app: the menus in `Chau7App.swift`, the
//! `AppDelegate` key monitor (Cmd+1..9 by physical key, Ctrl+Tab,
//! Cmd+Opt+arrows) and `FeatureSettings.defaultShortcuts`. On Linux and
//! Windows, Cmd becomes Ctrl+Shift so plain Ctrl combinations still reach the
//! shell.
//!
//! Custom shortcuts: the keybinding preset (`[next] keybinding_preset`) and
//! `[keybindings]` in config.toml (`"cmd+shift+b" = "toggleBroadcast"`, Swift
//! action names). They are bound on top of the defaults, so they win over
//! terminal input. A settings change rebuilds the key map from the defaults
//! (see [`capture_default_keymap`]), so a removed or remapped shortcut stops
//! working at once.

use chau7_next_core::input::shortcuts;
use gpui::{Action, App, Global, KeyBinding};

use super::*;
use crate::settings::InputSettings;

/// The "primary" modifier for app shortcuts on this platform.
fn primary() -> &'static str {
    if cfg!(target_os = "macos") {
        "cmd"
    } else {
        "ctrl-shift"
    }
}

/// Bindings shared by every platform; `p` is the primary modifier ("cmd" on
/// macOS, "ctrl-shift" elsewhere).
fn common_bindings(p: &str) -> Vec<KeyBinding> {
    let k = |keys: &str| keys.replace("P-", &format!("{p}-"));
    vec![
        KeyBinding::new(&k("P-t"), NewTab, None),
        KeyBinding::new(&k("P-w"), CloseTab, None),
        KeyBinding::new(&k("P-n"), NewWindow, None),
        KeyBinding::new(&k("P-d"), SplitRight, Some("Workspace")),
        KeyBinding::new(&k("P-c"), Copy, Some("Terminal")),
        KeyBinding::new(&k("P-v"), Paste, Some("Terminal")),
        KeyBinding::new(&k("P-a"), SelectAll, Some("Terminal")),
        KeyBinding::new(&k("P-k"), ClearScreen, Some("Terminal")),
        KeyBinding::new(&k("P-f"), ToggleSearch, Some("Workspace")),
        KeyBinding::new(&k("P-g"), FindNext, Some("Workspace")),
        KeyBinding::new(&k("P-up"), PreviousInputLine, Some("Terminal")),
        KeyBinding::new(&k("P-down"), NextInputLine, Some("Terminal")),
        KeyBinding::new(&k("P-="), IncreaseFontSize, None),
        KeyBinding::new(&k("P-+"), IncreaseFontSize, None),
        KeyBinding::new(&k("P--"), DecreaseFontSize, None),
        KeyBinding::new(&k("P-,"), OpenSettings, None),
        KeyBinding::new(&k("P-/"), ShowKeyboardShortcuts, None),
        // gpui-base's Root binds Tab/Shift-Tab (focus cycling) and, off macOS,
        // Ctrl-C (copy). Inside a terminal these keys belong to the shell, so
        // mask them; the keys then reach the terminal's key handler.
        KeyBinding::new("tab", gpui::NoAction, Some("Terminal")),
        KeyBinding::new("shift-tab", gpui::NoAction, Some("Terminal")),
        // Only the rename color row overrides Root Tab traversal.
        KeyBinding::new(
            "tab",
            gpui::NoAction,
            Some("Workspace && rename_color_focus"),
        ),
        KeyBinding::new("ctrl-tab", NextTab, None),
        KeyBinding::new("ctrl-shift-tab", PreviousTab, None),
        KeyBinding::new("escape", ToggleSearch, Some("SearchBar")),
        KeyBinding::new("enter", FindNext, Some("SearchBar")),
        KeyBinding::new("shift-enter", FindPrevious, Some("SearchBar")),
        KeyBinding::new("escape", ToggleSnippets, Some("Snippets")),
        KeyBinding::new("escape", ToggleCommandPalette, Some("Palette")),
    ]
}

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys(default_bindings());
    bind_layout_keys(cx);
}

/// The fixed default bindings of this platform (without the
/// layout-dependent Cmd+0..9, [`bind_layout_keys`]).
fn default_bindings() -> Vec<KeyBinding> {
    let mut bindings = common_bindings(primary());
    if cfg!(target_os = "macos") {
        bindings.extend(macos_bindings());
    } else {
        bindings.extend(other_platform_bindings());
    }
    bindings
}

/// Default shortcuts on Linux and Windows, on top of `common_bindings`.
fn other_platform_bindings() -> Vec<KeyBinding> {
    vec![
        KeyBinding::new("ctrl-c", gpui::NoAction, Some("Terminal")),
        // Shift+/ arrives as "?" with or without the Shift flag, by backend.
        KeyBinding::new("ctrl-?", ShowKeyboardShortcuts, None),
        // Same for Shift+, ("<"): Settings.
        KeyBinding::new("ctrl-<", OpenSettings, None),
        KeyBinding::new("ctrl-shift-<", OpenSettings, None),
        KeyBinding::new("ctrl-shift-?", ShowKeyboardShortcuts, None),
        KeyBinding::new("ctrl-pagedown", NextTab, None),
        KeyBinding::new("ctrl-pageup", PreviousTab, None),
        KeyBinding::new("ctrl-shift-r", RenameTab, None),
        KeyBinding::new("ctrl-shift-alt-t", ReopenClosedTab, None),
        KeyBinding::new("ctrl-shift-]", FocusNextPane, Some("Workspace")),
        KeyBinding::new("ctrl-shift-[", FocusPreviousPane, Some("Workspace")),
        KeyBinding::new("ctrl-shift-e", SplitDown, Some("Workspace")),
        KeyBinding::new("ctrl-shift-x", ClosePane, Some("Workspace")),
        KeyBinding::new("ctrl-shift-s", ToggleSnippets, Some("Workspace")),
        KeyBinding::new("ctrl-shift-alt-s", ExportText, Some("Workspace")),
        KeyBinding::new("ctrl-shift-o", crate::commands::ShowSshManager, None),
        // Ctrl+Shift+G is Find Next (`common_bindings`); Ctrl+Shift+Alt+G
        // is Show Changed Files (`panes::bind_keys`).
        KeyBinding::new("ctrl-shift-alt-f", FindPrevious, Some("Workspace")),
        KeyBinding::new("ctrl-shift-space", ToggleCommandPalette, Some("Workspace")),
        KeyBinding::new("ctrl-shift-space", ToggleCommandPalette, Some("Palette")),
        KeyBinding::new("ctrl-shift-h", ShowCommandHistory, Some("Workspace")),
        KeyBinding::new("ctrl-shift-alt-v", PasteEscaped, Some("Terminal")),
        KeyBinding::new("ctrl-shift-alt-k", ClearScrollback, Some("Terminal")),
        KeyBinding::new("f11", ToggleFullScreen, None),
        KeyBinding::new("ctrl-shift-q", Quit, None),
        KeyBinding::new("ctrl-shift-f12", SeedDebugTabs, None),
    ]
}

/// Every binding made at startup before the user's shortcuts: GPUI's and
/// the components', then the app's defaults. Settings changes rebuild the
/// key map from it.
struct DefaultKeymap(Vec<KeyBinding>);

impl Global for DefaultKeymap {}

/// Remember the key map as it stands, once every module bound its default
/// keys and before [`bind_shortcut_settings`] binds the user's shortcuts.
/// Layout-dependent keys are left out: they are bound again with each
/// rebuild, for the current layout.
pub fn capture_default_keymap(cx: &mut App) {
    let keymap = cx.key_bindings();
    let layout_actions: Vec<_> = layout_actions();
    let bindings = keymap
        .borrow()
        .bindings()
        .filter(|b| {
            !layout_actions
                .iter()
                .any(|a| b.action().partial_eq(a.as_ref()))
        })
        .cloned()
        .collect();
    cx.set_global(DefaultKeymap(bindings));
}

/// The actions [`bind_layout_keys`] binds (Cmd+1..9, Cmd+0).
fn layout_actions() -> Vec<Box<dyn Action>> {
    let mut actions: Vec<Box<dyn Action>> = (1..=9)
        .map(|n| Box::new(SelectTabNumber(n)) as Box<dyn Action>)
        .collect();
    actions.push(Box::new(ResetFontSize));
    actions
}

/// Cmd+1..9 (select tab) and Cmd+0 (actual size), matched by physical key:
/// on AZERTY Cmd+& selects tab 1 and Cmd+à resets the size, as in Swift
/// (`tabNumberForKeyCode`). GPUI's key equivalents map the US key to the
/// key at the same place in the current layout. Off macOS, Alt+N.
fn bind_layout_keys(cx: &mut App) {
    let select_mod = if cfg!(target_os = "macos") {
        "cmd"
    } else {
        "alt"
    };
    let mapper = cx.keyboard_mapper().clone();
    let mut bindings = Vec::new();
    let mut load = |keys: String, action: Box<dyn Action>| match KeyBinding::load(
        &keys,
        action,
        None,
        true,
        None,
        mapper.as_ref(),
    ) {
        Ok(binding) => bindings.push(binding),
        Err(err) => log::warn!("keybinding {keys}: {err:?}"),
    };
    for n in 1..=9 {
        load(format!("{select_mod}-{n}"), Box::new(SelectTabNumber(n)));
    }
    load(format!("{}-0", primary()), Box::new(ResetFontSize));
    bindings.extend(tab_bindings());
    cx.bind_keys(bindings);
}

/// Tab bar and overlay shortcuts off macOS (Close Other Tabs, Move Tab
/// Right/Left, minimal mode, bookmarks).
fn tab_bindings() -> Vec<KeyBinding> {
    // On macOS these are part of `macos_bindings`.
    if cfg!(target_os = "macos") {
        Vec::new()
    } else {
        other_platform_tab_bindings()
    }
}

fn other_platform_tab_bindings() -> Vec<KeyBinding> {
    {
        vec![
            KeyBinding::new("ctrl-shift-alt-w", CloseOtherTabs, None),
            KeyBinding::new("ctrl-shift-alt-]", MoveTabRight, None),
            KeyBinding::new("ctrl-shift-alt-[", MoveTabLeft, None),
            KeyBinding::new("ctrl-shift-alt-m", ToggleMinimalMode, None),
            KeyBinding::new("ctrl-shift-alt-r", RefreshTabBar, None),
            KeyBinding::new("ctrl-shift-b", AddBookmark, Some("Workspace")),
            // Help menu (Swift Cmd+Opt+I, Cmd+Opt+L).
            KeyBinding::new("ctrl-shift-alt-i", ReportIssue, None),
            KeyBinding::new("ctrl-shift-alt-l", ToggleDebugConsole, None),
        ]
    }
}

/// Bind the keybinding preset and `[keybindings]` on top of the defaults,
/// plus Cmd+Opt+Left/Right for tabs while the tab shortcuts are not
/// customized (Swift `shouldUseAlternateTabNavigationShortcuts`). Called at
/// startup, after a settings change and when the keyboard layout changes.
/// GPUI cannot remove a single binding, so the key map is rebuilt from the
/// defaults captured at startup ([`capture_default_keymap`]): a removed or
/// remapped shortcut stops working at once and nothing accumulates.
pub fn bind_shortcut_settings(input: &InputSettings, cx: &mut App) {
    if let Some(defaults) = cx.try_global::<DefaultKeymap>() {
        let defaults = defaults.0.clone();
        cx.clear_key_bindings();
        cx.bind_keys(defaults);
    }
    bind_layout_keys(cx);
    let list = input.shortcuts();
    let tabs_customized = shortcuts::changed_from_defaults(&list)
        .iter()
        .any(|s| s.action == "nextTab" || s.action == "previousTab");
    if cfg!(target_os = "macos") && !tabs_customized {
        cx.bind_keys([
            KeyBinding::new("cmd-alt-right", NextTab, Some("Terminal")),
            KeyBinding::new("cmd-alt-left", PreviousTab, Some("Terminal")),
        ]);
    }
    let custom: Vec<(String, String)> = shortcuts::changed_from_defaults(&list)
        .into_iter()
        .map(|s| (s.config_keys(), s.action))
        .collect();
    bind_custom_keys(&custom, cx);
}

/// Default shortcuts on macOS: `Chau7App.swift` (menu key equivalents) and
/// `KeybindingsManager.swift`. Where Swift binds an action that Chau7 Next
/// has not ported yet (Data Explorer, editor panes, ...), the shortcut is
/// bound anyway; the handler logs until that area is ported.
fn macos_bindings() -> Vec<KeyBinding> {
    vec![
        // File.
        KeyBinding::new("cmd-shift-o", crate::commands::ShowSshManager, None),
        KeyBinding::new("cmd-shift-w", CloseWindow, None),
        KeyBinding::new("cmd-alt-w", CloseOtherTabs, None),
        KeyBinding::new("cmd-shift-t", ReopenClosedTab, None),
        KeyBinding::new("cmd-shift-s", ExportText, Some("Workspace")),
        KeyBinding::new("cmd-p", PrintTerminal, Some("Workspace")),
        // Edit.
        KeyBinding::new("cmd-x", Cut, Some("Terminal")),
        KeyBinding::new("cmd-alt-v", PasteEscaped, Some("Terminal")),
        KeyBinding::new("cmd-shift-g", FindPrevious, Some("Workspace")),
        KeyBinding::new("cmd-e", UseSelectionForFind, Some("Workspace")),
        // Swift handles this one in OverlayWindow.performKeyEquivalent, not in the menu.
        KeyBinding::new("cmd-;", ToggleSnippets, Some("Workspace")),
        KeyBinding::new("cmd-alt-p", ToggleCommandPalette, Some("Workspace")),
        // Chau7 Next extras that do not collide with a Swift shortcut.
        KeyBinding::new("cmd-shift-p", ToggleCommandPalette, Some("Workspace")),
        // The palette is its own window: the same keys close it there.
        KeyBinding::new("cmd-alt-p", ToggleCommandPalette, Some("Palette")),
        KeyBinding::new("cmd-shift-p", ToggleCommandPalette, Some("Palette")),
        KeyBinding::new("cmd-shift-h", ShowCommandHistory, Some("Workspace")),
        // View (Cmd+0 and Cmd+1..9 are bound by physical key, `bind_layout_keys`;
        // Cmd+K, Cmd+Up/Down and Cmd+/ are in `common_bindings`).
        KeyBinding::new("cmd-shift-d", DataExplorer, Some("Workspace")),
        KeyBinding::new("cmd-ctrl-f", ToggleFullScreen, None),
        KeyBinding::new("cmd-alt-k", ClearScrollback, Some("Terminal")),
        // Panes.
        KeyBinding::new("cmd-alt-d", SplitDown, Some("Workspace")),
        KeyBinding::new("cmd-alt-e", OpenTextEditor, Some("Workspace")),
        KeyBinding::new("cmd-alt-o", OpenFilePreview, Some("Workspace")),
        KeyBinding::new("cmd-alt-shift-d", OpenDiffViewer, Some("Workspace")),
        KeyBinding::new(
            "cmd-alt-shift-e",
            AppendSelectionToEditor,
            Some("Workspace"),
        ),
        KeyBinding::new("ctrl-cmd-w", ClosePane, Some("Workspace")),
        KeyBinding::new("cmd-alt-]", FocusNextPane, Some("Workspace")),
        KeyBinding::new("cmd-alt-[", FocusPreviousPane, Some("Workspace")),
        KeyBinding::new("cmd-alt-g", ShowChangedFiles, Some("Workspace")),
        // Window. macOS reports Cmd+Shift+] as "cmd-}" (Shift folded into the
        // character), as in Zed's keymap.
        KeyBinding::new("cmd-alt-r", RenameTab, None),
        KeyBinding::new("cmd-alt-shift-r", RefreshTabBar, None),
        KeyBinding::new("cmd-}", NextTab, None),
        KeyBinding::new("cmd-{", PreviousTab, None),
        KeyBinding::new("cmd-alt-}", MoveTabRight, None),
        KeyBinding::new("cmd-alt-{", MoveTabLeft, None),
        KeyBinding::new("cmd-alt-shift-]", MoveTabRight, None),
        KeyBinding::new("cmd-alt-shift-[", MoveTabLeft, None),
        KeyBinding::new("cmd-m", Minimize, None),
        // Chau7 Next extras: minimal mode, bookmarks, snippets.
        KeyBinding::new("cmd-shift-m", ToggleMinimalMode, None),
        KeyBinding::new("cmd-ctrl-alt-d", SeedDebugTabs, None),
        KeyBinding::new("cmd-b", AddBookmark, Some("Workspace")),
        KeyBinding::new("cmd-alt-s", ToggleSnippets, Some("Workspace")),
        // App and Help.
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("cmd-h", HideApp, None),
        KeyBinding::new("cmd-alt-h", HideOtherApps, None),
        KeyBinding::new("cmd-alt-i", ReportIssue, None),
        KeyBinding::new("cmd-alt-l", ToggleDebugConsole, None),
    ]
}

/// Action for a Swift action name (config `[keybindings]`): `KeyAction` raw
/// values and the shortcut names Swift stores (`find`, `snippets`, ...).
pub fn action_for_swift_name(name: &str) -> Option<Box<dyn Action>> {
    let action: Box<dyn Action> = match shortcuts::canonical_action(name) {
        "newTab" => Box::new(NewTab),
        "closeTab" => Box::new(CloseTab),
        "reopenClosedTab" => Box::new(ReopenClosedTab),
        "nextTab" => Box::new(NextTab),
        "previousTab" => Box::new(PreviousTab),
        "copy" => Box::new(Copy),
        "paste" => Box::new(Paste),
        "selectAll" => Box::new(SelectAll),
        "clear" => Box::new(ClearScrollback),
        "toggleSearch" => Box::new(ToggleSearch),
        "nextMatch" => Box::new(FindNext),
        "previousMatch" => Box::new(FindPrevious),
        "zoomIn" => Box::new(IncreaseFontSize),
        "zoomOut" => Box::new(DecreaseFontSize),
        "zoomReset" => Box::new(ResetFontSize),
        "toggleFullscreen" => Box::new(ToggleFullScreen),
        "interrupt" => Box::new(SendInterrupt),
        "eof" => Box::new(SendEndOfFile),
        "suspend" => Box::new(SendSuspend),
        "clearLine" => Box::new(ClearLine),
        "clearWord" => Box::new(ClearWord),
        "toggleBroadcast" => Box::new(ToggleBroadcast),
        "showClipboardHistory" => Box::new(ShowClipboardHistory),
        "showSnippets" => Box::new(ToggleSnippets),
        "showBookmarks" => Box::new(ToggleBookmarks),
        "addBookmark" => Box::new(AddBookmark),
        "showChangedFiles" => Box::new(ShowChangedFiles),
        "renameTab" => Box::new(RenameTab),
        "refreshTabBar" => Box::new(RefreshTabBar),
        // Swift: horizontal = side by side (Cmd+D), vertical = stacked.
        "splitHorizontal" => Box::new(SplitRight),
        "splitVertical" => Box::new(SplitDown),
        "previousInputLine" => Box::new(PreviousInputLine),
        "nextInputLine" => Box::new(NextInputLine),
        "closeWindow" => Box::new(CloseWindow),
        "newWindow" => Box::new(NewWindow),
        "debugConsole" => Box::new(ToggleDebugConsole),
        "openTextEditor" => Box::new(OpenTextEditor),
        other => {
            let n = other.strip_prefix("selectTab")?.parse::<usize>().ok()?;
            Box::new(SelectTabNumber(n))
        }
    };
    Some(action)
}

/// "cmd+shift+t" (Swift config format) to "cmd-shift-t" (GPUI format).
/// With Cmd held, macOS folds Shift into punctuation ("cmd+shift+]" arrives
/// as "cmd-}"), so shifted punctuation is rewritten the same way there.
pub fn swift_keys_to_gpui(keys: &str) -> String {
    let mut parts: Vec<String> = keys
        .split('+')
        .map(|part| match part.trim().to_ascii_lowercase().as_str() {
            "opt" | "option" => "alt".to_string(),
            "command" => "cmd".to_string(),
            "control" => "ctrl".to_string(),
            "return" => "enter".to_string(),
            "esc" => "escape".to_string(),
            other => other.to_string(),
        })
        .collect();
    if cfg!(target_os = "macos")
        && parts.iter().any(|p| p == "cmd")
        && parts.iter().any(|p| p == "shift")
        && let Some(last) = parts.last_mut()
        && let Some(shifted) = shifted_punctuation(last)
    {
        *last = shifted.to_string();
        parts.retain(|p| p != "shift");
    }
    parts.join("-")
}

/// US-layout Shift variant of a punctuation key.
fn shifted_punctuation(key: &str) -> Option<&'static str> {
    Some(match key {
        "]" => "}",
        "[" => "{",
        "," => "<",
        "." => ">",
        "/" => "?",
        ";" => ":",
        "'" => "\"",
        "\\" => "|",
        "-" => "_",
        "=" => "+",
        "`" => "~",
        _ => return None,
    })
}

/// Bind (keys, Swift action name) pairs on top of the defaults.
pub fn bind_custom_keys(bindings: &[(String, String)], cx: &mut App) {
    let mut out = Vec::new();
    for (keys, action_name) in bindings {
        match action_for_swift_name(action_name) {
            Some(action) => {
                let keys = swift_keys_to_gpui(keys);
                match KeyBinding::load(&keys, action, None, false, None, &gpui::DummyKeyboardMapper)
                {
                    Ok(binding) => out.push(binding),
                    Err(err) => log::warn!("keybinding {keys}: {err:?}"),
                }
            }
            // Swift actions whose feature Chau7 Next does not have yet
            // (debug console, text editor, bookmarks, ...).
            None => log::warn!("unsupported action in [keybindings]: {action_name}"),
        }
    }
    cx.bind_keys(out);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_swift_key_format() {
        assert_eq!(swift_keys_to_gpui("cmd+shift+t"), "cmd-shift-t");
        assert_eq!(swift_keys_to_gpui("opt+cmd+r"), "alt-cmd-r");
        assert_eq!(swift_keys_to_gpui("cmd+up"), "cmd-up");
        let bracket = swift_keys_to_gpui("cmd+shift+]");
        if cfg!(target_os = "macos") {
            assert_eq!(bracket, "cmd-}");
        } else {
            assert_eq!(bracket, "cmd-shift-]");
        }
    }

    #[test]
    fn maps_swift_action_names() {
        assert!(action_for_swift_name("newTab").is_some());
        assert!(action_for_swift_name("selectTab3").is_some());
        assert!(action_for_swift_name("interrupt").is_some());
        assert!(action_for_swift_name("debugConsole").is_some());
        // Shortcut names as Swift stores them.
        assert!(
            action_for_swift_name("find")
                .unwrap()
                .partial_eq(&ToggleSearch)
        );
        assert!(
            action_for_swift_name("findNext")
                .unwrap()
                .partial_eq(&FindNext)
        );
        assert!(
            action_for_swift_name("snippets")
                .unwrap()
                .partial_eq(&ToggleSnippets)
        );
        assert!(
            action_for_swift_name("previousInputLine")
                .unwrap()
                .partial_eq(&PreviousInputLine)
        );
    }

    #[test]
    fn every_swift_key_action_is_bindable() {
        // All KeyAction raw values, including recovery commands.
        for name in [
            "newTab",
            "closeTab",
            "reopenClosedTab",
            "nextTab",
            "previousTab",
            "selectTab1",
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
            "refreshTabBar",
            "debugConsole",
            "splitHorizontal",
            "splitVertical",
            "openTextEditor",
            "showChangedFiles",
            "previousInputLine",
            "nextInputLine",
            "closeWindow",
            "newWindow",
        ] {
            assert!(action_for_swift_name(name).is_some(), "{name}");
        }
        assert!(
            action_for_swift_name("showBookmarks")
                .unwrap()
                .partial_eq(&ToggleBookmarks)
        );
        assert!(
            action_for_swift_name("addBookmark")
                .unwrap()
                .partial_eq(&AddBookmark)
        );
    }

    #[test]
    fn split_names_follow_swift() {
        // Swift: splitHorizontal is side by side (Cmd+D), splitVertical stacked.
        let h = action_for_swift_name("splitHorizontal").unwrap();
        assert!(h.partial_eq(&SplitRight));
        let v = action_for_swift_name("splitVertical").unwrap();
        assert!(v.partial_eq(&SplitDown));
    }

    #[test]
    fn every_default_shortcut_with_a_feature_maps_to_an_action() {
        let missing: Vec<String> = shortcuts::default_shortcuts()
            .into_iter()
            .filter(|s| action_for_swift_name(&s.action).is_none())
            .map(|s| s.action)
            .collect();
        assert!(missing.is_empty(), "{missing:?}");
    }

    /// Swift's shortcuts on macOS (`Chau7App.swift` menus, the AppDelegate
    /// key monitor, `KeybindingsManager`): each key is bound exactly once,
    /// to the Swift action. Context-only keys (Escape in a panel) and the
    /// keys masked for the shell are left out. Cmd+0..9 are bound by
    /// physical key at run time (`bind_layout_keys`).
    #[test]
    fn macos_defaults_match_swift() {
        let mut bindings = common_bindings("cmd");
        bindings.extend(macos_bindings());
        let mut seen: std::collections::HashMap<String, String> = Default::default();
        for b in &bindings {
            let context = b.predicate().map(|p| p.to_string()).unwrap_or_default();
            if ["SearchBar", "Snippets", "Palette"].contains(&context.as_str())
                || b.action().name() == "zed::NoAction"
            {
                continue;
            }
            let key = b
                .keystrokes()
                .iter()
                .map(|k| k.unparse())
                .collect::<Vec<_>>()
                .join(" ");
            let action = b.action().name().to_string();
            if let Some(previous) = seen.insert(key.clone(), action.clone()) {
                panic!("{key} is bound twice: {previous} and {action}");
            }
        }
        let swift = [
            ("cmd-t", "NewTab"),
            ("cmd-n", "NewWindow"),
            ("cmd-w", "CloseTab"),
            ("cmd-shift-w", "CloseWindow"),
            ("cmd-alt-w", "CloseOtherTabs"),
            ("cmd-shift-t", "ReopenClosedTab"),
            ("cmd-shift-o", "ShowSshManager"),
            ("cmd-shift-s", "ExportText"),
            ("cmd-p", "PrintTerminal"),
            ("cmd-x", "Cut"),
            ("cmd-c", "Copy"),
            ("cmd-v", "Paste"),
            ("cmd-alt-v", "PasteEscaped"),
            ("cmd-a", "SelectAll"),
            ("cmd-f", "ToggleSearch"),
            ("cmd-g", "FindNext"),
            ("cmd-shift-g", "FindPrevious"),
            ("cmd-e", "UseSelectionForFind"),
            ("cmd-;", "ToggleSnippets"),
            ("cmd-alt-p", "ToggleCommandPalette"),
            ("cmd-shift-d", "DataExplorer"),
            ("cmd-ctrl-f", "ToggleFullScreen"),
            ("cmd-=", "IncreaseFontSize"),
            ("cmd--", "DecreaseFontSize"),
            ("cmd-k", "ClearScreen"),
            ("cmd-alt-k", "ClearScrollback"),
            ("cmd-up", "PreviousInputLine"),
            ("cmd-down", "NextInputLine"),
            ("cmd-d", "SplitRight"),
            ("cmd-alt-d", "SplitDown"),
            ("cmd-alt-e", "OpenTextEditor"),
            ("cmd-alt-o", "OpenFilePreview"),
            ("cmd-alt-shift-d", "OpenDiffViewer"),
            ("cmd-alt-shift-e", "AppendSelectionToEditor"),
            ("ctrl-cmd-w", "ClosePane"),
            ("cmd-alt-]", "FocusNextPane"),
            ("cmd-alt-[", "FocusPreviousPane"),
            ("cmd-alt-g", "ShowChangedFiles"),
            ("cmd-alt-r", "RenameTab"),
            ("cmd-}", "NextTab"),
            ("cmd-{", "PreviousTab"),
            ("cmd-alt-}", "MoveTabRight"),
            ("cmd-alt-{", "MoveTabLeft"),
            ("ctrl-tab", "NextTab"),
            ("ctrl-shift-tab", "PreviousTab"),
            ("cmd-m", "Minimize"),
            ("cmd-,", "OpenSettings"),
            ("cmd-q", "Quit"),
            ("cmd-h", "HideApp"),
            ("cmd-alt-h", "HideOtherApps"),
            ("cmd-/", "ShowKeyboardShortcuts"),
            ("cmd-alt-i", "ReportIssue"),
            ("cmd-alt-l", "ToggleDebugConsole"),
        ];
        for (stroke, action) in swift {
            // The platform spells the Cmd key its own way (Super on Linux).
            let key = gpui::Keystroke::parse(stroke).unwrap().unparse();
            let bound = seen.get(&key).map(|a| a.rsplit("::").next().unwrap_or(a));
            assert_eq!(bound, Some(action), "{stroke}");
        }
    }

    /// Linux and Windows defaults (Cmd becomes Ctrl+Shift): each key is
    /// bound once, panes and tab shortcuts included.
    #[test]
    fn other_platform_defaults_bind_each_key_once() {
        let mut bindings = common_bindings("ctrl-shift");
        bindings.extend(other_platform_bindings());
        bindings.extend(other_platform_tab_bindings());
        bindings.extend(crate::panes::other_platform_bindings());
        let mut seen: std::collections::HashMap<String, String> = Default::default();
        for b in &bindings {
            let context = b.predicate().map(|p| p.to_string()).unwrap_or_default();
            if ["SearchBar", "Snippets", "Palette"].contains(&context.as_str())
                || b.action().name() == "zed::NoAction"
            {
                continue;
            }
            let key = b
                .keystrokes()
                .iter()
                .map(|k| k.unparse())
                .collect::<Vec<_>>()
                .join(" ");
            let action = b.action().name().to_string();
            if let Some(previous) = seen.insert(key.clone(), action.clone()) {
                panic!("{key} is bound twice: {previous} and {action}");
            }
        }
    }

    /// A settings change rebuilds the key map from the captured defaults:
    /// a removed custom shortcut stops working and bindings never pile up.
    #[gpui::test]
    fn shortcut_changes_replace_previous_custom_bindings(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| {
            bind_keys(cx);
            capture_default_keymap(cx);
            let bound = |cx: &App| -> Vec<String> {
                cx.key_bindings()
                    .borrow()
                    .bindings()
                    .filter(|b| b.action().partial_eq(&ToggleBroadcast))
                    .map(|b| {
                        b.keystrokes()
                            .iter()
                            .map(|k| k.unparse())
                            .collect::<Vec<_>>()
                            .join(" ")
                    })
                    .collect()
            };
            let mut input = InputSettings::default();
            input.keybindings = vec![("cmd+shift+y".into(), "toggleBroadcast".into())];
            bind_shortcut_settings(&input, cx);
            let count = cx.key_bindings().borrow().bindings().len();
            assert_eq!(bound(cx).len(), 1);
            bind_shortcut_settings(&input, cx);
            assert_eq!(cx.key_bindings().borrow().bindings().len(), count);

            input.keybindings = vec![("cmd+shift+u".into(), "toggleBroadcast".into())];
            bind_shortcut_settings(&input, cx);
            let keys = bound(cx);
            assert_eq!(keys.len(), 1, "{keys:?}");
            assert!(keys[0].ends_with('u'), "{keys:?}");

            bind_shortcut_settings(&InputSettings::default(), cx);
            assert!(bound(cx).is_empty());
        });
    }

    /// GPUI panics at launch when two actions share a name (two `actions!`
    /// blocks declaring the same one compile fine).
    #[test]
    fn action_names_are_unique() {
        let mut names: Vec<_> = gpui::generate_list_of_all_registered_actions()
            .map(|a| a.name)
            .collect();
        let count = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), count, "an action is declared twice");
    }
}
