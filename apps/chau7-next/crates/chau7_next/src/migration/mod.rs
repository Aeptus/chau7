//! The Terminal.app and iTerm2 import wizard (`TerminalMigrationWizard`,
//! `TerminalMigrationWizardView`). It never runs in the Swift app; here it
//! is File > Import Terminal Profiles. It only reads the other terminals'
//! preference files and creates settings profiles; the current settings
//! and the active profile stay as they are.

pub mod swift_restore;
mod window;

use chau7_next_core::terminal_import::ImportableProfile;
use gpui::App;

use crate::actions::ImportTerminalProfiles;
use crate::profiles;
use crate::settings::{CursorShape, Settings};

pub fn register(cx: &mut App) {
    cx.on_action(|_: &ImportTerminalProfiles, cx| window::open(cx));
}

/// The settings of a profile created from `profile`: `base` with the font
/// family and size and the cursor style of the imported one
/// (`importProfiles`).
pub fn imported_settings(base: &Settings, profile: &ImportableProfile) -> Settings {
    let mut settings = base.clone();
    if let Some(family) = profile.font_family.as_ref().filter(|f| !f.is_empty()) {
        settings.appearance.font_family = family.clone();
    }
    if let Some(size) = profile.font_size {
        settings.appearance.set_font_size(size as f32);
    }
    match profile.cursor_style.as_deref() {
        Some("block") => settings.appearance.cursor_shape = CursorShape::Block,
        Some("underline") => settings.appearance.cursor_shape = CursorShape::Underline,
        Some("bar") => settings.appearance.cursor_shape = CursorShape::Bar,
        _ => {}
    }
    settings
}

/// Create one settings profile per imported profile, named
/// "Imported: <name>". None of them is activated.
pub fn import_profiles(found: &[ImportableProfile], cx: &mut App) {
    let base = Settings::get(cx).clone();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    profiles::edit(cx, |store| {
        for profile in found {
            let config = imported_settings(&base, profile).to_profile_text();
            store.create(&profile.settings_profile_name(), "terminal", config, now);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::terminal_import::ProfileSource;

    #[test]
    fn import_carries_font_size_and_cursor_only() {
        let base = Settings::default();
        let mut p = ImportableProfile::new("Pro", ProfileSource::TerminalApp);
        p.font_family = Some("Menlo".into());
        p.font_size = Some(15);
        p.cursor_style = Some("bar".into());
        p.background_color = Some("#000000".into());
        let out = imported_settings(&base, &p);
        assert_eq!(out.appearance.font_family, "Menlo");
        assert_eq!(out.appearance.font_size, 15.0);
        assert_eq!(out.appearance.cursor_shape, CursorShape::Bar);
        assert_eq!(
            out.appearance.color_scheme.name,
            base.appearance.color_scheme.name
        );
        // The base is untouched.
        assert_ne!(base.appearance.font_size, 15.0);
    }

    #[test]
    fn missing_fields_keep_the_current_settings() {
        let base = Settings::default();
        let p = ImportableProfile::new("Empty", ProfileSource::ITerm2);
        assert_eq!(imported_settings(&base, &p), base);
    }

    #[test]
    fn imported_profile_font_uses_setting_bounds_without_changing_base_or_preferences() {
        let mut base = Settings::default();
        base.appearance.font_size = 19.0;
        base.input.copy_on_select = false;
        base.terminal.scrollback_lines = 2300;
        for (raw, expected) in [
            (-1, 8.0),
            (0, 8.0),
            (7, 8.0),
            (8, 8.0),
            (72, 72.0),
            (73, 72.0),
        ] {
            let mut profile = ImportableProfile::new("Bounds", ProfileSource::ITerm2);
            profile.font_size = Some(raw);
            let actual = imported_settings(&base, &profile);
            assert_eq!(actual.appearance.font_size, expected);
            assert!(!actual.input.copy_on_select);
            assert_eq!(actual.terminal.scrollback_lines, 2300);
            let restored = Settings::from_profile_text(&actual.to_profile_text());
            assert_eq!(restored.appearance.font_size, expected);
            assert_eq!(base.appearance.font_size, 19.0);
        }
    }
}
