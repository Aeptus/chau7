//! Shortcut text for the command palette and menus: `⇧⌘N` on macOS (Swift's
//! palette shows these), `Ctrl+Shift+N` elsewhere.

/// Modifiers of one keystroke.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Mods {
    pub control: bool,
    pub alt: bool,
    pub shift: bool,
    /// Cmd on macOS, the Windows key elsewhere.
    pub platform: bool,
}

fn key_label(key: &str, mac: bool) -> String {
    let named = match key {
        "enter" => Some(if mac { "↵" } else { "Enter" }),
        "escape" => Some(if mac { "⎋" } else { "Esc" }),
        "tab" => Some(if mac { "⇥" } else { "Tab" }),
        "backspace" => Some(if mac { "⌫" } else { "Backspace" }),
        "delete" => Some(if mac { "⌦" } else { "Delete" }),
        "space" => Some("Space"),
        "up" => Some("↑"),
        "down" => Some("↓"),
        "left" => Some("←"),
        "right" => Some("→"),
        "pageup" => Some("Page Up"),
        "pagedown" => Some("Page Down"),
        "home" => Some("Home"),
        "end" => Some("End"),
        _ => None,
    };
    if let Some(label) = named {
        return label.to_string();
    }
    key.to_uppercase()
}

/// One keystroke: macOS order is control, option, shift, command (`⌃⌥⇧⌘`).
pub fn format_keystroke(mods: Mods, key: &str, mac: bool) -> String {
    let label = key_label(key, mac);
    if mac {
        let mut out = String::new();
        if mods.control {
            out.push('⌃');
        }
        if mods.alt {
            out.push('⌥');
        }
        if mods.shift {
            out.push('⇧');
        }
        if mods.platform {
            out.push('⌘');
        }
        out.push_str(&label);
        out
    } else {
        let mut parts = Vec::new();
        if mods.control {
            parts.push("Ctrl".to_string());
        }
        if mods.alt {
            parts.push("Alt".to_string());
        }
        if mods.shift {
            parts.push("Shift".to_string());
        }
        if mods.platform {
            parts.push("Super".to_string());
        }
        parts.push(label);
        parts.join("+")
    }
}

/// A UI text written for macOS (Swift's wording) adapted to `os`
/// (`std::env::consts::OS`): unchanged on macOS; elsewhere modifier symbols
/// and names become the platform's (Cmd shortcuts are Ctrl+Shift, as in
/// `actions/keymap.rs`; Cmd+click is Ctrl+click; Option is Alt), "Reveal in
/// Finder" names the platform's file manager and "Mac" becomes "computer".
pub fn platform_text(text: &str, os: &str) -> String {
    if os == "macos" {
        return text.to_string();
    }
    let mut s = text.to_string();
    let file_manager = if os == "windows" {
        "Show in Explorer"
    } else {
        "Show in File Manager"
    };
    for (from, to) in [
        ("Reveal in Finder", file_manager),
        ("all your Macs", "all your computers"),
        ("your Mac", "your computer"),
        ("this Mac", "this computer"),
        ("\u{2318}+Click", "Ctrl+Click"),
        ("\u{2325}+Click", "Alt+Click"),
        ("Cmd+click", "Ctrl+click"),
        ("Cmd+Click", "Ctrl+Click"),
        ("Cmd-click", "Ctrl-click"),
        ("Option+click", "Alt+click"),
        ("Option+Click", "Alt+Click"),
        ("Cmd+Shift+", "Ctrl+Shift+"),
        ("Cmd+", "Ctrl+Shift+"),
        ("Option+", "Alt+"),
        ("Opt+", "Alt+"),
    ] {
        s = s.replace(from, to);
    }
    // Runs of modifier symbols before a key: "\u{21E7}\u{2318}]" is
    // "Ctrl+Shift+]".
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if !matches!(c, '\u{2303}' | '\u{2325}' | '\u{21E7}' | '\u{2318}') {
            out.push(c);
            continue;
        }
        let (mut ctrl, mut alt, mut shift) = (false, false, false);
        let mut next = Some(c);
        while let Some(m) = next {
            match m {
                '\u{2303}' => ctrl = true,
                '\u{2325}' => alt = true,
                '\u{21E7}' => shift = true,
                '\u{2318}' => {
                    ctrl = true;
                    shift = true;
                }
                _ => unreachable!(),
            }
            next =
                chars.next_if(|n| matches!(n, '\u{2303}' | '\u{2325}' | '\u{21E7}' | '\u{2318}'));
        }
        for (on, name) in [(ctrl, "Ctrl+"), (alt, "Alt+"), (shift, "Shift+")] {
            if on {
                out.push_str(name);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_text_adapts_mac_wording() {
        assert_eq!(platform_text("\u{2318}T", "macos"), "\u{2318}T");
        assert_eq!(platform_text("\u{2318}T", "linux"), "Ctrl+Shift+T");
        assert_eq!(platform_text("\u{21E7}\u{2318}]", "linux"), "Ctrl+Shift+]");
        assert_eq!(
            platform_text("\u{2318}\u{2325}R", "linux"),
            "Ctrl+Alt+Shift+R"
        );
        assert_eq!(platform_text("\u{2303}Tab", "windows"), "Ctrl+Tab");
        assert_eq!(platform_text("\u{2318}+Click", "linux"), "Ctrl+Click");
        assert_eq!(platform_text("\u{2325}+Click", "linux"), "Alt+Click");
        assert_eq!(
            platform_text("Cmd+click to open file paths", "linux"),
            "Ctrl+click to open file paths"
        );
        assert_eq!(platform_text("Cmd+Shift+M", "linux"), "Ctrl+Shift+M");
        assert_eq!(
            platform_text("Cmd+K palette", "linux"),
            "Ctrl+Shift+K palette"
        );
        assert_eq!(
            platform_text("Option+click moves", "linux"),
            "Alt+click moves"
        );
        assert_eq!(
            platform_text("Reveal in Finder", "linux"),
            "Show in File Manager"
        );
        assert_eq!(
            platform_text("Reveal in Finder", "windows"),
            "Show in Explorer"
        );
        assert_eq!(
            platform_text("Reveal in Finder", "macos"),
            "Reveal in Finder"
        );
        assert_eq!(
            platform_text("start when you log in to your Mac", "linux"),
            "start when you log in to your computer"
        );
    }

    #[test]
    fn mac_symbols() {
        let m = Mods {
            shift: true,
            platform: true,
            ..Default::default()
        };
        assert_eq!(format_keystroke(m, "n", true), "⇧⌘N");
        let m = Mods {
            control: true,
            alt: true,
            platform: true,
            ..Default::default()
        };
        assert_eq!(format_keystroke(m, "]", true), "⌃⌥⌘]");
    }

    #[test]
    fn other_platforms_use_words() {
        let m = Mods {
            control: true,
            shift: true,
            ..Default::default()
        };
        assert_eq!(format_keystroke(m, "t", false), "Ctrl+Shift+T");
        assert_eq!(format_keystroke(Mods::default(), "enter", false), "Enter");
        assert_eq!(format_keystroke(Mods::default(), "up", true), "↑");
    }
}
