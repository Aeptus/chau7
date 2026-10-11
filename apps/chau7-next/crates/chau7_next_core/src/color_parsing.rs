//! Hex color parsing and simple color math.
//!
//! Port of `ColorParsing.swift` from `apps/chau7-macos/Sources/Chau7Core`.
//! The Swift type is RGB only (no alpha) with `Double` components in 0..=1,
//! so this port uses [`Rgb`] with `f64` components to keep identical values.

/// RGB color components in the 0.0..=1.0 range.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rgb {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

impl Rgb {
    pub const fn new(red: f64, green: f64, blue: f64) -> Self {
        Self { red, green, blue }
    }

    /// Creates a color from 0-255 integer components (not clamped, as in
    /// Swift).
    pub fn from_ints(r: i64, g: i64, b: i64) -> Self {
        Self {
            red: r as f64 / 255.0,
            green: g as f64 / 255.0,
            blue: b as f64 / 255.0,
        }
    }
}

/// Matches Swift's `Character.isHexDigit`: ASCII `0-9`, `a-f`, `A-F` and their
/// fullwidth compatibility forms.
pub fn is_hex_digit(c: char) -> bool {
    c.is_ascii_hexdigit()
        || matches!(c, '\u{FF10}'..='\u{FF19}' | '\u{FF21}'..='\u{FF26}' | '\u{FF41}'..='\u{FF46}')
}

/// Parses a hex color string (`#RRGGBB`, `RRGGBB`, `#RGB` or `RGB`, with
/// surrounding whitespace ignored). Returns `None` when invalid.
pub fn parse_hex(hex: &str) -> Option<Rgb> {
    let sanitized: String = hex.trim().chars().filter(|&c| c != '#').collect();

    let count = sanitized.chars().count();
    if count != 6 && count != 3 {
        return None;
    }

    let sanitized: String = if count == 3 {
        sanitized.chars().flat_map(|c| [c, c]).collect()
    } else {
        sanitized
    };

    if !sanitized.chars().all(is_hex_digit) {
        return None;
    }

    // `Scanner.scanHexInt64` reads the leading run of ASCII hex digits; a
    // fullwidth digit (accepted above) stops the scan, like in Swift.
    let rgb = sanitized
        .chars()
        .map_while(|c| c.to_digit(16))
        .fold(0_u64, |acc, d| (acc << 4) | u64::from(d));

    Some(Rgb {
        red: ((rgb & 0xFF0000) >> 16) as f64 / 255.0,
        green: ((rgb & 0x00FF00) >> 8) as f64 / 255.0,
        blue: (rgb & 0x0000FF) as f64 / 255.0,
    })
}

/// Converts a color to an uppercase `#RRGGBB` string. Components are clamped
/// to 0..=1 and truncated (not rounded) after scaling by 255, as in Swift.
pub fn to_hex(rgb: Rgb) -> String {
    let channel = |v: f64| (v.clamp(0.0, 1.0) * 255.0) as i64;
    format!(
        "#{:02X}{:02X}{:02X}",
        channel(rgb.red),
        channel(rgb.green),
        channel(rgb.blue)
    )
}

/// Checks if a string is a valid hex color.
pub fn is_valid_hex(hex: &str) -> bool {
    parse_hex(hex).is_some()
}

/// Multiplies each component by `factor` and clamps to 0..=1.
pub fn adjust_brightness(rgb: Rgb, factor: f64) -> Rgb {
    Rgb {
        red: (rgb.red * factor).clamp(0.0, 1.0),
        green: (rgb.green * factor).clamp(0.0, 1.0),
        blue: (rgb.blue * factor).clamp(0.0, 1.0),
    }
}

/// Relative luminance (Rec. 709 weights), 0.0..=1.0.
pub fn luminance(rgb: Rgb) -> f64 {
    0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
}

/// Whether a color is considered "light" (luminance above 0.5).
pub fn is_light(rgb: Rgb) -> bool {
    luminance(rgb) > 0.5
}

#[cfg(test)]
mod tests {
    // Ported from ColorParsingTests.swift. No tests skipped.
    use super::*;

    fn assert_close(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() <= 0.001,
            "expected {expected}, got {actual}"
        );
    }

    fn assert_rgb(rgb: Rgb, r: f64, g: f64, b: f64) {
        assert_close(rgb.red, r);
        assert_close(rgb.green, g);
        assert_close(rgb.blue, b);
    }

    // Hex parsing

    #[test]
    fn parse_hex_with_hash() {
        assert_rgb(parse_hex("#FF0000").unwrap(), 1.0, 0.0, 0.0);
    }

    #[test]
    fn parse_hex_without_hash() {
        assert_rgb(parse_hex("00FF00").unwrap(), 0.0, 1.0, 0.0);
    }

    #[test]
    fn parse_hex_blue() {
        assert_close(parse_hex("#0000FF").unwrap().blue, 1.0);
    }

    #[test]
    fn parse_hex_white() {
        assert_rgb(parse_hex("#FFFFFF").unwrap(), 1.0, 1.0, 1.0);
    }

    #[test]
    fn parse_hex_black() {
        assert_rgb(parse_hex("#000000").unwrap(), 0.0, 0.0, 0.0);
    }

    #[test]
    fn parse_hex_mixed_case() {
        let rgb1 = parse_hex("#aAbBcC").unwrap();
        let rgb2 = parse_hex("#AABBCC").unwrap();
        assert_rgb(rgb1, rgb2.red, rgb2.green, rgb2.blue);
    }

    #[test]
    fn parse_hex_short_form() {
        assert_rgb(parse_hex("#F00").unwrap(), 1.0, 0.0, 0.0);
    }

    #[test]
    fn parse_hex_short_form_white() {
        assert_rgb(parse_hex("FFF").unwrap(), 1.0, 1.0, 1.0);
    }

    #[test]
    fn parse_hex_with_whitespace() {
        assert_close(parse_hex("  #FF0000  ").unwrap().red, 1.0);
    }

    #[test]
    fn parse_hex_gray() {
        let expected = 128.0 / 255.0;
        assert_rgb(parse_hex("#808080").unwrap(), expected, expected, expected);
    }

    // Invalid hex

    #[test]
    fn parse_invalid_hex_too_short() {
        assert_eq!(parse_hex("#FF"), None);
        assert_eq!(parse_hex("AB"), None);
    }

    #[test]
    fn parse_invalid_hex_too_long() {
        assert_eq!(parse_hex("#FF00FF00"), None);
    }

    #[test]
    fn parse_invalid_hex_characters() {
        assert_eq!(parse_hex("#GGGGGG"), None);
        assert_eq!(parse_hex("#ZZZ"), None);
    }

    #[test]
    fn parse_empty_hex() {
        assert_eq!(parse_hex(""), None);
        assert_eq!(parse_hex("#"), None);
    }

    // Hex conversion

    #[test]
    fn to_hex_red() {
        assert_eq!(to_hex(Rgb::new(1.0, 0.0, 0.0)), "#FF0000");
    }

    #[test]
    fn to_hex_green() {
        assert_eq!(to_hex(Rgb::new(0.0, 1.0, 0.0)), "#00FF00");
    }

    #[test]
    fn to_hex_blue() {
        assert_eq!(to_hex(Rgb::new(0.0, 0.0, 1.0)), "#0000FF");
    }

    #[test]
    fn round_trip() {
        let original = "#3B8EEA";
        assert_eq!(to_hex(parse_hex(original).unwrap()), original);
    }

    // Validation

    #[test]
    fn is_valid_hex_cases() {
        assert!(is_valid_hex("#FF0000"));
        assert!(is_valid_hex("00FF00"));
        assert!(is_valid_hex("#FFF"));
        assert!(!is_valid_hex("invalid"));
        assert!(!is_valid_hex("#GGG"));
    }

    // Luminance

    #[test]
    fn luminance_white() {
        assert_close(luminance(Rgb::new(1.0, 1.0, 1.0)), 1.0);
    }

    #[test]
    fn luminance_black() {
        assert_close(luminance(Rgb::new(0.0, 0.0, 0.0)), 0.0);
    }

    #[test]
    fn luminance_green_higher() {
        let red = luminance(Rgb::new(1.0, 0.0, 0.0));
        let green = luminance(Rgb::new(0.0, 1.0, 0.0));
        let blue = luminance(Rgb::new(0.0, 0.0, 1.0));
        assert!(green > red);
        assert!(green > blue);
    }

    // Is light

    #[test]
    fn is_light_white() {
        assert!(is_light(Rgb::new(1.0, 1.0, 1.0)));
    }

    #[test]
    fn is_light_black() {
        assert!(!is_light(Rgb::new(0.0, 0.0, 0.0)));
    }

    #[test]
    fn is_light_yellow() {
        assert!(is_light(parse_hex("#FFFF00").unwrap()));
    }

    #[test]
    fn is_light_dark_blue() {
        assert!(!is_light(parse_hex("#000080").unwrap()));
    }

    // Brightness adjustment

    #[test]
    fn adjust_brightness_darker() {
        let darker = adjust_brightness(Rgb::new(0.8, 0.8, 0.8), 0.5);
        assert_rgb(darker, 0.4, 0.4, 0.4);
    }

    #[test]
    fn adjust_brightness_brighter() {
        let brighter = adjust_brightness(Rgb::new(0.4, 0.4, 0.4), 2.0);
        assert_rgb(brighter, 0.8, 0.8, 0.8);
    }

    #[test]
    fn adjust_brightness_clamped() {
        let brighter = adjust_brightness(Rgb::new(0.8, 0.8, 0.8), 2.0);
        assert_rgb(brighter, 1.0, 1.0, 1.0);
    }

    // RGB init

    #[test]
    fn rgb_init_from_integers() {
        assert_rgb(Rgb::from_ints(255, 128, 0), 1.0, 128.0 / 255.0, 0.0);
    }

    // Extra coverage (not in the Swift suite).

    #[test]
    fn fullwidth_digits_validate_but_stop_the_scan() {
        // "FF" then fullwidth zeros: valid per isHexDigit, scan reads 0xFF.
        assert_rgb(
            parse_hex("FF\u{FF10}\u{FF10}\u{FF10}\u{FF10}").unwrap(),
            0.0,
            0.0,
            1.0,
        );
    }
}
