//! Pure logic behind the non-terminal panes of a tab (`Editor/` and
//! `SplitPanes/` in the Swift app): language detection and highlighting for
//! the text editor, output-style highlighting for the file preview, editor
//! settings and editing helpers, the unified diff parser of the diff viewer,
//! the markdown runbook parser, and the command blocks used by semantic
//! search.

pub mod config;
pub mod diff;
pub mod language;
pub mod markdown;
pub mod output_highlight;
pub mod semantic;
pub mod text;

/// Palette slot of a highlighted span. Swift uses `NSColor.system*` colors;
/// the UI maps each slot to a color of the editor theme.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HighlightColor {
    Pink,
    Purple,
    Red,
    Green,
    Blue,
    Teal,
    Orange,
    Yellow,
    Cyan,
    Gray,
    /// The normal text color (`labelColor`), used with bold.
    Label,
}

/// A styled byte range of a line or document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HighlightSpan {
    pub range: std::ops::Range<usize>,
    pub color: HighlightColor,
    pub bold: bool,
    /// Underlined link target (URLs in output highlighting).
    pub link: Option<String>,
}

/// Paint `color` over `range` in a per-byte style buffer: later rules win,
/// like `NSMutableAttributedString.addAttribute` applied in order.
pub(crate) fn paint(
    styles: &mut [Option<(HighlightColor, bool, Option<u32>)>],
    range: std::ops::Range<usize>,
    color: HighlightColor,
    bold: bool,
    link: Option<u32>,
) {
    for slot in &mut styles[range] {
        // Bold and links stay once set (they are separate attributes in Swift).
        let (keep_bold, keep_link) = slot.map(|s| (s.1, s.2)).unwrap_or((false, None));
        *slot = Some((color, bold || keep_bold, link.or(keep_link)));
    }
}

/// Turn a per-byte style buffer into runs.
pub(crate) fn runs(
    styles: &[Option<(HighlightColor, bool, Option<u32>)>],
    links: &[String],
) -> Vec<HighlightSpan> {
    let mut out: Vec<HighlightSpan> = Vec::new();
    let mut start = 0;
    while start < styles.len() {
        let current = styles[start];
        let mut end = start + 1;
        while end < styles.len() && styles[end] == current {
            end += 1;
        }
        if let Some((color, bold, link)) = current {
            out.push(HighlightSpan {
                range: start..end,
                color,
                bold,
                link: link.and_then(|i| links.get(i as usize).cloned()),
            });
        }
        start = end;
    }
    out
}

pub mod session_note;
