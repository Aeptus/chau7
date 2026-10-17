//! Monospace fonts offered by the font picker (`FeatureSettings.availableFonts`).

/// The curated list, in Swift's order (system fonts first, then popular
/// coding fonts, Nerd Fonts, commercial fonts).
pub const MONOSPACE_FONTS: &[&str] = &[
    "Menlo",
    "Monaco",
    "SF Mono",
    "Courier New",
    "Cascadia Code",
    "Cascadia Mono",
    "Consolas",
    "JetBrains Mono",
    "Source Code Pro",
    "Roboto Mono",
    "Fira Code",
    "Fira Mono",
    "IBM Plex Mono",
    "Monaspace Neon",
    "Monaspace Argon",
    "Monaspace Xenon",
    "Monaspace Radon",
    "Monaspace Krypton",
    "Geist Mono",
    "Hack",
    "Inconsolata",
    "Anonymous Pro",
    "Ubuntu Mono",
    "Droid Sans Mono",
    "DejaVu Sans Mono",
    "Liberation Mono",
    "PT Mono",
    "Oxygen Mono",
    "Space Mono",
    "Overpass Mono",
    "Share Tech Mono",
    "Cousine",
    "Cutive Mono",
    "Iosevka",
    "Iosevka Term",
    "Iosevka Fixed",
    "Victor Mono",
    "Fantasque Sans Mono",
    "Input Mono",
    "Input Mono Narrow",
    "Input Mono Condensed",
    "Recursive Mono Linear",
    "Rec Mono Linear",
    "Comic Mono",
    "Maple Mono",
    "Maple Mono NF",
    "Commit Mono",
    "MesloLGS NF",
    "MesloLGM NF",
    "MesloLGL NF",
    "Hack Nerd Font",
    "FiraCode Nerd Font",
    "JetBrainsMono Nerd Font",
    "CaskaydiaCove Nerd Font",
    "Iosevka Nerd Font",
    "UbuntuMono Nerd Font",
    "RobotoMono Nerd Font",
    "SourceCodePro Nerd Font",
    "Symbols Nerd Font",
    "Operator Mono",
    "Dank Mono",
    "MonoLisa",
    "Berkeley Mono",
    "Gintronic",
    "Pragmata Pro",
    "Cartograph CF",
    "Codelia",
    "Comic Code",
    "Ellograph CF",
    "Lilex",
    "Sudo",
    "Agave",
    "Cozette",
    "Terminus",
    "Tamzen",
    "Tamsyn",
    "GoMono",
    "Noto Sans Mono",
    "Intel One Mono",
];

/// Whether `family` is installed (case-insensitive match on family names).
pub fn is_installed(family: &str, installed: &[String]) -> bool {
    let family = family.trim();
    !family.is_empty() && installed.iter().any(|f| f.eq_ignore_ascii_case(family))
}

/// The picker list: the curated fonts that are installed ("SF Mono" is kept
/// on macOS, where it is always available through the system monospaced
/// font), with the custom font first when it is installed and not already
/// listed.
pub fn available_fonts(installed: &[String], custom: &str, always_sf_mono: bool) -> Vec<String> {
    let mut fonts: Vec<String> = MONOSPACE_FONTS
        .iter()
        .filter(|f| (always_sf_mono && **f == "SF Mono") || is_installed(f, installed))
        .map(|f| f.to_string())
        .collect();
    let custom = custom.trim();
    if !custom.is_empty() && !fonts.iter().any(|f| f == custom) && is_installed(custom, installed) {
        fonts.insert(0, custom.to_string());
    }
    fonts
}

#[cfg(test)]
mod tests {
    use super::*;

    fn installed() -> Vec<String> {
        ["Menlo", "fira code", "Comic Sans MS", "My Font"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    }

    #[test]
    fn has_swift_list() {
        assert_eq!(MONOSPACE_FONTS.len(), 79);
        assert_eq!(MONOSPACE_FONTS[0], "Menlo");
        assert_eq!(MONOSPACE_FONTS.last(), Some(&"Intel One Mono"));
    }

    #[test]
    fn filters_to_installed_fonts() {
        assert_eq!(
            available_fonts(&installed(), "", true),
            vec!["Menlo", "SF Mono", "Fira Code"]
        );
        assert_eq!(
            available_fonts(&installed(), "", false),
            vec!["Menlo", "Fira Code"]
        );
    }

    #[test]
    fn custom_font_goes_first_when_installed() {
        assert_eq!(
            available_fonts(&installed(), "My Font", false),
            vec!["My Font", "Menlo", "Fira Code"]
        );
        assert_eq!(available_fonts(&installed(), "Nope", false).len(), 2);
        assert_eq!(available_fonts(&installed(), "Menlo", false).len(), 2);
        assert!(is_installed(" my font ", &installed()));
        assert!(!is_installed("", &installed()));
    }
}
