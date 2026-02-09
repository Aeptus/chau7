//! Color conversion utilities for terminal rendering.

use alacritty_terminal::vte::ansi::{Color as AnsiColor, NamedColor};

// ============================================================================
// Theme colors
// ============================================================================

/// Theme colors configuration with pre-computed lookup table.
///
/// The `indexed_lut` field is a flat 256-entry RGB lookup table built once when
/// the theme changes (via `rebuild_lut()`). During grid snapshot creation,
/// `Indexed(n)` colors resolve with a single array index instead of per-cell
/// branch matching + arithmetic. Since alacritty_terminal stores most cell
/// colors as `Indexed`, this covers ~95% of cells in a typical terminal.
///
/// `Named` colors (Foreground, Background, Cursor, Dim*, Bright*) still use
/// a match, since their discriminants start at 256 and they're comparatively
/// rare in grid data.
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
    /// Pre-computed lookup table for Indexed(0..255) colors.
    /// Indices 0-15 use the theme palette; 16-231 use the 6×6×6 color cube;
    /// 232-255 use the grayscale ramp. Built once per theme change.
    indexed_lut: [(u8, u8, u8); 256],
    /// Pre-computed dim palette (palette[0..8] dimmed). Avoids per-cell
    /// arithmetic for DimBlack..DimWhite named colors.
    dim_palette: [(u8, u8, u8); 8],
    /// Pre-computed special colors derived from fg.
    bright_fg: (u8, u8, u8),
    dim_fg: (u8, u8, u8),
}

impl ThemeColors {
    /// Rebuild the lookup tables from current palette/fg/bg/cursor.
    /// Call this whenever the theme palette, fg, bg, or cursor changes.
    pub fn rebuild_lut(&mut self) {
        // Indexed LUT: 0-15 from palette, 16-255 from standard calculation
        for i in 0u16..256 {
            let idx = i as u8;
            self.indexed_lut[i as usize] = if idx < 16 {
                self.palette[idx as usize]
            } else {
                ansi256_to_rgb(idx)
            };
        }
        // Pre-compute dim palette and fg variants
        for i in 0..8 {
            self.dim_palette[i] = dim_color(self.palette[i]);
        }
        self.bright_fg = brighten_color(self.fg);
        self.dim_fg = dim_color(self.fg);
    }
}

impl Default for ThemeColors {
    fn default() -> Self {
        let mut t = ThemeColors {
            fg: (255, 255, 255),
            bg: (0, 0, 0),
            cursor: (255, 255, 255),
            palette: ANSI_COLORS,
            indexed_lut: [(0, 0, 0); 256],
            dim_palette: [(0, 0, 0); 8],
            bright_fg: (0, 0, 0),
            dim_fg: (0, 0, 0),
        };
        t.rebuild_lut();
        t
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

/// Fast color resolution using pre-computed lookup tables.
///
/// For `Indexed` colors (the vast majority of cells), this is a single
/// array lookup. `Named` and `Spec` colors use match/direct extraction.
#[inline(always)]
pub fn color_to_rgb_with_theme(color: AnsiColor, is_fg: bool, theme: &ThemeColors) -> (u8, u8, u8) {
    match color {
        AnsiColor::Indexed(idx) => {
            // Hot path: single array lookup, no branches or arithmetic.
            theme.indexed_lut[idx as usize]
        }
        AnsiColor::Named(named) => named_color_rgb(named, is_fg, theme),
        AnsiColor::Spec(rgb) => (rgb.r, rgb.g, rgb.b),
    }
}

/// Resolve a NamedColor to RGB. Separated to keep the hot Indexed path
/// branch-free and to hint the compiler to not inline this cold path.
#[inline(never)]
fn named_color_rgb(named: NamedColor, is_fg: bool, theme: &ThemeColors) -> (u8, u8, u8) {
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
        NamedColor::Background => theme.bg,
        NamedColor::Cursor => theme.cursor,
        // Dim colors: use pre-computed dim palette (no per-cell arithmetic)
        NamedColor::DimBlack => theme.dim_palette[0],
        NamedColor::DimRed => theme.dim_palette[1],
        NamedColor::DimGreen => theme.dim_palette[2],
        NamedColor::DimYellow => theme.dim_palette[3],
        NamedColor::DimBlue => theme.dim_palette[4],
        NamedColor::DimMagenta => theme.dim_palette[5],
        NamedColor::DimCyan => theme.dim_palette[6],
        NamedColor::DimWhite => theme.dim_palette[7],
        NamedColor::BrightForeground => theme.bright_fg,
        NamedColor::DimForeground => theme.dim_fg,
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

    #[test]
    fn test_indexed_lut_matches_calculation() {
        let theme = ThemeColors::default();

        // Verify indexed LUT matches original function for all 256 entries
        for idx in 0u8..=255 {
            let lut_result = theme.indexed_lut[idx as usize];
            let expected = if idx < 16 {
                theme.palette[idx as usize]
            } else {
                ansi256_to_rgb(idx)
            };
            assert_eq!(lut_result, expected, "Indexed LUT mismatch at {}", idx);
        }
    }

    #[test]
    fn test_named_colors_resolve_correctly() {
        let theme = ThemeColors::default();

        // Verify palette colors
        assert_eq!(
            color_to_rgb_with_theme(AnsiColor::Named(NamedColor::Black), true, &theme),
            theme.palette[0]
        );
        assert_eq!(
            color_to_rgb_with_theme(AnsiColor::Named(NamedColor::BrightWhite), true, &theme),
            theme.palette[15]
        );

        // Verify special colors
        assert_eq!(
            color_to_rgb_with_theme(AnsiColor::Named(NamedColor::Foreground), true, &theme),
            theme.fg
        );
        assert_eq!(
            color_to_rgb_with_theme(AnsiColor::Named(NamedColor::Foreground), false, &theme),
            theme.bg
        );
        assert_eq!(
            color_to_rgb_with_theme(AnsiColor::Named(NamedColor::Cursor), true, &theme),
            theme.cursor
        );

        // Verify dim colors use pre-computed values
        assert_eq!(
            color_to_rgb_with_theme(AnsiColor::Named(NamedColor::DimRed), true, &theme),
            dim_color(theme.palette[1])
        );
    }

    #[test]
    fn test_indexed_via_fast_path() {
        let theme = ThemeColors::default();
        // Verify common indexed colors go through LUT
        assert_eq!(
            color_to_rgb_with_theme(AnsiColor::Indexed(196), true, &theme),
            ansi256_to_rgb(196)
        );
    }
}
