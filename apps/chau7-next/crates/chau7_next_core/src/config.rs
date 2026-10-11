//! Port of `apps/chau7-macos/Sources/Chau7Core/ConfigFileParser.swift`.
//!
//! Hand-written parser for the TOML-like `~/.chau7/config.toml` (and per-repo
//! `.chau7/config.toml`) format: `[sections]`, `key = value` pairs, `#` and
//! `//` comments, and basic type inference (bool, integer, double, string).
//!
//! Behavior intentionally mirrors the Swift parser, including its quirks:
//! malformed lines are skipped silently, quoted values are not unescaped on
//! read (even though `serialize` escapes them on write), duplicate keys and
//! sections merge with last-wins semantics, and `parse` always returns
//! `profiles: Some(..)` (possibly empty).
//!
//! The two default configs written by the macOS `ConfigFileWatcher`
//! (`createDefaultConfig` and `createRepoConfig`) are exposed as
//! [`Chau7ConfigFile::default_global`] and [`Chau7ConfigFile::default_repo`],
//! and its read-then-parse step as [`load`].

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::path::Path;

/// Name of the implicit section that holds keys appearing before any header.
pub const GLOBAL_SECTION: &str = "__global__";

/// Parsed configuration from a `.chau7` config file.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Chau7ConfigFile {
    pub general: Option<GeneralConfig>,
    pub appearance: Option<AppearanceConfig>,
    pub terminal: Option<TerminalConfig>,
    pub keybindings: Option<BTreeMap<String, String>>,
    pub profiles: Option<BTreeMap<String, ProfileConfig>>,
}

/// `[general]` section.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GeneralConfig {
    pub shell: Option<String>,
    pub startup_command: Option<String>,
    pub default_directory: Option<String>,
    pub close_on_exit: Option<bool>,
    pub confirm_close: Option<bool>,
}

/// `[appearance]` section.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AppearanceConfig {
    pub font_family: Option<String>,
    pub font_size: Option<i64>,
    pub color_scheme: Option<String>,
    pub cursor_style: Option<String>,
    pub cursor_blink: Option<bool>,
    pub opacity: Option<f64>,
    pub minimal_mode: Option<bool>,
}

/// `[terminal]` section.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct TerminalConfig {
    pub scrollback_lines: Option<i64>,
    pub bell_enabled: Option<bool>,
    pub bell_sound: Option<String>,
    pub word_wrap: Option<bool>,
    pub mouse_reporting: Option<bool>,
    pub sixel_enabled: Option<bool>,
    pub kitty_graphics: Option<bool>,
}

/// `[profile.<name>]` section.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ProfileConfig {
    pub font_family: Option<String>,
    pub font_size: Option<i64>,
    pub color_scheme: Option<String>,
    pub shell: Option<String>,
}

impl Chau7ConfigFile {
    /// The config `ConfigFileWatcher.createDefaultConfig()` writes to
    /// `~/.chau7/config.toml`.
    pub fn default_global() -> Self {
        Chau7ConfigFile {
            general: Some(GeneralConfig::default()),
            appearance: Some(AppearanceConfig {
                font_family: Some("Menlo".to_string()),
                font_size: Some(13),
                cursor_style: Some("block".to_string()),
                ..AppearanceConfig::default()
            }),
            terminal: Some(TerminalConfig {
                scrollback_lines: Some(10000),
                bell_enabled: Some(true),
                ..TerminalConfig::default()
            }),
            keybindings: None,
            profiles: None,
        }
    }

    /// The config `ConfigFileWatcher.createRepoConfig(directory:)` writes to
    /// `<repo>/.chau7/config.toml` (empty sections only).
    pub fn default_repo() -> Self {
        Chau7ConfigFile {
            general: Some(GeneralConfig::default()),
            appearance: Some(AppearanceConfig::default()),
            terminal: Some(TerminalConfig::default()),
            keybindings: None,
            profiles: None,
        }
    }
}

/// Errors declared by the Swift parser. The parser itself never returns them
/// (malformed input is skipped silently); they are kept for API parity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    InvalidLine(usize, String),
    DuplicateSection(String),
    InvalidValue(String, String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::InvalidLine(line, content) => {
                write!(f, "Invalid config at line {line}: {content}")
            }
            ParseError::DuplicateSection(name) => write!(f, "Duplicate config section: [{name}]"),
            ParseError::InvalidValue(key, value) => {
                write!(f, "Invalid value for '{key}': {value}")
            }
        }
    }
}

impl std::error::Error for ParseError {}

/// A raw, type-inferred value (the Swift `Any` produced by `inferType`).
#[derive(Debug, Clone, PartialEq)]
pub enum RawValue {
    Bool(bool),
    Int(i64),
    Double(f64),
    String(String),
}

impl RawValue {
    /// Equivalent of Swift `as? Bool`.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            RawValue::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// Equivalent of Swift `as? Int`.
    pub fn as_int(&self) -> Option<i64> {
        match self {
            RawValue::Int(i) => Some(*i),
            _ => None,
        }
    }

    /// Equivalent of Swift `as? Double` (an inferred `Int` does not convert).
    pub fn as_double(&self) -> Option<f64> {
        match self {
            RawValue::Double(d) => Some(*d),
            _ => None,
        }
    }

    /// Equivalent of Swift `as? String`.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            RawValue::String(s) => Some(s),
            _ => None,
        }
    }
}

/// Section name to (key to value) map returned by [`parse_raw`].
pub type RawConfig = HashMap<String, HashMap<String, RawValue>>;

/// Foundation `CharacterSet.whitespaces`: Unicode category Z* plus tab.
fn is_swift_whitespace(c: char) -> bool {
    c == '\t' || (c.is_whitespace() && !matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}'))
}

/// Foundation `CharacterSet.newlines`.
fn is_swift_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

fn trim_ws(s: &str) -> &str {
    s.trim_matches(is_swift_whitespace)
}

/// Drops the first and last character, like Swift `dropFirst().dropLast()`.
fn drop_first_last(s: &str) -> &str {
    let mut chars = s.chars();
    chars.next();
    chars.next_back();
    chars.as_str()
}

fn escape_value(v: &str) -> String {
    v.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

/// Parse TOML-like config content into a section/key/value structure.
/// Keys outside any section land in [`GLOBAL_SECTION`].
pub fn parse_raw(content: &str) -> RawConfig {
    let mut sections: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut current_section = GLOBAL_SECTION.to_string();
    sections.insert(current_section.clone(), HashMap::new());

    for line in content.split(is_swift_newline) {
        let trimmed = trim_ws(line);

        // Skip empty lines and comments
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with("//") {
            continue;
        }

        // Section header
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            let name = trim_ws(drop_first_last(trimmed)).to_string();
            sections.entry(name.clone()).or_default();
            current_section = name;
            continue;
        }

        // Key = Value
        let Some(eq_idx) = trimmed.find('=') else {
            continue; // Skip malformed lines silently
        };

        let key = trim_ws(&trimmed[..eq_idx]).to_string();
        let raw_value = trim_ws(&trimmed[eq_idx + 1..]);

        // Strip quotes from string values
        let value = if (raw_value.starts_with('"') && raw_value.ends_with('"'))
            || (raw_value.starts_with('\'') && raw_value.ends_with('\''))
        {
            drop_first_last(raw_value)
        } else {
            raw_value
        };

        sections
            .entry(current_section.clone())
            .or_default()
            .insert(key, value.to_string());
    }

    // Convert with type inference
    sections
        .into_iter()
        .map(|(section, pairs)| {
            let converted = pairs
                .into_iter()
                .map(|(k, v)| {
                    let inferred = infer_type(&v);
                    (k, inferred)
                })
                .collect();
            (section, converted)
        })
        .collect()
}

fn get_str(map: &HashMap<String, RawValue>, key: &str) -> Option<String> {
    map.get(key).and_then(RawValue::as_str).map(str::to_string)
}

fn get_int(map: &HashMap<String, RawValue>, key: &str) -> Option<i64> {
    map.get(key).and_then(RawValue::as_int)
}

fn get_bool(map: &HashMap<String, RawValue>, key: &str) -> Option<bool> {
    map.get(key).and_then(RawValue::as_bool)
}

fn get_double(map: &HashMap<String, RawValue>, key: &str) -> Option<f64> {
    map.get(key).and_then(RawValue::as_double)
}

/// Parse config content into a typed [`Chau7ConfigFile`].
pub fn parse(content: &str) -> Chau7ConfigFile {
    let mut config = Chau7ConfigFile::default();
    let raw = parse_raw(content);

    if let Some(general) = raw.get("general") {
        config.general = Some(GeneralConfig {
            shell: get_str(general, "shell"),
            startup_command: get_str(general, "startup_command"),
            default_directory: get_str(general, "default_directory"),
            close_on_exit: get_bool(general, "close_on_exit"),
            confirm_close: get_bool(general, "confirm_close"),
        });
    }

    if let Some(appearance) = raw.get("appearance") {
        config.appearance = Some(AppearanceConfig {
            font_family: get_str(appearance, "font_family"),
            font_size: get_int(appearance, "font_size"),
            color_scheme: get_str(appearance, "color_scheme"),
            cursor_style: get_str(appearance, "cursor_style"),
            cursor_blink: get_bool(appearance, "cursor_blink"),
            opacity: get_double(appearance, "opacity"),
            minimal_mode: get_bool(appearance, "minimal_mode"),
        });
    }

    if let Some(terminal) = raw.get("terminal") {
        config.terminal = Some(TerminalConfig {
            scrollback_lines: get_int(terminal, "scrollback_lines"),
            bell_enabled: get_bool(terminal, "bell_enabled"),
            bell_sound: get_str(terminal, "bell_sound"),
            word_wrap: get_bool(terminal, "word_wrap"),
            mouse_reporting: get_bool(terminal, "mouse_reporting"),
            sixel_enabled: get_bool(terminal, "sixel_enabled"),
            kitty_graphics: get_bool(terminal, "kitty_graphics"),
        });
    }

    if let Some(keybindings) = raw.get("keybindings") {
        config.keybindings = Some(
            keybindings
                .iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect(),
        );
    }

    // Parse [profile.name] sections
    let mut profiles = BTreeMap::new();
    for (key, values) in &raw {
        if let Some(profile_name) = key.strip_prefix("profile.") {
            profiles.insert(
                profile_name.to_string(),
                ProfileConfig {
                    font_family: get_str(values, "font_family"),
                    font_size: get_int(values, "font_size"),
                    color_scheme: get_str(values, "color_scheme"),
                    shell: get_str(values, "shell"),
                },
            );
        }
    }
    config.profiles = Some(profiles);

    config
}

/// Read and parse a config file. Returns `None` when the file cannot be read
/// as UTF-8 text (mirrors `try? String(contentsOfFile:encoding: .utf8)` in
/// `ConfigFileWatcher`).
pub fn load(path: &Path) -> Option<Chau7ConfigFile> {
    std::fs::read_to_string(path).ok().map(|s| parse(&s))
}

/// Serialize a config file back to the TOML-like format.
pub fn serialize(config: &Chau7ConfigFile) -> String {
    let mut lines: Vec<String> = vec![
        "# Chau7 Configuration".to_string(),
        "# https://github.com/your/chau7".to_string(),
        String::new(),
    ];

    fn push_str(lines: &mut Vec<String>, key: &str, v: &Option<String>) {
        if let Some(v) = v {
            lines.push(format!("{key} = \"{}\"", escape_value(v)));
        }
    }
    fn push_display<T: fmt::Display>(lines: &mut Vec<String>, key: &str, v: &Option<T>) {
        if let Some(v) = v {
            lines.push(format!("{key} = {v}"));
        }
    }

    if let Some(g) = &config.general {
        lines.push("[general]".to_string());
        push_str(&mut lines, "shell", &g.shell);
        push_str(&mut lines, "startup_command", &g.startup_command);
        push_str(&mut lines, "default_directory", &g.default_directory);
        push_display(&mut lines, "close_on_exit", &g.close_on_exit);
        push_display(&mut lines, "confirm_close", &g.confirm_close);
        lines.push(String::new());
    }

    if let Some(a) = &config.appearance {
        lines.push("[appearance]".to_string());
        push_str(&mut lines, "font_family", &a.font_family);
        push_display(&mut lines, "font_size", &a.font_size);
        push_str(&mut lines, "color_scheme", &a.color_scheme);
        push_str(&mut lines, "cursor_style", &a.cursor_style);
        push_display(&mut lines, "cursor_blink", &a.cursor_blink);
        if let Some(v) = a.opacity {
            lines.push(format!("opacity = {}", swift_double_description(v)));
        }
        push_display(&mut lines, "minimal_mode", &a.minimal_mode);
        lines.push(String::new());
    }

    if let Some(t) = &config.terminal {
        lines.push("[terminal]".to_string());
        push_display(&mut lines, "scrollback_lines", &t.scrollback_lines);
        push_display(&mut lines, "bell_enabled", &t.bell_enabled);
        push_str(&mut lines, "bell_sound", &t.bell_sound);
        push_display(&mut lines, "word_wrap", &t.word_wrap);
        push_display(&mut lines, "mouse_reporting", &t.mouse_reporting);
        push_display(&mut lines, "sixel_enabled", &t.sixel_enabled);
        push_display(&mut lines, "kitty_graphics", &t.kitty_graphics);
        lines.push(String::new());
    }

    if let Some(kb) = &config.keybindings
        && !kb.is_empty()
    {
        lines.push("[keybindings]".to_string());
        // BTreeMap iterates in sorted key order, like Swift's sorted(by:).
        for (key, value) in kb {
            lines.push(format!("{key} = \"{}\"", escape_value(value)));
        }
        lines.push(String::new());
    }

    if let Some(profiles) = &config.profiles {
        for (name, p) in profiles {
            lines.push(format!("[profile.{name}]"));
            push_str(&mut lines, "font_family", &p.font_family);
            push_display(&mut lines, "font_size", &p.font_size);
            push_str(&mut lines, "color_scheme", &p.color_scheme);
            push_str(&mut lines, "shell", &p.shell);
            lines.push(String::new());
        }
    }

    lines.join("\n")
}

/// Formats a `f64` like Swift's `Double.description`: shortest round-trip
/// digits, a `.0` for integral values, and exponents written as `e-05`.
/// The switch to exponential notation for large magnitudes may differ from
/// Swift for |v| between 1e16 and 2^54 (irrelevant for opacity values).
fn swift_double_description(v: f64) -> String {
    if v.is_nan() {
        return "nan".to_string();
    }
    if v.is_infinite() {
        return if v > 0.0 { "inf" } else { "-inf" }.to_string();
    }
    // Rust's Debug output uses the same shortest digits and switches to
    // exponential below 1e-4, like Swift.
    let s = format!("{v:?}");
    match s.split_once('e') {
        None => s,
        Some((mantissa, exp)) => {
            let (sign, digits) = match exp.strip_prefix('-') {
                Some(d) => ('-', d),
                None => ('+', exp),
            };
            format!("{mantissa}e{sign}{digits:0>2}")
        }
    }
}

/// Swift `Int(String)`: optional sign followed by ASCII digits only.
fn parse_swift_int(value: &str) -> Option<i64> {
    let digits = value.strip_prefix(['+', '-']).unwrap_or(value);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    value.parse::<i64>().ok()
}

fn infer_type(value: &str) -> RawValue {
    // Boolean
    let lower = value.to_lowercase();
    if lower == "true" {
        return RawValue::Bool(true);
    }
    if lower == "false" {
        return RawValue::Bool(false);
    }

    // Integer
    if let Some(i) = parse_swift_int(value) {
        return RawValue::Int(i);
    }

    // Double
    if value.contains('.')
        && let Ok(d) = value.parse::<f64>()
    {
        return RawValue::Double(d);
    }

    // String (default)
    RawValue::String(value.to_string())
}

#[cfg(test)]
mod tests {
    //! Ported from `Tests/Chau7Tests/Utilities/ConfigFileParserTests.swift`.
    //! All 27 Swift tests are ported; none skipped. A few extra tests cover
    //! Rust-specific helpers (double formatting, defaults, load).

    use super::*;

    fn s(v: &str) -> Option<String> {
        Some(v.to_string())
    }

    fn raw_str<'a>(raw: &'a RawConfig, section: &str, key: &str) -> Option<&'a str> {
        raw.get(section)?.get(key)?.as_str()
    }

    // MARK: - Section Headers

    #[test]
    fn parse_section_headers() {
        let content = "[general]\nshell = \"/bin/zsh\"\n\n[appearance]\nfont_size = 14";
        let raw = parse_raw(content);
        assert!(raw.contains_key("general"));
        assert!(raw.contains_key("appearance"));
    }

    #[test]
    fn parse_section_header_with_spaces() {
        let raw = parse_raw("[ general ]\nshell = \"/bin/zsh\"");
        assert!(raw.contains_key("general"));
    }

    // MARK: - Key Value Pairs

    #[test]
    fn parse_key_value_pairs() {
        let raw = parse_raw("[general]\nshell = \"/bin/zsh\"\nstartup_command = \"neofetch\"");
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
        assert_eq!(
            raw_str(&raw, "general", "startup_command"),
            Some("neofetch")
        );
    }

    #[test]
    fn parse_key_value_without_spaces() {
        let raw = parse_raw("[general]\nshell=\"/bin/zsh\"");
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
    }

    // MARK: - String Values

    #[test]
    fn parse_double_quoted_string() {
        let raw = parse_raw("[general]\nshell = \"/bin/zsh\"");
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
    }

    #[test]
    fn parse_single_quoted_string() {
        let raw = parse_raw("[general]\nshell = '/bin/zsh'");
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
    }

    #[test]
    fn parse_unquoted_string() {
        let raw = parse_raw("[appearance]\ncursor_style = block");
        assert_eq!(raw_str(&raw, "appearance", "cursor_style"), Some("block"));
    }

    // MARK: - Boolean Values

    #[test]
    fn parse_boolean_true() {
        let raw = parse_raw("[terminal]\nbell_enabled = true");
        assert_eq!(raw["terminal"]["bell_enabled"].as_bool(), Some(true));
    }

    #[test]
    fn parse_boolean_false() {
        let raw = parse_raw("[terminal]\nbell_enabled = false");
        assert_eq!(raw["terminal"]["bell_enabled"].as_bool(), Some(false));
    }

    #[test]
    fn parse_boolean_case_insensitive() {
        let raw = parse_raw("[terminal]\nbell_enabled = True\nword_wrap = FALSE");
        assert_eq!(raw["terminal"]["bell_enabled"].as_bool(), Some(true));
        assert_eq!(raw["terminal"]["word_wrap"].as_bool(), Some(false));
    }

    // MARK: - Integer Values

    #[test]
    fn parse_integer() {
        let raw = parse_raw("[terminal]\nscrollback_lines = 10000");
        assert_eq!(raw["terminal"]["scrollback_lines"].as_int(), Some(10000));
    }

    #[test]
    fn parse_zero_integer() {
        let raw = parse_raw("[terminal]\nscrollback_lines = 0");
        assert_eq!(raw["terminal"]["scrollback_lines"].as_int(), Some(0));
    }

    // MARK: - Double Values

    #[test]
    fn parse_double() {
        let raw = parse_raw("[appearance]\nopacity = 0.85");
        assert_eq!(raw["appearance"]["opacity"].as_double(), Some(0.85));
    }

    #[test]
    fn parse_double_one_point_zero() {
        let raw = parse_raw("[appearance]\nopacity = 1.0");
        assert_eq!(raw["appearance"]["opacity"].as_double(), Some(1.0));
    }

    // MARK: - Comments

    #[test]
    fn parse_hash_comments() {
        let raw =
            parse_raw("# This is a comment\n[general]\n# Another comment\nshell = \"/bin/zsh\"");
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
        assert_eq!(raw["general"].len(), 1);
    }

    #[test]
    fn parse_slash_slash_comments() {
        let raw =
            parse_raw("// This is a comment\n[general]\n// Another comment\nshell = \"/bin/zsh\"");
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
        assert_eq!(raw["general"].len(), 1);
    }

    // MARK: - Empty Lines

    #[test]
    fn parse_empty_lines() {
        let raw =
            parse_raw("[general]\n\nshell = \"/bin/zsh\"\n\nstartup_command = \"neofetch\"\n\n");
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
        assert_eq!(
            raw_str(&raw, "general", "startup_command"),
            Some("neofetch")
        );
    }

    #[test]
    fn parse_empty_content() {
        let config = parse("");
        assert!(config.general.is_none());
        assert!(config.appearance.is_none());
        assert!(config.terminal.is_none());
    }

    // MARK: - Profile Sections

    #[test]
    fn parse_profile_sections() {
        let content = "[profile.work]\nfont_family = \"SF Mono\"\nfont_size = 12\ncolor_scheme = \"Solarized Dark\"\n\n[profile.personal]\nfont_family = \"Menlo\"\nfont_size = 14\nshell = \"/bin/fish\"";
        let config = parse(content);
        let profiles = config.profiles.unwrap();
        let work = &profiles["work"];
        assert_eq!(work.font_family, s("SF Mono"));
        assert_eq!(work.font_size, Some(12));
        assert_eq!(work.color_scheme, s("Solarized Dark"));

        let personal = &profiles["personal"];
        assert_eq!(personal.font_family, s("Menlo"));
        assert_eq!(personal.font_size, Some(14));
        assert_eq!(personal.shell, s("/bin/fish"));
    }

    // MARK: - Serialization Round-Trip

    #[test]
    fn serialization_round_trip() {
        let original = Chau7ConfigFile {
            general: Some(GeneralConfig {
                shell: s("/bin/zsh"),
                startup_command: s("neofetch"),
                close_on_exit: Some(true),
                ..Default::default()
            }),
            appearance: Some(AppearanceConfig {
                font_family: s("Menlo"),
                font_size: Some(13),
                cursor_style: s("block"),
                cursor_blink: Some(false),
                opacity: Some(0.95),
                ..Default::default()
            }),
            terminal: Some(TerminalConfig {
                scrollback_lines: Some(10000),
                bell_enabled: Some(true),
                bell_sound: s("default"),
                ..Default::default()
            }),
            keybindings: Some(BTreeMap::from([
                ("cmd+t".to_string(), "newTab".to_string()),
                ("cmd+w".to_string(), "closeTab".to_string()),
            ])),
            profiles: Some(BTreeMap::from([(
                "work".to_string(),
                ProfileConfig {
                    font_family: s("SF Mono"),
                    font_size: Some(12),
                    ..Default::default()
                },
            )])),
        };

        let serialized = serialize(&original);
        let parsed = parse(&serialized);

        let (pg, og) = (parsed.general.unwrap(), original.general.unwrap());
        assert_eq!(pg.shell, og.shell);
        assert_eq!(pg.startup_command, og.startup_command);
        assert_eq!(pg.close_on_exit, og.close_on_exit);
        let (pa, oa) = (parsed.appearance.unwrap(), original.appearance.unwrap());
        assert_eq!(pa.font_family, oa.font_family);
        assert_eq!(pa.font_size, oa.font_size);
        assert_eq!(pa.cursor_style, oa.cursor_style);
        assert_eq!(pa.cursor_blink, oa.cursor_blink);
        assert_eq!(pa.opacity, oa.opacity);
        let (pt, ot) = (parsed.terminal.unwrap(), original.terminal.unwrap());
        assert_eq!(pt.scrollback_lines, ot.scrollback_lines);
        assert_eq!(pt.bell_enabled, ot.bell_enabled);
        assert_eq!(pt.bell_sound, ot.bell_sound);
        assert_eq!(parsed.keybindings, original.keybindings);
        let profiles = parsed.profiles.unwrap();
        assert_eq!(profiles["work"].font_family, s("SF Mono"));
        assert_eq!(profiles["work"].font_size, Some(12));
    }

    // MARK: - parseRaw Type Inference

    #[test]
    fn parse_raw_returns_correct_types() {
        let content = "[mixed]\nstr_val = \"hello\"\nint_val = 42\nbool_val = true\ndouble_val = 3.14\nunquoted_str = world";
        let raw = parse_raw(content);
        let section = &raw["mixed"];

        assert!(matches!(section["str_val"], RawValue::String(_)));
        assert_eq!(section["str_val"].as_str(), Some("hello"));

        assert!(matches!(section["int_val"], RawValue::Int(_)));
        assert_eq!(section["int_val"].as_int(), Some(42));

        assert!(matches!(section["bool_val"], RawValue::Bool(_)));
        assert_eq!(section["bool_val"].as_bool(), Some(true));

        assert!(matches!(section["double_val"], RawValue::Double(_)));
        #[allow(clippy::approx_constant)]
        let expected = 3.14;
        assert_eq!(section["double_val"].as_double(), Some(expected));

        assert!(matches!(section["unquoted_str"], RawValue::String(_)));
        assert_eq!(section["unquoted_str"].as_str(), Some("world"));
    }

    // MARK: - Typed Chau7ConfigFile

    #[test]
    fn parse_into_typed_config() {
        let content = r#"[general]
shell = "/bin/zsh"
startup_command = "neofetch"
default_directory = "~/Projects"
close_on_exit = true
confirm_close = false

[appearance]
font_family = "Menlo"
font_size = 13
color_scheme = "Solarized Dark"
cursor_style = "beam"
cursor_blink = true
opacity = 0.9
minimal_mode = false

[terminal]
scrollback_lines = 5000
bell_enabled = false
bell_sound = "ping"
word_wrap = true
mouse_reporting = true
sixel_enabled = false
kitty_graphics = true

[keybindings]
cmd+t = "newTab"
cmd+w = "closeTab""#;
        let config = parse(content);

        let g = config.general.unwrap();
        assert_eq!(g.shell, s("/bin/zsh"));
        assert_eq!(g.startup_command, s("neofetch"));
        assert_eq!(g.default_directory, s("~/Projects"));
        assert_eq!(g.close_on_exit, Some(true));
        assert_eq!(g.confirm_close, Some(false));

        let a = config.appearance.unwrap();
        assert_eq!(a.font_family, s("Menlo"));
        assert_eq!(a.font_size, Some(13));
        assert_eq!(a.color_scheme, s("Solarized Dark"));
        assert_eq!(a.cursor_style, s("beam"));
        assert_eq!(a.cursor_blink, Some(true));
        assert_eq!(a.opacity, Some(0.9));
        assert_eq!(a.minimal_mode, Some(false));

        let t = config.terminal.unwrap();
        assert_eq!(t.scrollback_lines, Some(5000));
        assert_eq!(t.bell_enabled, Some(false));
        assert_eq!(t.bell_sound, s("ping"));
        assert_eq!(t.word_wrap, Some(true));
        assert_eq!(t.mouse_reporting, Some(true));
        assert_eq!(t.sixel_enabled, Some(false));
        assert_eq!(t.kitty_graphics, Some(true));

        let kb = config.keybindings.unwrap();
        assert_eq!(kb.get("cmd+t").map(String::as_str), Some("newTab"));
        assert_eq!(kb.get("cmd+w").map(String::as_str), Some("closeTab"));
    }

    // MARK: - Global Keys (no section)

    #[test]
    fn parse_global_keys_outside_section() {
        let raw = parse_raw("some_key = \"some_value\"\n\n[general]\nshell = \"/bin/zsh\"");
        assert_eq!(
            raw_str(&raw, GLOBAL_SECTION, "some_key"),
            Some("some_value")
        );
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
    }

    // MARK: - Malformed Lines

    #[test]
    fn skips_malformed_lines() {
        let raw = parse_raw(
            "[general]\nshell = \"/bin/zsh\"\nthis has no equals sign\nstartup_command = \"neofetch\"",
        );
        assert_eq!(raw_str(&raw, "general", "shell"), Some("/bin/zsh"));
        assert_eq!(
            raw_str(&raw, "general", "startup_command"),
            Some("neofetch")
        );
        assert_eq!(raw["general"].len(), 2);
    }

    // MARK: - Serialize Empty Config

    #[test]
    fn serialize_empty_config() {
        let serialized = serialize(&Chau7ConfigFile::default());
        assert!(serialized.contains("# Chau7 Configuration"));
    }

    #[test]
    fn serialize_escapes_special_characters() {
        let config = Chau7ConfigFile {
            general: Some(GeneralConfig {
                shell: s("/bin/zsh"),
                startup_command: s("echo \"hello\\nworld\""),
                ..Default::default()
            }),
            ..Default::default()
        };
        let serialized = serialize(&config);
        assert!(serialized.contains("\\\\"));
        assert!(serialized.contains("\\\""));
    }

    // MARK: - Multiple Profiles

    #[test]
    fn multiple_profiles() {
        let content = "[profile.dev]\nfont_family = \"Fira Code\"\nfont_size = 14\n\n[profile.presentation]\nfont_family = \"SF Mono\"\nfont_size = 24\ncolor_scheme = \"Light\"\n\n[profile.ssh]\nshell = \"/bin/bash\"";
        let profiles = parse(content).profiles.unwrap();
        assert_eq!(profiles.len(), 3);
        assert_eq!(profiles["dev"].font_family, s("Fira Code"));
        assert_eq!(profiles["dev"].font_size, Some(14));
        assert_eq!(profiles["presentation"].font_family, s("SF Mono"));
        assert_eq!(profiles["presentation"].font_size, Some(24));
        assert_eq!(profiles["presentation"].color_scheme, s("Light"));
        assert_eq!(profiles["ssh"].shell, s("/bin/bash"));
    }

    // MARK: - Rust-port extras

    #[test]
    fn double_description_matches_swift() {
        assert_eq!(swift_double_description(1.0), "1.0");
        assert_eq!(swift_double_description(0.95), "0.95");
        assert_eq!(swift_double_description(0.0001), "0.0001");
        assert_eq!(swift_double_description(0.00001), "1e-05");
        assert_eq!(swift_double_description(1.5e-7), "1.5e-07");
    }

    #[test]
    fn integral_opacity_round_trips_as_double() {
        let config = Chau7ConfigFile {
            appearance: Some(AppearanceConfig {
                opacity: Some(1.0),
                ..Default::default()
            }),
            ..Default::default()
        };
        let parsed = parse(&serialize(&config));
        assert_eq!(parsed.appearance.unwrap().opacity, Some(1.0));
    }

    #[test]
    fn lone_quote_value_is_empty_string() {
        let raw = parse_raw("[general]\nshell = \"");
        assert_eq!(raw_str(&raw, "general", "shell"), Some(""));
    }

    #[test]
    fn int_does_not_coerce_to_double_or_string() {
        let config = parse("[appearance]\nopacity = 1\nfont_family = 12");
        let a = config.appearance.unwrap();
        assert_eq!(a.opacity, None);
        assert_eq!(a.font_family, None);
    }

    #[test]
    fn default_configs_serialize_and_reparse() {
        let parsed = parse(&serialize(&Chau7ConfigFile::default_global()));
        let a = parsed.appearance.unwrap();
        assert_eq!(a.font_family, s("Menlo"));
        assert_eq!(a.font_size, Some(13));
        assert_eq!(a.cursor_style, s("block"));
        let t = parsed.terminal.unwrap();
        assert_eq!(t.scrollback_lines, Some(10000));
        assert_eq!(t.bell_enabled, Some(true));

        let repo = serialize(&Chau7ConfigFile::default_repo());
        assert!(repo.contains("[general]\n\n[appearance]\n\n[terminal]\n"));
    }

    #[test]
    fn load_missing_file_returns_none() {
        assert!(load(Path::new("/nonexistent/chau7/config.toml")).is_none());
    }

    #[test]
    fn parse_error_messages() {
        assert_eq!(
            ParseError::InvalidLine(3, "x".into()).to_string(),
            "Invalid config at line 3: x"
        );
        assert_eq!(
            ParseError::DuplicateSection("general".into()).to_string(),
            "Duplicate config section: [general]"
        );
        assert_eq!(
            ParseError::InvalidValue("k".into(), "v".into()).to_string(),
            "Invalid value for 'k': v"
        );
    }
}
