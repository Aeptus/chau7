//! Input (`InputSettingsView.swift`): keybinding preset, mouse options,
//! custom key bindings.
//!
//! Option is Meta except when it types ASCII punctuation, with no setting,
//! as in Swift (`OptionModifiedTextRouting`).

use std::collections::BTreeMap;

use chau7_next_core::config::RawValue;
use chau7_next_core::input::shortcuts;

use super::{ConfigSink, ConfigSource, SettingsDomain};

#[derive(Debug, Clone, PartialEq)]
pub struct InputSettings {
    /// `feature.copyOnSelect`, default on.
    pub copy_on_select: bool,
    /// `feature.mouseReporting` (`[terminal] mouse_reporting`), default off:
    /// programs receive clicks and drags only when this is on. Full-screen
    /// programs always receive requested wheel events; Shift forces selection.
    pub mouse_reporting: bool,
    /// `feature.clickToPosition`, default on: a plain click near the cursor
    /// moves it with arrow keys.
    pub click_to_position: bool,
    /// `feature.optionClickCursor`, default on: Option-click moves the cursor.
    pub option_click_cursor: bool,
    /// `feature.keybindingPreset`: "default", "vim" or "emacs".
    pub keybinding_preset: String,
    /// `keyboard.shortcutHelperHint`, default on.
    pub shortcut_helper_hint: bool,
    /// `feature.broadcastEnabled`, default off ("Broadcast Input"). As in
    /// Swift it is only stored and shown in diagnostics: Broadcast Input to
    /// All Tabs works from its menu item either way.
    pub broadcast_enabled: bool,
    /// `feature.localEchoEnabled`, default off: typed characters appear
    /// before the shell echoes them.
    pub local_echo: bool,
    /// `[keybindings]`: "cmd+t" = "newTab" (Swift action names).
    pub keybindings: Vec<(String, String)>,
}

impl Default for InputSettings {
    fn default() -> Self {
        Self {
            copy_on_select: true,
            mouse_reporting: false,
            click_to_position: true,
            option_click_cursor: true,
            keybinding_preset: "default".into(),
            shortcut_helper_hint: true,
            broadcast_enabled: false,
            local_echo: false,
            keybindings: Vec::new(),
        }
    }
}

impl InputSettings {
    /// Every shortcut in effect: the preset's list with `[keybindings]` applied.
    pub fn shortcuts(&self) -> Vec<shortcuts::KeyboardShortcut> {
        shortcuts::effective_shortcuts(&self.keybinding_preset, &self.keybindings)
    }

    /// Store `list` as `[keybindings]` entries (only what differs from the preset).
    pub fn set_shortcuts(&mut self, list: &[shortcuts::KeyboardShortcut]) {
        let extra: Vec<(String, String)> = self
            .keybindings
            .iter()
            .filter(|(_, action)| {
                !list.iter().any(|s| {
                    shortcuts::canonical_action(&s.action) == shortcuts::canonical_action(action)
                })
            })
            .cloned()
            .collect();
        self.keybindings = shortcuts::config_entries(&self.keybinding_preset, list);
        self.keybindings.extend(extra);
    }
}

impl SettingsDomain for InputSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(bindings) = &src.file.keybindings {
            self.keybindings = bindings
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
        }
        if let Some(v) = src.file.terminal.as_ref().and_then(|t| t.mouse_reporting) {
            self.mouse_reporting = v;
        }
        let flag = |key: &str| src.next(key).and_then(RawValue::as_bool);
        if let Some(v) = flag("copy_on_select") {
            self.copy_on_select = v;
        }
        if let Some(v) = flag("click_to_position") {
            self.click_to_position = v;
        }
        if let Some(v) = flag("option_click_cursor") {
            self.option_click_cursor = v;
        }
        if let Some(v) = flag("shortcut_helper_hint") {
            self.shortcut_helper_hint = v;
        }
        if let Some(v) = flag("broadcast_enabled") {
            self.broadcast_enabled = v;
        }
        if let Some(v) = flag("local_echo") {
            self.local_echo = v;
        }
        if let Some(v) = src.next("keybinding_preset").and_then(RawValue::as_str)
            && shortcuts::PRESETS.contains(&v)
        {
            self.keybinding_preset = v.to_string();
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next("copy_on_select", self.copy_on_select);
        out.set_next("click_to_position", self.click_to_position);
        out.set_next("option_click_cursor", self.option_click_cursor);
        out.set_next("shortcut_helper_hint", self.shortcut_helper_hint);
        out.set_next("broadcast_enabled", self.broadcast_enabled);
        out.set_next("local_echo", self.local_echo);
        out.set_next(
            "keybinding_preset",
            format!("\"{}\"", self.keybinding_preset),
        );
        let terminal = out.file.terminal.get_or_insert_with(Default::default);
        terminal.mouse_reporting = Some(self.mouse_reporting);
        out.file.keybindings = (!self.keybindings.is_empty()).then(|| {
            self.keybindings
                .iter()
                .cloned()
                .collect::<BTreeMap<String, String>>()
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn round_trips() {
        let input = InputSettings {
            copy_on_select: false,
            mouse_reporting: true,
            click_to_position: false,
            option_click_cursor: false,
            keybinding_preset: "vim".into(),
            shortcut_helper_hint: false,
            broadcast_enabled: true,
            local_echo: true,
            keybindings: vec![("cmd+b".into(), "toggleBroadcast".into())],
        };
        assert_eq!(round_trip(&input), input);
    }

    #[test]
    fn swift_defaults() {
        let d = InputSettings::default();
        assert!(d.copy_on_select && d.click_to_position && d.option_click_cursor);
        assert!(!d.mouse_reporting);
        assert!(d.shortcut_helper_hint);
        assert_eq!(d.keybinding_preset, "default");
    }

    #[test]
    fn loads_keybindings_and_mouse_reporting() {
        let input: InputSettings = load_text(
            "[terminal]\nmouse_reporting = true\n\n[next]\nkeybinding_preset = \"bogus\"\n\n[keybindings]\ncmd+b = \"toggleBroadcast\"\n",
        );
        assert!(input.mouse_reporting);
        assert_eq!(input.keybinding_preset, "default");
        assert_eq!(
            input.keybindings,
            vec![("cmd+b".to_string(), "toggleBroadcast".to_string())]
        );
    }

    #[test]
    fn shortcut_edits_become_keybindings() {
        let mut input = InputSettings {
            keybindings: vec![("cmd+b".into(), "toggleBroadcast".into())],
            ..Default::default()
        };
        let mut list = input.shortcuts();
        shortcuts::update(
            &mut list,
            shortcuts::KeyboardShortcut::new("newTab", "y", &["cmd"]),
        );
        input.set_shortcuts(&list);
        assert!(
            input
                .keybindings
                .contains(&("cmd+y".into(), "newTab".into()))
        );
        assert!(
            input
                .keybindings
                .contains(&("cmd+b".into(), "toggleBroadcast".into()))
        );
        assert_eq!(input.shortcuts(), list);
    }
}
