//! Import of Terminal.app and iTerm2 profiles (Migration module):
//! `Migration/TerminalMigrationWizard.swift` (`scanTerminalApp`,
//! `scanITerm2`, `ImportableProfile`, `ProfileSource`) and the step logic of
//! `TerminalMigrationWizardView.swift`.
//!
//! Both apps keep their profiles in a property list in `~/Library/Preferences`.
//! The files are only read. Swift decodes the fonts and colors of Terminal.app
//! with `NSKeyedUnarchiver`; here the archive is read directly
//! ([`decode_font`], [`decode_color`]). Colors are taken as stored (Swift
//! converts them to sRGB first, which can shift a channel by a few units for
//! calibrated colors).

use std::path::Path;

use plist::{Dictionary, Value};
use uuid::Uuid;

/// Terminal.app preferences, relative to the home folder.
pub const TERMINAL_APP_PLIST: &str = "Library/Preferences/com.apple.Terminal.plist";
/// iTerm2 preferences, relative to the home folder.
pub const ITERM2_PLIST: &str = "Library/Preferences/com.googlecode.iterm2.plist";

/// Prefix of the settings profiles the import creates.
pub const IMPORTED_PREFIX: &str = "Imported: ";

/// Where a profile comes from (`ProfileSource`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileSource {
    TerminalApp,
    ITerm2,
}

impl ProfileSource {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::TerminalApp => "terminal",
            Self::ITerm2 => "iterm2",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::TerminalApp => "Terminal.app",
            Self::ITerm2 => "iTerm2",
        }
    }

    /// SF Symbol name in Swift.
    pub fn icon(self) -> &'static str {
        match self {
            Self::TerminalApp => "terminal",
            Self::ITerm2 => "rectangle.split.3x1",
        }
    }
}

/// A profile found in another terminal (`ImportableProfile`).
#[derive(Debug, Clone, PartialEq)]
pub struct ImportableProfile {
    pub id: Uuid,
    pub name: String,
    pub source: ProfileSource,
    pub font_family: Option<String>,
    pub font_size: Option<i64>,
    /// `#RRGGBB`.
    pub background_color: Option<String>,
    /// `#RRGGBB`.
    pub foreground_color: Option<String>,
    /// `block`, `underline` or `bar`.
    pub cursor_style: Option<String>,
    pub columns: Option<i64>,
    pub rows: Option<i64>,
    pub shell: Option<String>,
    pub directory: Option<String>,
}

impl ImportableProfile {
    pub fn new(name: impl Into<String>, source: ProfileSource) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            source,
            font_family: None,
            font_size: None,
            background_color: None,
            foreground_color: None,
            cursor_style: None,
            columns: None,
            rows: None,
            shell: None,
            directory: None,
        }
    }

    /// "Terminal.app · Menlo · 13pt" (`summary`).
    pub fn summary(&self) -> String {
        let mut parts = vec![self.source.display_name().to_string()];
        if let Some(font) = &self.font_family {
            parts.push(font.clone());
        }
        if let Some(size) = self.font_size {
            parts.push(format!("{size}pt"));
        }
        parts.join(" \u{b7} ")
    }

    /// Name of the settings profile the import creates.
    pub fn settings_profile_name(&self) -> String {
        format!("{IMPORTED_PREFIX}{}", self.name)
    }
}

// ----- colors and fonts ---------------------------------------------------------

/// `#RRGGBB` from components in 0 to 1; truncated like Swift's `Int(x * 255)`.
pub fn hex_color(r: f64, g: f64, b: f64) -> String {
    let byte = |c: f64| (c * 255.0) as i64;
    format!("#{:02X}{:02X}{:02X}", byte(r), byte(g), byte(b))
}

/// An iTerm2 color dictionary (`Red Component`, `Green Component`,
/// `Blue Component`).
fn iterm_color(dict: &Dictionary) -> Option<String> {
    let channel = |key: &str| dict.get(key).and_then(Value::as_real);
    Some(hex_color(
        channel("Red Component")?,
        channel("Green Component")?,
        channel("Blue Component")?,
    ))
}

/// The root object of an `NSKeyedArchiver` property list and the object table.
fn archive_root(data: &[u8]) -> Option<(Dictionary, Vec<Value>)> {
    let value = Value::from_reader(std::io::Cursor::new(data)).ok()?;
    let top = value.into_dictionary()?;
    let objects = top.get("$objects")?.as_array()?.clone();
    let root_uid = top
        .get("$top")?
        .as_dictionary()?
        .get("root")?
        .as_uid()?
        .get() as usize;
    let root = objects.get(root_uid)?.as_dictionary()?.clone();
    Some((root, objects))
}

/// Follow a `UID` reference into the object table.
fn resolve<'a>(value: &'a Value, objects: &'a [Value]) -> Option<&'a Value> {
    match value {
        Value::Uid(uid) => objects.get(uid.get() as usize),
        other => Some(other),
    }
}

/// Font name and point size of an archived `NSFont`.
pub fn decode_font(data: &[u8]) -> Option<(String, f64)> {
    let (root, objects) = archive_root(data)?;
    let name = resolve(root.get("NSName")?, &objects)?
        .as_string()?
        .to_string();
    let size = resolve(root.get("NSSize")?, &objects)?.as_real()?;
    Some((name, size))
}

fn ascii_floats(data: &[u8]) -> Vec<f64> {
    String::from_utf8_lossy(data)
        .trim_end_matches('\0')
        .split_whitespace()
        .filter_map(|f| f.parse().ok())
        .collect()
}

/// Red, green and blue (0 to 1) of an archived `NSColor`.
pub fn decode_color(data: &[u8]) -> Option<(f64, f64, f64)> {
    let (root, objects) = archive_root(data)?;
    let bytes = |key: &str| {
        root.get(key)
            .and_then(|v| resolve(v, &objects))
            .and_then(Value::as_data)
            .map(ascii_floats)
    };
    let space = root
        .get("NSColorSpace")
        .and_then(Value::as_signed_integer)
        .unwrap_or(1);
    // Spaces 3 and 4 are gray (calibrated and device white).
    if matches!(space, 3..=6)
        && let Some(white) = bytes("NSWhite").and_then(|w| w.first().copied())
    {
        return Some((white, white, white));
    }
    let rgb = bytes("NSRGB").or_else(|| bytes("NSComponents"))?;
    (rgb.len() >= 3).then(|| (rgb[0], rgb[1], rgb[2]))
}

/// Words that end a PostScript font name (`Menlo-Regular`).
const STYLE_WORDS: [&str; 22] = [
    "regular",
    "bold",
    "italic",
    "oblique",
    "light",
    "medium",
    "thin",
    "black",
    "heavy",
    "semibold",
    "extrabold",
    "extralight",
    "book",
    "roman",
    "condensed",
    "bolditalic",
    "lightitalic",
    "mediumitalic",
    "semilight",
    "demibold",
    "ultralight",
    "retina",
];

fn squash(name: &str) -> String {
    name.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// The family of a font from its PostScript name ("SFMono-Regular" gives
/// "SF Mono" when that family is installed). Swift asks AppKit for
/// `NSFont.familyName`; without it the style suffix is dropped and the family
/// is matched against the installed ones (`known`), else kept as written.
pub fn family_from_postscript(name: &str, known: &[String]) -> String {
    let mut parts: Vec<&str> = name.split(['-', ' ']).filter(|p| !p.is_empty()).collect();
    while parts.len() > 1
        && parts
            .last()
            .is_some_and(|p| STYLE_WORDS.contains(&p.to_lowercase().as_str()))
    {
        parts.pop();
    }
    let base = parts.join(" ");
    let key = squash(&base);
    known
        .iter()
        .find(|family| squash(family) == key)
        .cloned()
        .unwrap_or(base)
}

// ----- scanning -----------------------------------------------------------------

/// Read a property list (XML or binary); `None` when the file is missing or
/// unreadable.
pub fn read_plist(path: &Path) -> Option<Value> {
    Value::from_file(path).ok()
}

/// Profiles in `com.apple.Terminal.plist` ("Window Settings"), by name.
pub fn scan_terminal_app(plist: &Value, known_families: &[String]) -> Vec<ImportableProfile> {
    let Some(profiles) = plist
        .as_dictionary()
        .and_then(|d| d.get("Window Settings"))
        .and_then(Value::as_dictionary)
    else {
        return Vec::new();
    };
    let mut found: Vec<ImportableProfile> = profiles
        .iter()
        .filter_map(|(name, settings)| {
            let settings = settings.as_dictionary()?;
            let mut profile = ImportableProfile::new(name.clone(), ProfileSource::TerminalApp);
            if let Some((ps_name, size)) = settings
                .get("Font")
                .and_then(Value::as_data)
                .and_then(decode_font)
            {
                profile.font_family = Some(family_from_postscript(&ps_name, known_families));
                profile.font_size = Some(size as i64);
            }
            let color = |key: &str| {
                settings
                    .get(key)
                    .and_then(Value::as_data)
                    .and_then(decode_color)
                    .map(|(r, g, b)| hex_color(r, g, b))
            };
            profile.background_color = color("BackgroundColor");
            profile.foreground_color = color("TextColor");
            profile.cursor_style = settings
                .get("CursorType")
                .and_then(Value::as_signed_integer)
                .and_then(|t| match t {
                    0 => Some("block"),
                    1 => Some("underline"),
                    2 => Some("bar"),
                    _ => None,
                })
                .map(str::to_string);
            profile.columns = settings
                .get("columnCount")
                .and_then(Value::as_signed_integer);
            profile.rows = settings.get("rowCount").and_then(Value::as_signed_integer);
            profile.shell = settings
                .get("CommandString")
                .and_then(Value::as_string)
                .map(str::to_string);
            Some(profile)
        })
        .collect();
    found.sort_by_key(|a| a.name.to_lowercase());
    found
}

/// Profiles in `com.googlecode.iterm2.plist` ("New Bookmarks"), in file order.
pub fn scan_iterm2(plist: &Value, known_families: &[String]) -> Vec<ImportableProfile> {
    let Some(bookmarks) = plist
        .as_dictionary()
        .and_then(|d| d.get("New Bookmarks"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    bookmarks
        .iter()
        .filter_map(|bookmark| {
            let settings = bookmark.as_dictionary()?;
            let name = settings.get("Name")?.as_string()?;
            let mut profile = ImportableProfile::new(name, ProfileSource::ITerm2);
            // "FontName Size", for example "Menlo-Regular 13".
            if let Some(font) = settings.get("Normal Font").and_then(Value::as_string) {
                let parts: Vec<&str> = font.split(' ').filter(|p| !p.is_empty()).collect();
                if parts.len() >= 2 {
                    let family = parts[..parts.len() - 1].join(" ");
                    profile.font_family = Some(family_from_postscript(&family, known_families));
                    profile.font_size = Some(
                        parts
                            .last()
                            .and_then(|s| s.parse::<f64>().ok())
                            .map(|s| s as i64)
                            .unwrap_or(13),
                    );
                }
            }
            let color = |key: &str| {
                settings
                    .get(key)
                    .and_then(Value::as_dictionary)
                    .and_then(iterm_color)
            };
            profile.background_color = color("Background Color");
            profile.foreground_color = color("Foreground Color");
            profile.shell = settings
                .get("Command")
                .and_then(Value::as_string)
                .map(str::to_string);
            profile.directory = settings
                .get("Working Directory")
                .and_then(Value::as_string)
                .map(str::to_string);
            Some(profile)
        })
        .collect()
}

/// Both apps' profiles under `home` (`scanForProfiles`): Terminal.app first.
pub fn scan_home(home: &Path, known_families: &[String]) -> Vec<ImportableProfile> {
    let mut all = Vec::new();
    if let Some(plist) = read_plist(&home.join(TERMINAL_APP_PLIST)) {
        all.extend(scan_terminal_app(&plist, known_families));
    } else {
        log::info!("TerminalMigrationWizard: no Terminal.app plist found");
    }
    if let Some(plist) = read_plist(&home.join(ITERM2_PLIST)) {
        all.extend(scan_iterm2(&plist, known_families));
    } else {
        log::info!("TerminalMigrationWizard: no iTerm2 plist found");
    }
    all
}

// ----- the wizard ---------------------------------------------------------------

/// The steps of the import wizard (`WizardStep`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Welcome,
    Scanning,
    Selection,
    Importing,
    Complete,
}

impl Step {
    /// The line under the title (`stepDescription`).
    pub fn description(self) -> &'static str {
        match self {
            Self::Welcome => "Bring your existing settings into Chau7",
            Self::Scanning => "Looking for terminal profiles...",
            Self::Selection => "Select profiles to import",
            Self::Importing => "Importing selected profiles...",
            Self::Complete => "Import finished",
        }
    }
}

/// How the wizard ended, for the last page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Imported,
    /// "No Profiles Found".
    NothingFound,
}

/// The state of the wizard window: the found profiles and the ticked ones.
#[derive(Debug, Clone)]
pub struct Wizard {
    pub step: Step,
    pub profiles: Vec<ImportableProfile>,
    selected: Vec<Uuid>,
    pub outcome: Option<Outcome>,
}

impl Default for Wizard {
    fn default() -> Self {
        Self {
            step: Step::Welcome,
            profiles: Vec::new(),
            selected: Vec::new(),
            outcome: None,
        }
    }
}

impl Wizard {
    /// "Scan for Profiles".
    pub fn start_scan(&mut self) {
        self.step = Step::Scanning;
    }

    /// The scan is done: everything found is ticked and the selection page
    /// opens; with nothing found the last page says so.
    pub fn finish_scan(&mut self, found: Vec<ImportableProfile>) {
        self.selected = found.iter().map(|p| p.id).collect();
        self.profiles = found;
        if self.profiles.is_empty() {
            self.outcome = Some(Outcome::NothingFound);
            self.step = Step::Complete;
        } else {
            self.step = Step::Selection;
        }
    }

    pub fn is_selected(&self, id: Uuid) -> bool {
        self.selected.contains(&id)
    }

    pub fn toggle(&mut self, id: Uuid) {
        if let Some(i) = self.selected.iter().position(|s| *s == id) {
            self.selected.remove(i);
        } else {
            self.selected.push(id);
        }
    }

    pub fn select_all(&mut self) {
        self.selected = self.profiles.iter().map(|p| p.id).collect();
    }

    pub fn deselect_all(&mut self) {
        self.selected.clear();
    }

    pub fn selected_count(&self) -> usize {
        self.selected.len()
    }

    /// "Found N profiles".
    pub fn found_label(&self) -> String {
        format!("Found {} profiles", self.profiles.len())
    }

    /// "N selected".
    pub fn selected_label(&self) -> String {
        format!("{} selected", self.selected.len())
    }

    /// "Import N Profiles" (disabled with none selected).
    pub fn import_button(&self) -> String {
        format!("Import {} Profiles", self.selected.len())
    }

    /// "Importing N profiles...".
    pub fn importing_label(&self) -> String {
        format!("Importing {} profiles...", self.selected.len())
    }

    /// The ticked profiles in list order.
    pub fn selected_profiles(&self) -> Vec<ImportableProfile> {
        self.profiles
            .iter()
            .filter(|p| self.selected.contains(&p.id))
            .cloned()
            .collect()
    }

    /// "Import N Profiles": the importing page opens.
    pub fn start_import(&mut self) {
        if !self.selected.is_empty() {
            self.step = Step::Importing;
        }
    }

    pub fn finish_import(&mut self) {
        self.outcome = Some(Outcome::Imported);
        self.step = Step::Complete;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ----- ImportableProfile (TerminalMigrationTests) ---------------------------

    #[test]
    fn profile_creation_has_no_optional_fields() {
        let profile = ImportableProfile::new("TestProfile", ProfileSource::TerminalApp);
        assert_eq!(profile.name, "TestProfile");
        assert_eq!(profile.source, ProfileSource::TerminalApp);
        assert!(profile.font_family.is_none());
        assert!(profile.font_size.is_none());
        assert!(profile.background_color.is_none());
        assert!(profile.foreground_color.is_none());
        assert!(profile.cursor_style.is_none());
        assert!(profile.columns.is_none());
        assert!(profile.rows.is_none());
        assert!(profile.shell.is_none());
        assert!(profile.directory.is_none());
    }

    #[test]
    fn summary_with_font() {
        let mut profile = ImportableProfile::new("Test", ProfileSource::TerminalApp);
        profile.font_family = Some("Menlo".into());
        profile.font_size = Some(13);
        let summary = profile.summary();
        assert!(summary.contains("Terminal.app"));
        assert!(summary.contains("Menlo"));
        assert!(summary.contains("13pt"));
        assert_eq!(summary, "Terminal.app \u{b7} Menlo \u{b7} 13pt");
    }

    #[test]
    fn summary_with_the_source_only() {
        let profile = ImportableProfile::new("Test", ProfileSource::ITerm2);
        assert_eq!(profile.summary(), "iTerm2");
    }

    #[test]
    fn profiles_have_unique_ids() {
        let a = ImportableProfile::new("A", ProfileSource::TerminalApp);
        let b = ImportableProfile::new("A", ProfileSource::TerminalApp);
        assert_ne!(a.id, b.id);
    }

    #[test]
    fn source_names_values_and_icons() {
        assert_eq!(ProfileSource::TerminalApp.display_name(), "Terminal.app");
        assert_eq!(ProfileSource::ITerm2.display_name(), "iTerm2");
        assert_eq!(ProfileSource::TerminalApp.raw_value(), "terminal");
        assert_eq!(ProfileSource::ITerm2.raw_value(), "iterm2");
        assert_eq!(ProfileSource::TerminalApp.icon(), "terminal");
        assert_eq!(ProfileSource::ITerm2.icon(), "rectangle.split.3x1");
    }

    #[test]
    fn imported_profiles_are_named_with_a_prefix() {
        let profile = ImportableProfile::new("Pro", ProfileSource::ITerm2);
        assert_eq!(profile.settings_profile_name(), "Imported: Pro");
    }

    // ----- colors ---------------------------------------------------------------

    #[test]
    fn hex_colors_truncate_like_swift() {
        assert_eq!(hex_color(0.0, 0.0, 0.0), "#000000");
        assert_eq!(hex_color(1.0, 1.0, 1.0), "#FFFFFF");
        assert_eq!(hex_color(1.0, 0.0, 0.0), "#FF0000");
        // 0.5 * 255 = 127.5 is cut to 127 (7F), 0.75 gives 191 (BF), 0.25 gives 63 (3F).
        assert_eq!(hex_color(0.5, 0.75, 0.25), "#7FBF3F");
    }

    // ----- keyed archives -------------------------------------------------------

    fn uid(n: u64) -> Value {
        Value::Uid(plist::Uid::new(n))
    }

    fn archive(root: Dictionary, extra: Vec<Value>) -> Vec<u8> {
        let mut objects = vec![Value::String("$null".into()), Value::Dictionary(root)];
        objects.extend(extra);
        let mut top = Dictionary::new();
        top.insert("root".into(), uid(1));
        let mut file = Dictionary::new();
        file.insert("$archiver".into(), Value::String("NSKeyedArchiver".into()));
        file.insert("$objects".into(), Value::Array(objects));
        file.insert("$top".into(), Value::Dictionary(top));
        let mut out = Vec::new();
        plist::to_writer_binary(&mut out, &Value::Dictionary(file)).unwrap();
        out
    }

    fn font_archive(name: &str, size: f64) -> Vec<u8> {
        let mut root = Dictionary::new();
        root.insert("NSName".into(), uid(2));
        root.insert("NSSize".into(), Value::Real(size));
        archive(root, vec![Value::String(name.into())])
    }

    fn color_archive(space: i64, key: &str, text: &str) -> Vec<u8> {
        let mut root = Dictionary::new();
        root.insert("NSColorSpace".into(), Value::Integer(space.into()));
        root.insert(key.into(), Value::Data(format!("{text}\0").into_bytes()));
        archive(root, Vec::new())
    }

    #[test]
    fn decodes_an_archived_font() {
        let data = font_archive("Menlo-Regular", 13.0);
        assert_eq!(decode_font(&data), Some(("Menlo-Regular".into(), 13.0)));
        assert_eq!(decode_font(b"not a plist"), None);
    }

    #[test]
    fn decodes_archived_colors() {
        let rgb = color_archive(1, "NSRGB", "0.1 0.2 0.3");
        assert_eq!(decode_color(&rgb), Some((0.1, 0.2, 0.3)));
        let white = color_archive(3, "NSWhite", "0.5");
        assert_eq!(decode_color(&white), Some((0.5, 0.5, 0.5)));
        let none = color_archive(1, "NSOther", "1 1 1");
        assert_eq!(decode_color(&none), None);
    }

    #[test]
    fn family_from_a_postscript_name() {
        let known = vec!["SF Mono".to_string(), "Menlo".to_string()];
        assert_eq!(family_from_postscript("Menlo-Regular", &known), "Menlo");
        assert_eq!(family_from_postscript("SFMono-Regular", &known), "SF Mono");
        assert_eq!(family_from_postscript("Monaco", &known), "Monaco");
        assert_eq!(
            family_from_postscript("MesloLGS-NF-Regular", &[]),
            "MesloLGS NF"
        );
        assert_eq!(family_from_postscript("Hack-BoldItalic", &[]), "Hack");
    }

    // ----- Terminal.app ---------------------------------------------------------

    fn terminal_plist() -> Value {
        let mut basic = Dictionary::new();
        basic.insert(
            "Font".into(),
            Value::Data(font_archive("Menlo-Regular", 12.0)),
        );
        basic.insert(
            "BackgroundColor".into(),
            Value::Data(color_archive(1, "NSRGB", "0 0 0")),
        );
        basic.insert(
            "TextColor".into(),
            Value::Data(color_archive(1, "NSRGB", "1 1 1")),
        );
        basic.insert("CursorType".into(), Value::Integer(2.into()));
        basic.insert("columnCount".into(), Value::Integer(120.into()));
        basic.insert("rowCount".into(), Value::Integer(40.into()));
        basic.insert("CommandString".into(), Value::String("/bin/zsh".into()));
        let mut plain = Dictionary::new();
        plain.insert("CursorType".into(), Value::Integer(7.into()));
        let mut windows = Dictionary::new();
        windows.insert("Pro".into(), Value::Dictionary(basic));
        windows.insert("Basic".into(), Value::Dictionary(plain));
        let mut root = Dictionary::new();
        root.insert("Window Settings".into(), Value::Dictionary(windows));
        Value::Dictionary(root)
    }

    #[test]
    fn scans_terminal_app_profiles() {
        let known = vec!["Menlo".to_string()];
        let found = scan_terminal_app(&terminal_plist(), &known);
        let names: Vec<_> = found.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["Basic", "Pro"]);
        let pro = &found[1];
        assert_eq!(pro.source, ProfileSource::TerminalApp);
        assert_eq!(pro.font_family.as_deref(), Some("Menlo"));
        assert_eq!(pro.font_size, Some(12));
        assert_eq!(pro.background_color.as_deref(), Some("#000000"));
        assert_eq!(pro.foreground_color.as_deref(), Some("#FFFFFF"));
        assert_eq!(pro.cursor_style.as_deref(), Some("bar"));
        assert_eq!(pro.columns, Some(120));
        assert_eq!(pro.rows, Some(40));
        assert_eq!(pro.shell.as_deref(), Some("/bin/zsh"));
        // A profile with nothing readable still lists, and an unknown cursor type is ignored.
        let basic = &found[0];
        assert!(basic.font_family.is_none());
        assert!(basic.cursor_style.is_none());
    }

    #[test]
    fn cursor_types_map_to_styles() {
        for (kind, style) in [(0, "block"), (1, "underline"), (2, "bar")] {
            let mut profile = Dictionary::new();
            profile.insert("CursorType".into(), Value::Integer(kind.into()));
            let mut windows = Dictionary::new();
            windows.insert("P".into(), Value::Dictionary(profile));
            let mut root = Dictionary::new();
            root.insert("Window Settings".into(), Value::Dictionary(windows));
            let found = scan_terminal_app(&Value::Dictionary(root), &[]);
            assert_eq!(found[0].cursor_style.as_deref(), Some(style));
        }
    }

    #[test]
    fn terminal_app_without_window_settings_has_no_profiles() {
        assert!(scan_terminal_app(&Value::Dictionary(Dictionary::new()), &[]).is_empty());
        assert!(scan_terminal_app(&Value::String("x".into()), &[]).is_empty());
    }

    // ----- iTerm2 ---------------------------------------------------------------

    fn iterm_color_dict(r: f64, g: f64, b: f64) -> Value {
        let mut d = Dictionary::new();
        d.insert("Red Component".into(), Value::Real(r));
        d.insert("Green Component".into(), Value::Real(g));
        d.insert("Blue Component".into(), Value::Real(b));
        Value::Dictionary(d)
    }

    #[test]
    fn scans_iterm2_profiles() {
        let mut full = Dictionary::new();
        full.insert("Name".into(), Value::String("Dev".into()));
        full.insert(
            "Normal Font".into(),
            Value::String("Menlo-Regular 14".into()),
        );
        full.insert("Background Color".into(), iterm_color_dict(0.0, 0.0, 1.0));
        full.insert("Foreground Color".into(), iterm_color_dict(1.0, 1.0, 0.0));
        full.insert("Command".into(), Value::String("/bin/fish".into()));
        full.insert(
            "Working Directory".into(),
            Value::String("/Users/me".into()),
        );
        let mut nameless = Dictionary::new();
        nameless.insert("Command".into(), Value::String("x".into()));
        let mut spaced = Dictionary::new();
        spaced.insert("Name".into(), Value::String("Spaced".into()));
        spaced.insert(
            "Normal Font".into(),
            Value::String("Fira Code Retina 11".into()),
        );
        let mut root = Dictionary::new();
        root.insert(
            "New Bookmarks".into(),
            Value::Array(vec![
                Value::Dictionary(full),
                Value::Dictionary(nameless),
                Value::Dictionary(spaced),
            ]),
        );
        let found = scan_iterm2(&Value::Dictionary(root), &["Menlo".to_string()]);
        assert_eq!(found.len(), 2);
        let dev = &found[0];
        assert_eq!(dev.source, ProfileSource::ITerm2);
        assert_eq!(dev.font_family.as_deref(), Some("Menlo"));
        assert_eq!(dev.font_size, Some(14));
        assert_eq!(dev.background_color.as_deref(), Some("#0000FF"));
        assert_eq!(dev.foreground_color.as_deref(), Some("#FFFF00"));
        assert_eq!(dev.shell.as_deref(), Some("/bin/fish"));
        assert_eq!(dev.directory.as_deref(), Some("/Users/me"));
        // The font name keeps its spaces; the style word is dropped.
        assert_eq!(found[1].font_family.as_deref(), Some("Fira Code"));
        assert_eq!(found[1].font_size, Some(11));
    }

    #[test]
    fn iterm2_font_size_defaults_to_13_when_unreadable() {
        let mut p = Dictionary::new();
        p.insert("Name".into(), Value::String("X".into()));
        p.insert("Normal Font".into(), Value::String("Menlo big".into()));
        let mut root = Dictionary::new();
        root.insert(
            "New Bookmarks".into(),
            Value::Array(vec![Value::Dictionary(p)]),
        );
        let found = scan_iterm2(&Value::Dictionary(root), &[]);
        assert_eq!(found[0].font_size, Some(13));
    }

    #[test]
    fn scans_both_files_under_a_home_folder() {
        let dir = std::env::temp_dir().join(format!("chau7-import-{}", Uuid::new_v4()));
        let prefs = dir.join("Library/Preferences");
        std::fs::create_dir_all(&prefs).unwrap();
        plist::to_file_binary(prefs.join("com.apple.Terminal.plist"), &terminal_plist()).unwrap();
        let mut one = Dictionary::new();
        one.insert("Name".into(), Value::String("iTerm profile".into()));
        let mut root = Dictionary::new();
        root.insert(
            "New Bookmarks".into(),
            Value::Array(vec![Value::Dictionary(one)]),
        );
        plist::to_file_xml(
            prefs.join("com.googlecode.iterm2.plist"),
            &Value::Dictionary(root),
        )
        .unwrap();
        let found = scan_home(&dir, &[]);
        let names: Vec<_> = found.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["Basic", "Pro", "iTerm profile"]);
        let _ = std::fs::remove_dir_all(&dir);
        // Neither file: nothing.
        assert!(scan_home(&dir, &[]).is_empty());
    }

    // ----- the wizard -----------------------------------------------------------

    fn two_profiles() -> Vec<ImportableProfile> {
        vec![
            ImportableProfile::new("A", ProfileSource::TerminalApp),
            ImportableProfile::new("B", ProfileSource::ITerm2),
        ]
    }

    #[test]
    fn wizard_walks_through_the_steps() {
        let mut wizard = Wizard::default();
        assert_eq!(wizard.step, Step::Welcome);
        wizard.start_scan();
        assert_eq!(wizard.step, Step::Scanning);
        wizard.finish_scan(two_profiles());
        assert_eq!(wizard.step, Step::Selection);
        // Everything found starts ticked.
        assert_eq!(wizard.selected_count(), 2);
        assert_eq!(wizard.found_label(), "Found 2 profiles");
        assert_eq!(wizard.selected_label(), "2 selected");
        assert_eq!(wizard.import_button(), "Import 2 Profiles");
        wizard.start_import();
        assert_eq!(wizard.step, Step::Importing);
        assert_eq!(wizard.importing_label(), "Importing 2 profiles...");
        wizard.finish_import();
        assert_eq!(wizard.step, Step::Complete);
        assert_eq!(wizard.outcome, Some(Outcome::Imported));
    }

    #[test]
    fn nothing_found_ends_on_the_last_page() {
        let mut wizard = Wizard::default();
        wizard.start_scan();
        wizard.finish_scan(Vec::new());
        assert_eq!(wizard.step, Step::Complete);
        assert_eq!(wizard.outcome, Some(Outcome::NothingFound));
    }

    #[test]
    fn selection_can_be_changed() {
        let mut wizard = Wizard::default();
        wizard.finish_scan(two_profiles());
        let first = wizard.profiles[0].id;
        wizard.toggle(first);
        assert!(!wizard.is_selected(first));
        assert_eq!(wizard.selected_label(), "1 selected");
        assert_eq!(wizard.selected_profiles().len(), 1);
        wizard.deselect_all();
        assert_eq!(wizard.selected_count(), 0);
        // The import button is disabled: nothing happens.
        wizard.start_import();
        assert_eq!(wizard.step, Step::Selection);
        wizard.select_all();
        assert_eq!(wizard.selected_count(), 2);
        wizard.toggle(first);
        wizard.toggle(first);
        assert!(wizard.is_selected(first));
    }

    #[test]
    fn step_descriptions() {
        assert_eq!(
            Step::Welcome.description(),
            "Bring your existing settings into Chau7"
        );
        assert_eq!(Step::Complete.description(), "Import finished");
    }
}
