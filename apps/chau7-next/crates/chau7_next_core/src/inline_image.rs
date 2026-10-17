//! iTerm2 inline image arguments and sizing (`Rendering/InlineImageSupport.swift`,
//! `InlineImageHandler.parseImageSequence` and `renderImage`).
//!
//! The emulator (`chau7_terminal::graphics`) strips `ESC ] 1337 ; File=args :
//! base64 BEL` from the output and hands over `args` and the base64 payload;
//! this module parses `args` and computes the size the image is drawn at.

/// One of `width=` / `height=`: `auto`, `N` cells, `Npx`, `N%`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Dimension {
    #[default]
    Auto,
    Pixels(i64),
    Percent(i64),
    Cells(i64),
}

impl Dimension {
    /// `parseDimension`: `N%`, `Npx`, `auto`, otherwise cells (0 when not a number).
    pub fn parse(value: &str) -> Self {
        if let Some(num) = value.strip_suffix('%') {
            Dimension::Percent(num.parse().unwrap_or(100))
        } else if let Some(num) = value.strip_suffix("px") {
            Dimension::Pixels(num.parse().unwrap_or(0))
        } else if value == "auto" {
            Dimension::Auto
        } else {
            Dimension::Cells(value.parse().unwrap_or(0))
        }
    }
}

/// Parsed `File=` arguments (`InlineImageArgs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InlineImageArgs {
    pub name: Option<String>,
    pub size: Option<i64>,
    pub width: Dimension,
    pub height: Dimension,
    pub preserve_aspect_ratio: bool,
    pub inline: bool,
}

impl Default for InlineImageArgs {
    fn default() -> Self {
        Self {
            name: None,
            size: None,
            width: Dimension::Auto,
            height: Dimension::Auto,
            preserve_aspect_ratio: true,
            inline: true,
        }
    }
}

/// Largest size an inline image is drawn at, in points (`maxImageWidth`, `maxImageHeight`).
pub const MAX_WIDTH: f32 = 800.0;
pub const MAX_HEIGHT: f32 = 600.0;

impl InlineImageArgs {
    /// Parse `key=value;key=value` (keys are case-insensitive, unknown keys ignored).
    pub fn parse(args: &str) -> Self {
        let args = args.strip_prefix("File=").unwrap_or(args);
        let mut out = InlineImageArgs::default();
        for part in args.split(';') {
            let Some((key, value)) = part.split_once('=') else {
                continue;
            };
            match key.to_ascii_lowercase().as_str() {
                "name" => out.name = Some(percent_decode(value)),
                "size" => out.size = value.parse().ok(),
                "width" => out.width = Dimension::parse(value),
                "height" => out.height = Dimension::parse(value),
                "preserveaspectratio" => out.preserve_aspect_ratio = value != "0",
                "inline" => out.inline = value == "1",
                _ => {}
            }
        }
        out
    }

    /// `renderImage`: the drawn size in points for an image of `natural`
    /// size, with cells of `cell` points and a grid of `grid` cells.
    pub fn target_size(
        &self,
        natural: (f32, f32),
        cell: (f32, f32),
        grid: (u16, u16),
    ) -> (f32, f32) {
        let resolve = |dim: Dimension, natural: f32, cell: f32, cells: u16| match dim {
            Dimension::Auto => natural,
            Dimension::Pixels(px) => px as f32,
            Dimension::Percent(pct) => cells as f32 * cell * pct as f32 / 100.0,
            Dimension::Cells(n) => n as f32 * cell,
        };
        let mut width = resolve(self.width, natural.0, cell.0, grid.0).min(MAX_WIDTH);
        let mut height = resolve(self.height, natural.1, cell.1, grid.1).min(MAX_HEIGHT);
        if self.preserve_aspect_ratio && natural.0 > 0.0 && natural.1 > 0.0 && height > 0.0 {
            let aspect = natural.0 / natural.1;
            if width / height > aspect {
                width = height * aspect;
            } else {
                height = width / aspect;
            }
        }
        (width.max(0.0), height.max(0.0))
    }

    /// File name for Save Image... and Open in Preview (`image.png` by default).
    pub fn file_name(&self) -> String {
        self.name
            .as_deref()
            .map(|n| n.rsplit(['/', '\\']).next().unwrap_or(n).trim())
            .filter(|n| !n.is_empty())
            .unwrap_or("image.png")
            .to_string()
    }
}

/// `removingPercentEncoding ?? value`.
fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = value
                .get(i + 1..i + 3)
                .and_then(|h| u8::from_str_radix(h, 16).ok());
            match hex {
                Some(b) => {
                    out.push(b);
                    i += 3;
                    continue;
                }
                None => return value.to_string(),
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| value.to_string())
}

/// Image bytes format, sniffed from the first bytes (iTerm2 payloads carry no type).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SniffedFormat {
    Png,
    Jpeg,
    Gif,
    Webp,
    Bmp,
    Tiff,
}

pub fn sniff_format(bytes: &[u8]) -> Option<SniffedFormat> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(SniffedFormat::Png)
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some(SniffedFormat::Jpeg)
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some(SniffedFormat::Gif)
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(SniffedFormat::Webp)
    } else if bytes.starts_with(b"BM") {
        Some(SniffedFormat::Bmp)
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        Some(SniffedFormat::Tiff)
    } else {
        None
    }
}

/// Where an image anchored at absolute line `anchor` sits in the viewport:
/// viewport row (may be negative or past the bottom) for a terminal whose
/// scrollback holds `history` lines and is scrolled up by `display_offset`.
pub fn viewport_row(anchor: i64, history: u32, display_offset: u32) -> i64 {
    anchor - (history as i64 - display_offset as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_imgcat_arguments() {
        let args =
            InlineImageArgs::parse("name=cat%20pic.png;size=1234;inline=1;width=40;height=50%");
        assert_eq!(args.name.as_deref(), Some("cat pic.png"));
        assert_eq!(args.size, Some(1234));
        assert!(args.inline);
        assert_eq!(args.width, Dimension::Cells(40));
        assert_eq!(args.height, Dimension::Percent(50));
        assert!(args.preserve_aspect_ratio);
    }

    #[test]
    fn defaults_and_flags() {
        let args = InlineImageArgs::parse("File=inline=0;preserveAspectRatio=0;WIDTH=120px");
        assert!(!args.inline);
        assert!(!args.preserve_aspect_ratio);
        assert_eq!(args.width, Dimension::Pixels(120));
        assert_eq!(args.height, Dimension::Auto);
        assert_eq!(InlineImageArgs::parse("").file_name(), "image.png");
        assert_eq!(Dimension::parse("x"), Dimension::Cells(0));
        assert_eq!(Dimension::parse("auto"), Dimension::Auto);
    }

    #[test]
    fn sizes_are_capped_and_keep_aspect() {
        let args = InlineImageArgs::default();
        // 1600x1200 natural: capped to 800x600, same aspect.
        assert_eq!(
            args.target_size((1600.0, 1200.0), (8.0, 16.0), (80, 24)),
            (800.0, 600.0)
        );
        // 2000x500: width capped first, then height follows aspect.
        assert_eq!(
            args.target_size((2000.0, 500.0), (8.0, 16.0), (80, 24)),
            (800.0, 200.0)
        );
        // 10 cells wide, auto height, keep aspect.
        let cells = InlineImageArgs::parse("width=10");
        assert_eq!(
            cells.target_size((100.0, 100.0), (8.0, 16.0), (80, 24)),
            (80.0, 80.0)
        );
        // Stretch when aspect is not preserved.
        let stretch = InlineImageArgs::parse("width=100%;height=2;preserveAspectRatio=0");
        assert_eq!(
            stretch.target_size((10.0, 10.0), (8.0, 16.0), (80, 24)),
            (640.0, 32.0)
        );
    }

    #[test]
    fn sniffs_formats() {
        assert_eq!(
            sniff_format(b"\x89PNG\r\n\x1a\n...."),
            Some(SniffedFormat::Png)
        );
        assert_eq!(
            sniff_format(&[0xFF, 0xD8, 0xFF, 0xE0]),
            Some(SniffedFormat::Jpeg)
        );
        assert_eq!(sniff_format(b"GIF89a"), Some(SniffedFormat::Gif));
        assert_eq!(sniff_format(b"hello"), None);
    }

    #[test]
    fn viewport_rows_follow_scrolling() {
        // Arrived at screen row 3 with 10 lines of history: absolute 13.
        assert_eq!(viewport_row(13, 10, 0), 3);
        // 5 more lines of output pushed into history: the image moved up.
        assert_eq!(viewport_row(13, 15, 0), -2);
        // Scrolling back 5 lines shows it at row 3 again.
        assert_eq!(viewport_row(13, 15, 5), 3);
    }
}
