//! Keyboard input to terminal bytes (xterm conventions).
//!
//! Plays the role of the key handling in
//! `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView.swift` (`keyDown`)
//! and `Chau7Core/TerminalKeyPress.swift`: named keys, Control combinations,
//! modifier parameters (`CSI 1;m X`), application cursor mode and Option/Alt.
//!
//! Key names follow GPUI's `Keystroke::key` naming ("enter", "left", "f5",
//! "a", ...). The UI layer passes the platform's composed text as `key_char`.

/// Modifier state for one key press.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KeyMods {
    pub shift: bool,
    pub alt: bool,
    pub control: bool,
    /// Command on macOS, Super/Windows elsewhere. Never sent to the shell.
    pub platform: bool,
}

/// Terminal state that changes how keys are encoded.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KeyContext {
    /// DECCKM (`ESC [ ? 1 h`): arrows and Home/End use `SS3`.
    pub app_cursor: bool,
    /// Treat Option/Alt as Meta (send `ESC` + key) instead of composing characters.
    pub option_as_meta: bool,
}

const ESC: u8 = 0x1b;

/// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl.
fn modifier_param(mods: KeyMods) -> u8 {
    1 + u8::from(mods.shift) + 2 * u8::from(mods.alt) + 4 * u8::from(mods.control)
}

fn has_modifiers(mods: KeyMods) -> bool {
    mods.shift || mods.alt || mods.control
}

/// Encode a key press. Returns `None` when the key should not reach the shell
/// (platform/Command shortcuts, bare modifier keys, unknown keys).
pub fn encode_key(
    key: &str,
    key_char: Option<&str>,
    mods: KeyMods,
    ctx: KeyContext,
) -> Option<Vec<u8>> {
    if mods.platform {
        return None;
    }

    // Cursor keys: CSI or SS3 final byte.
    let cursor_final = match key {
        "up" => Some(b'A'),
        "down" => Some(b'B'),
        "right" => Some(b'C'),
        "left" => Some(b'D'),
        "home" => Some(b'H'),
        "end" => Some(b'F'),
        _ => None,
    };
    if let Some(final_byte) = cursor_final {
        if has_modifiers(mods) {
            return Some(
                format!("\x1b[1;{}{}", modifier_param(mods), final_byte as char).into_bytes(),
            );
        }
        let intro = if ctx.app_cursor { b'O' } else { b'[' };
        return Some(vec![ESC, intro, final_byte]);
    }

    // Tilde keys: CSI n ~ (with ;m when modified).
    let tilde = match key {
        "insert" => Some(2),
        "delete" => Some(3),
        "pageup" => Some(5),
        "pagedown" => Some(6),
        "f5" => Some(15),
        "f6" => Some(17),
        "f7" => Some(18),
        "f8" => Some(19),
        "f9" => Some(20),
        "f10" => Some(21),
        "f11" => Some(23),
        "f12" => Some(24),
        _ => None,
    };
    if let Some(code) = tilde {
        if has_modifiers(mods) {
            return Some(format!("\x1b[{code};{}~", modifier_param(mods)).into_bytes());
        }
        return Some(format!("\x1b[{code}~").into_bytes());
    }

    // F1..F4: SS3 P..S, CSI 1;m P..S when modified.
    let f1_4 = match key {
        "f1" => Some(b'P'),
        "f2" => Some(b'Q'),
        "f3" => Some(b'R'),
        "f4" => Some(b'S'),
        _ => None,
    };
    if let Some(final_byte) = f1_4 {
        if has_modifiers(mods) {
            return Some(
                format!("\x1b[1;{}{}", modifier_param(mods), final_byte as char).into_bytes(),
            );
        }
        return Some(vec![ESC, b'O', final_byte]);
    }

    let with_alt = |mut bytes: Vec<u8>| {
        if mods.alt {
            bytes.insert(0, ESC);
        }
        bytes
    };

    match key {
        "enter" => return Some(with_alt(vec![b'\r'])),
        "tab" => {
            if mods.shift {
                return Some(b"\x1b[Z".to_vec());
            }
            return Some(with_alt(vec![b'\t']));
        }
        "escape" => return Some(with_alt(vec![ESC])),
        "backspace" => {
            if mods.control {
                return Some(with_alt(vec![0x08]));
            }
            return Some(with_alt(vec![0x7f]));
        }
        "space" => {
            if mods.control {
                return Some(with_alt(vec![0x00]));
            }
            return Some(with_alt(vec![b' ']));
        }
        "shift" | "control" | "alt" | "platform" | "function" | "capslock" | "fn" => return None,
        _ => {}
    }

    // Control combinations on printable keys.
    if mods.control {
        let base = key.chars().next().filter(|_| key.chars().count() == 1)?;
        let byte = match base.to_ascii_lowercase() {
            c @ 'a'..='z' => (c as u8) & 0x1f,
            '@' | '2' => 0x00,
            '[' | '3' => 0x1b,
            '\\' | '4' => 0x1c,
            ']' | '5' => 0x1d,
            '^' | '6' => 0x1e,
            // Ctrl+/ is US like Ctrl+_ (xterm, Terminal.app, iTerm2); Emacs
            // and readline bind it to undo.
            '_' | '-' | '/' | '7' => 0x1f,
            '?' | '8' => 0x7f,
            _ => return None,
        };
        return Some(with_alt(vec![byte]));
    }

    // Option/Alt as Meta: ESC + the unmodified key.
    if mods.alt && ctx.option_as_meta {
        let base: String = if key.chars().count() == 1 {
            if mods.shift {
                key.to_uppercase()
            } else {
                key.to_string()
            }
        } else {
            key_char?.to_string()
        };
        let mut bytes = vec![ESC];
        bytes.extend_from_slice(base.as_bytes());
        return Some(bytes);
    }

    // Plain text: the platform's composed characters (handles Shift, Option
    // compositions on macOS, dead keys resolved by the input method).
    let text = key_char.filter(|text| !text.is_empty())?;
    Some(text.as_bytes().to_vec())
}

/// True when an Option/Alt key press should type its composed character
/// instead of being sent as Meta (`ESC` + key). Swift's rule
/// (`OptionModifiedTextRouting`, no setting): Option with a letter is Meta;
/// Option with a non-letter key that types one printable ASCII character
/// (Option+5 is `[` on AZERTY) is text. `key` is GPUI's key name (the base
/// character, Shift applied for non-letters), `key_char` the composed text.
pub fn option_types_text(key: &str, key_char: Option<&str>, mods: KeyMods) -> bool {
    let base = if key == "space" { " " } else { key };
    crate::option_text_routing::should_treat_as_literal_text(
        key_char,
        Some(base),
        mods.alt,
        mods.control,
        mods.platform,
    )
}

/// Wrap pasted text for bracketed paste mode (`ESC [ ? 2004 h`) and normalize
/// line endings the way terminals do (`\r\n` and `\n` become `\r`).
pub fn encode_paste(text: &str, bracketed: bool) -> Vec<u8> {
    let normalized = text.replace("\r\n", "\r").replace('\n', "\r");
    let mut out = Vec::with_capacity(normalized.len() + 12);
    if bracketed {
        out.extend_from_slice(b"\x1b[200~");
        // Strip the end marker so pasted content cannot leave paste mode
        // early, including markers that only form once an inner one is
        // removed.
        out.extend_from_slice(&strip_paste_end_markers(normalized.as_bytes()));
        out.extend_from_slice(b"\x1b[201~");
    } else {
        out.extend_from_slice(normalized.as_bytes());
    }
    out
}

/// Remove every bracketed paste end marker (`ESC [ 201 ~`) from `bytes`,
/// including markers formed by the bytes around a removed one. A marker can
/// only form at the end of the output as bytes are appended, so checking the
/// tail after each byte leaves none behind in a single linear pass. The
/// marker is ASCII, so truncating it keeps UTF-8 text valid.
fn strip_paste_end_markers(bytes: &[u8]) -> Vec<u8> {
    const END_MARKER: &[u8] = b"\x1b[201~";
    let mut out = Vec::with_capacity(bytes.len());
    for &byte in bytes {
        out.push(byte);
        if out.ends_with(END_MARKER) {
            out.truncate(out.len() - END_MARKER.len());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn enc(key: &str, ch: Option<&str>, mods: KeyMods) -> Option<Vec<u8>> {
        encode_key(key, ch, mods, KeyContext::default())
    }

    const NONE: KeyMods = KeyMods {
        shift: false,
        alt: false,
        control: false,
        platform: false,
    };

    #[test]
    fn printable_uses_key_char() {
        assert_eq!(enc("a", Some("a"), NONE), Some(b"a".to_vec()));
        let shift = KeyMods {
            shift: true,
            ..NONE
        };
        assert_eq!(enc("a", Some("A"), shift), Some(b"A".to_vec()));
        assert_eq!(enc("e", Some("é"), NONE), Some("é".as_bytes().to_vec()));
    }

    #[test]
    fn control_letters() {
        let ctrl = KeyMods {
            control: true,
            ..NONE
        };
        assert_eq!(enc("c", Some("c"), ctrl), Some(vec![3]));
        assert_eq!(enc("a", None, ctrl), Some(vec![1]));
        assert_eq!(enc("[", None, ctrl), Some(vec![0x1b]));
        assert_eq!(enc("space", None, ctrl), Some(vec![0]));
    }

    #[test]
    fn control_slash_sends_unit_separator() {
        let ctrl = KeyMods {
            control: true,
            ..NONE
        };
        assert_eq!(enc("/", Some("/"), ctrl), Some(vec![0x1f]));
        assert_eq!(enc("_", None, ctrl), Some(vec![0x1f]));
    }

    #[test]
    fn named_keys() {
        assert_eq!(enc("enter", None, NONE), Some(b"\r".to_vec()));
        assert_eq!(enc("backspace", None, NONE), Some(vec![0x7f]));
        assert_eq!(enc("tab", None, NONE), Some(b"\t".to_vec()));
        assert_eq!(
            enc(
                "tab",
                None,
                KeyMods {
                    shift: true,
                    ..NONE
                }
            ),
            Some(b"\x1b[Z".to_vec())
        );
        assert_eq!(enc("escape", None, NONE), Some(vec![0x1b]));
        assert_eq!(enc("delete", None, NONE), Some(b"\x1b[3~".to_vec()));
        assert_eq!(enc("pageup", None, NONE), Some(b"\x1b[5~".to_vec()));
        assert_eq!(enc("f1", None, NONE), Some(b"\x1bOP".to_vec()));
        assert_eq!(enc("f12", None, NONE), Some(b"\x1b[24~".to_vec()));
    }

    #[test]
    fn arrows_normal_app_and_modified() {
        assert_eq!(enc("up", None, NONE), Some(b"\x1b[A".to_vec()));
        let app = KeyContext {
            app_cursor: true,
            ..KeyContext::default()
        };
        assert_eq!(encode_key("up", None, NONE, app), Some(b"\x1bOA".to_vec()));
        let ctrl = KeyMods {
            control: true,
            ..NONE
        };
        assert_eq!(enc("left", None, ctrl), Some(b"\x1b[1;5D".to_vec()));
        let shift_alt = KeyMods {
            shift: true,
            alt: true,
            ..NONE
        };
        assert_eq!(enc("right", None, shift_alt), Some(b"\x1b[1;4C".to_vec()));
    }

    #[test]
    fn alt_handling() {
        let alt = KeyMods { alt: true, ..NONE };
        // Default: Option composes characters (macOS behavior).
        assert_eq!(enc("f", Some("ƒ"), alt), Some("ƒ".as_bytes().to_vec()));
        let meta = KeyContext {
            option_as_meta: true,
            ..KeyContext::default()
        };
        assert_eq!(
            encode_key("f", Some("ƒ"), alt, meta),
            Some(b"\x1bf".to_vec())
        );
        assert_eq!(enc("backspace", None, alt), Some(vec![0x1b, 0x7f]));
        assert_eq!(enc("enter", None, alt), Some(b"\x1b\r".to_vec()));
    }

    #[test]
    fn option_routing_follows_swift() {
        let alt = KeyMods { alt: true, ..NONE };
        // AZERTY Option+5 types "[" (base key "("): text.
        assert!(option_types_text("(", Some("["), alt));
        // Option+B is Meta even though it composes a character.
        assert!(!option_types_text("b", Some("\u{222B}"), alt));
        // US Option+5 composes a non-ASCII character: Meta.
        assert!(!option_types_text("5", Some("\u{221E}"), alt));
        assert!(!option_types_text("space", Some("\u{A0}"), alt));
        // Without Option nothing is rerouted.
        assert!(!option_types_text("(", Some("["), NONE));
        let meta = KeyContext {
            option_as_meta: true,
            ..KeyContext::default()
        };
        let shift_alt = KeyMods {
            shift: true,
            alt: true,
            ..NONE
        };
        assert_eq!(
            encode_key("b", Some("\u{222B}"), shift_alt, meta),
            Some(b"\x1bB".to_vec())
        );
    }

    #[test]
    fn platform_and_bare_modifiers_are_not_sent() {
        let cmd = KeyMods {
            platform: true,
            ..NONE
        };
        assert_eq!(enc("c", Some("c"), cmd), None);
        assert_eq!(enc("shift", None, NONE), None);
    }

    #[test]
    fn paste_encoding() {
        assert_eq!(encode_paste("a\nb", false), b"a\rb".to_vec());
        assert_eq!(
            encode_paste("x\x1b[201~y", true),
            b"\x1b[200~xy\x1b[201~".to_vec()
        );
    }

    #[test]
    fn paste_cannot_reform_end_marker_from_nested_markers() {
        let payload = "\x1b[2\x1b[201~01~; rm -rf ~\r";
        assert_eq!(
            encode_paste(payload, true),
            b"\x1b[200~; rm -rf ~\r\x1b[201~".to_vec()
        );
        let deep = "\x1b[2\x1b[2\x1b[201~01~01~tail";
        assert_eq!(
            encode_paste(deep, true),
            b"\x1b[200~tail\x1b[201~".to_vec()
        );
        // Escape sequences that are not the end marker survive.
        assert_eq!(
            encode_paste("\x1b[31mred\x1b[0m", true),
            b"\x1b[200~\x1b[31mred\x1b[0m\x1b[201~".to_vec()
        );
        // Unbracketed paste is passed through untouched apart from newlines.
        assert_eq!(
            encode_paste("a\x1b[201~b", false),
            b"a\x1b[201~b".to_vec()
        );
    }
}

/// Mouse buttons for terminal mouse reporting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButtonCode {
    Left,
    Middle,
    Right,
    /// Motion with no button pressed.
    None,
    WheelUp,
    WheelDown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

/// `chau7_terminal::Chau7Terminal::mouse_mode` bits.
pub mod mouse_mode {
    pub const CLICK: u32 = 1;
    pub const DRAG: u32 = 2;
    pub const MOTION: u32 = 4;
    pub const FOCUS: u32 = 8;
    pub const SGR: u32 = 16;
}

/// Encode a mouse event for an application that enabled mouse reporting
/// (vim, tmux, htop...). `col`/`row` are 0-based grid cells. Returns `None`
/// when the current mode does not report this event.
pub fn encode_mouse(
    button: MouseButtonCode,
    action: MouseAction,
    col: u16,
    row: u16,
    mods: KeyMods,
    mode: u32,
) -> Option<Vec<u8>> {
    use mouse_mode::*;
    if mode & (CLICK | DRAG | MOTION) == 0 {
        return None;
    }
    if action == MouseAction::Motion {
        let dragging = button != MouseButtonCode::None;
        let wanted = if dragging {
            mode & (DRAG | MOTION) != 0
        } else {
            mode & MOTION != 0
        };
        if !wanted {
            return None;
        }
    }
    let sgr = mode & SGR != 0;
    let mut code: u32 = match button {
        MouseButtonCode::Left => 0,
        MouseButtonCode::Middle => 1,
        MouseButtonCode::Right => 2,
        MouseButtonCode::None => 3,
        MouseButtonCode::WheelUp => 64,
        MouseButtonCode::WheelDown => 65,
    };
    if action == MouseAction::Release && !sgr {
        code = 3;
    }
    if action == MouseAction::Motion {
        code += 32;
    }
    if mods.shift {
        code += 4;
    }
    if mods.alt {
        code += 8;
    }
    if mods.control {
        code += 16;
    }
    let (x, y) = (col as u32 + 1, row as u32 + 1);
    if sgr {
        let final_byte = if action == MouseAction::Release {
            'm'
        } else {
            'M'
        };
        return Some(format!("\x1b[<{code};{x};{y}{final_byte}").into_bytes());
    }
    // X10/normal encoding: values offset by 32, limited to one byte.
    if x > 223 || y > 223 {
        return None;
    }
    Some(vec![
        0x1b,
        b'[',
        b'M',
        (32 + code) as u8,
        (32 + x) as u8,
        (32 + y) as u8,
    ])
}

#[cfg(test)]
mod mouse_tests {
    use super::*;

    const NONE: KeyMods = KeyMods {
        shift: false,
        alt: false,
        control: false,
        platform: false,
    };

    #[test]
    fn sgr_press_release() {
        let mode = mouse_mode::CLICK | mouse_mode::SGR;
        assert_eq!(
            encode_mouse(MouseButtonCode::Left, MouseAction::Press, 0, 0, NONE, mode),
            Some(b"\x1b[<0;1;1M".to_vec())
        );
        assert_eq!(
            encode_mouse(
                MouseButtonCode::Left,
                MouseAction::Release,
                4,
                9,
                NONE,
                mode
            ),
            Some(b"\x1b[<0;5;10m".to_vec())
        );
    }

    #[test]
    fn normal_encoding_and_release() {
        let mode = mouse_mode::CLICK;
        assert_eq!(
            encode_mouse(MouseButtonCode::Right, MouseAction::Press, 0, 0, NONE, mode),
            Some(vec![0x1b, b'[', b'M', 34, 33, 33])
        );
        assert_eq!(
            encode_mouse(
                MouseButtonCode::Right,
                MouseAction::Release,
                0,
                0,
                NONE,
                mode
            ),
            Some(vec![0x1b, b'[', b'M', 35, 33, 33])
        );
    }

    #[test]
    fn motion_needs_the_right_mode() {
        let click = mouse_mode::CLICK | mouse_mode::SGR;
        assert_eq!(
            encode_mouse(
                MouseButtonCode::Left,
                MouseAction::Motion,
                1,
                1,
                NONE,
                click
            ),
            None
        );
        let drag = click | mouse_mode::DRAG;
        assert_eq!(
            encode_mouse(MouseButtonCode::Left, MouseAction::Motion, 1, 1, NONE, drag),
            Some(b"\x1b[<32;2;2M".to_vec())
        );
        assert_eq!(
            encode_mouse(MouseButtonCode::None, MouseAction::Motion, 1, 1, NONE, drag),
            None
        );
    }

    #[test]
    fn wheel_and_modifiers() {
        let mode = mouse_mode::CLICK | mouse_mode::SGR;
        let ctrl = KeyMods {
            control: true,
            ..NONE
        };
        assert_eq!(
            encode_mouse(
                MouseButtonCode::WheelUp,
                MouseAction::Press,
                0,
                0,
                ctrl,
                mode
            ),
            Some(b"\x1b[<80;1;1M".to_vec())
        );
    }

    #[test]
    fn off_when_no_tracking() {
        assert_eq!(
            encode_mouse(
                MouseButtonCode::Left,
                MouseAction::Press,
                0,
                0,
                NONE,
                mouse_mode::SGR
            ),
            None
        );
    }
}
