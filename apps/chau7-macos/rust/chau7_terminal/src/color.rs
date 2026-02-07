//! Color conversion utilities for terminal rendering.

use alacritty_terminal::vte::ansi::{Color as AnsiColor, NamedColor};

// ============================================================================
// Theme colors
// ============================================================================

/// Theme colors configuration
#[derive(Clone)]
pub struct ThemeColors {
    /// Foreground color RGB
    pub fg: (u8, u8, u8),
    /// Background color RGB
    pub bg: (u8, u8, u8),
    /// Cursor color RGB
    pub cursor: (u8, u8, u8),
    /// 16-color ANSI palette
    pub palette: [(u8, u8, u8); 16],
}

impl Default for ThemeColors {
    fn default() -> Self {
        ThemeColors {
            fg: (255, 255, 255),
            bg: (0, 0, 0),
            cursor: (255, 255, 255),
            palette: ANSI_COLORS,
        }
    }
}

// ============================================================================
// Color constants and conversion
// ============================================================================

/// Default 16-color ANSI palette (basic terminal colors)
pub const ANSI_COLORS: [(u8, u8, u8); 16] = [
    (0, 0, 0),       // Black
    (205, 49, 49),   // Red
    (13, 188, 121),  // Green
    (229, 229, 16),  // Yellow
    (36, 114, 200),  // Blue
    (188, 63, 188),  // Magenta
    (17, 168, 205),  // Cyan
    (229, 229, 229), // White
    (102, 102, 102), // Bright Black
    (241, 76, 76),   // Bright Red
    (35, 209, 139),  // Bright Green
    (245, 245, 67),  // Bright Yellow
    (59, 142, 234),  // Bright Blue
    (214, 112, 214), // Bright Magenta
    (41, 184, 219),  // Bright Cyan
    (255, 255, 255), // Bright White
];

/// Convert ANSI 256-color index to RGB
pub fn ansi256_to_rgb(idx: u8) -> (u8, u8, u8) {
    if idx < 16 {
        ANSI_COLORS[idx as usize]
    } else if idx < 232 {
        // 6x6x6 color cube
        let idx = idx - 16;
        let r = (idx / 36) % 6;
        let g = (idx / 6) % 6;
        let b = idx % 6;
        let to_val = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
        (to_val(r), to_val(g), to_val(b))
    } else {
        // Grayscale ramp
        let gray = 8 + (idx - 232) * 10;
        (gray, gray, gray)
    }
}

/// Convert alacritty Color to RGB tuple using theme colors
pub fn color_to_rgb_with_theme(color: AnsiColor, is_fg: bool, theme: &ThemeColors) -> (u8, u8, u8) {
    match color {
        AnsiColor::Named(named) => {
            match named {
                NamedColor::Black => theme.palette[0],
                NamedColor::Red => theme.palette[1],
                NamedColor::Green => theme.palette[2],
                NamedColor::Yellow => theme.palette[3],
                NamedColor::Blue => theme.palette[4],
                NamedColor::Magenta => theme.palette[5],
                NamedColor::Cyan => theme.palette[6],
                NamedColor::White => theme.palette[7],
                NamedColor::BrightBlack => theme.palette[8],
                NamedColor::BrightRed => theme.palette[9],
                NamedColor::BrightGreen => theme.palette[10],
                NamedColor::BrightYellow => theme.palette[11],
                NamedColor::BrightBlue => theme.palette[12],
                NamedColor::BrightMagenta => theme.palette[13],
                NamedColor::BrightCyan => theme.palette[14],
                NamedColor::BrightWhite => theme.palette[15],
                NamedColor::Foreground => {
                    if is_fg { theme.fg } else { theme.bg }
                }
                NamedColor::Background => {
                    // Background color should always return theme.bg regardless of context
                    theme.bg
                }
                NamedColor::Cursor => theme.cursor,
                // Dim colors: derive from palette with reduced brightness
                NamedColor::DimBlack => dim_color(theme.palette[0]),
                NamedColor::DimRed => dim_color(theme.palette[1]),
                NamedColor::DimGreen => dim_color(theme.palette[2]),
                NamedColor::DimYellow => dim_color(theme.palette[3]),
                NamedColor::DimBlue => dim_color(theme.palette[4]),
                NamedColor::DimMagenta => dim_color(theme.palette[5]),
                NamedColor::DimCyan => dim_color(theme.palette[6]),
                NamedColor::DimWhite => dim_color(theme.palette[7]),
                NamedColor::BrightForeground => brighten_color(theme.fg),
                NamedColor::DimForeground => dim_color(theme.fg),
            }
        }
        AnsiColor::Spec(rgb) => (rgb.r, rgb.g, rgb.b),
        AnsiColor::Indexed(idx) => {
            if idx < 16 {
                // Use theme palette for indexed colors 0-15
                theme.palette[idx as usize]
            } else {
                // Use standard 256-color calculation for indices 16-255
                ansi256_to_rgb(idx)
            }
        }
    }
}

/// Dim a color by reducing its brightness
pub fn dim_color(color: (u8, u8, u8)) -> (u8, u8, u8) {
    (
        (color.0 as u16 * 2 / 3) as u8,
        (color.1 as u16 * 2 / 3) as u8,
        (color.2 as u16 * 2 / 3) as u8,
    )
}

/// Brighten a color
pub fn brighten_color(color: (u8, u8, u8)) -> (u8, u8, u8) {
    (
        ((color.0 as u16 * 4 / 3).min(255)) as u8,
        ((color.1 as u16 * 4 / 3).min(255)) as u8,
        ((color.2 as u16 * 4 / 3).min(255)) as u8,
    )
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ansi256_to_rgb() {
        // Test basic colors
        assert_eq!(ansi256_to_rgb(0), (0, 0, 0)); // Black
        assert_eq!(ansi256_to_rgb(15), (255, 255, 255)); // Bright white

        // Test grayscale
        assert_eq!(ansi256_to_rgb(232), (8, 8, 8)); // Darkest gray
        assert_eq!(ansi256_to_rgb(255), (238, 238, 238)); // Lightest gray
    }
}
