//! Painting the terminal grid: cell backgrounds, text runs, underline styles,
//! hyperlinks, search matches, dangerous-command tint, images, line
//! timestamps, the cursor and IME text (`RustTerminalView.swift`
//! `RustGridView.draw`, `Rendering/`, `Performance/MetalTerminalRenderer.swift`).
//!
//! Text is shaped one row at a time with `force_width` set to the cell width,
//! so every glyph sits on the grid (wide characters are followed by a spacer
//! cell in the snapshot and stay aligned). With ligatures on, a ligature
//! glyph starts in its first cell and spans the cells of its characters.
//!
//! `view.rs` builds a [`FrameInputs`] in `render`, [`prepaint`] turns it
//! into a [`PaintState`] once the bounds are known, and [`paint_grid`] draws.

#[path = "cpu_renderer.rs"]
mod cpu_renderer;

pub use cpu_renderer::init as init_cpu_text_system;
use cpu_renderer::{FrameCache, GridCanvas};
pub(crate) use cpu_renderer::{glyph_cache_bytes, glyph_cache_entries, release_glyph_cache};
use parking_lot::Mutex;

use std::collections::HashMap;
use std::ops::Range;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chau7_next_core::color_schemes::ColorScheme;
use chau7_next_core::feature_profiler::{self, Feature};
use chau7_next_core::line_timestamps::{self, LineTimestamps};
use chau7_terminal::{
    CELL_FLAG_BOLD, CELL_FLAG_DIM, CELL_FLAG_HIDDEN, CELL_FLAG_INVERSE, CELL_FLAG_ITALIC,
    CELL_FLAG_STRIKETHROUGH, CELL_FLAG_UNDERLINE, OwnedCell, UNDERLINE_CURL, UNDERLINE_DASHED,
    UNDERLINE_DOTTED, UNDERLINE_DOUBLE,
};
use gpui::{
    App, Bounds, Font, FontFallbacks, FontFeatures, FontStyle, FontWeight, Hsla, Pixels,
    SharedString, StrikethroughStyle, TextRun, UnderlineStyle, Window, fill, font, outline, point,
    px, size,
};

use super::images::{ImageLayer, Placement};
use super::session::TerminalSession;
use crate::settings::{CursorShape, Settings, fallback_fonts};
use crate::theme::{rgb_tuple, scheme_color};

/// Font and cell geometry for one font size.
#[derive(Debug, Clone)]
pub struct CellMetrics {
    pub font: Font,
    pub font_size: Pixels,
    pub cell_width: Pixels,
    pub line_height: Pixels,
    /// Distance from the top of a row to the underline.
    pub underline_y: Pixels,
}

impl CellMetrics {
    pub fn measure(settings: &Settings, font_size: f32, window: &mut Window) -> Self {
        let f = terminal_font(settings, window);
        let font_size = px(font_size);
        let text_system = window.text_system();
        let font_id = text_system.resolve_font(&f);
        let cell_width = text_system
            .advance(font_id, font_size, 'm')
            .map(|s| s.width)
            .unwrap_or(font_size * 0.6);
        let line_height = (font_size * settings.appearance.line_height).round();
        let ascent = text_system.ascent(font_id, font_size);
        let descent = text_system.descent(font_id, font_size).abs();
        let baseline = (line_height - ascent - descent) / 2.0 + ascent;
        let underline_y = (baseline + (descent * 0.4).max(px(1.0))).min(line_height - px(1.0));
        Self {
            font: f,
            font_size,
            cell_width,
            line_height,
            underline_y,
        }
    }
}

/// The terminal font: the configured family (the first installed one among
/// it and the platform's monospace fallbacks, since a missing family would
/// fall back to a proportional UI font and break the grid), weight
/// (`terminal.fontWeight`) and ligatures (`terminal.enableLigatures`).
pub fn terminal_font(settings: &Settings, window: &Window) -> Font {
    let appearance = &settings.appearance;
    let installed = window.text_system().all_font_names();
    let family = std::iter::once(appearance.font_family.clone())
        .chain(fallback_fonts())
        .find(|name| installed.iter().any(|f| f.eq_ignore_ascii_case(name)))
        .unwrap_or_else(|| appearance.font_family.clone());
    let mut f = font(SharedString::from(family));
    f.fallbacks = Some(FontFallbacks::from_fonts(fallback_fonts()));
    f.weight = ns_font_weight(appearance.font_weight);
    f.features = font_features(
        appearance.ligatures
            && appearance.rendering.gpu_renderer
            && window
                .renderer_diagnostics()
                .is_none_or(|d| d.backend != "software"),
    );
    f
}

/// Ligatures on or off. Swift draws ligatures only in its Metal renderer, so
/// they follow the "Metal Renderer" setting too.
pub fn font_features(ligatures: bool) -> FontFeatures {
    let value = u32::from(ligatures);
    FontFeatures(Arc::new(vec![
        ("calt".into(), value),
        ("liga".into(), value),
    ]))
}

/// NSFontManager weight (0 ultralight, 5 regular, 9 bold, 14 heaviest) to a
/// CSS weight.
pub fn ns_font_weight(weight: i32) -> FontWeight {
    const TABLE: [f32; 15] = [
        100.0, 100.0, 200.0, 300.0, 350.0, 400.0, 500.0, 500.0, 600.0, 700.0, 800.0, 800.0, 900.0,
        900.0, 900.0,
    ];
    FontWeight(TABLE[weight.clamp(0, 14) as usize])
}

/// State kept by the view between frames for what is drawn over the grid.
pub struct Overlays {
    pub images: ImageLayer,
    pub timestamps: LineTimestamps,
    /// Last output (typing echoes count): the cursor stays solid for 1 s after it.
    pub last_activity: Instant,
    /// Last time the view was painted (a hidden tab is not).
    pub last_paint: Instant,
    last_history: u32,
    cpu_frame: Arc<Mutex<FrameCache>>,
}

impl Default for Overlays {
    fn default() -> Self {
        let now = Instant::now();
        Self {
            images: ImageLayer::default(),
            timestamps: LineTimestamps::default(),
            last_activity: now,
            last_paint: now,
            last_history: 0,
            cpu_frame: Arc::new(Mutex::new(FrameCache::default())),
        }
    }
}

impl Overlays {
    pub fn renderer_diagnostics(&self) -> serde_json::Value {
        let mut value = self.cpu_frame.lock().diagnostics();
        value["inline_images"] = self.images.allocation_snapshot();
        value
    }
    pub fn cache_bytes(&self) -> u64 {
        self.cpu_frame.lock().bytes()
    }
    pub fn reclaim_cache(&mut self, cx: &mut App) -> u64 {
        let bytes = self.cache_bytes();
        self.release_cpu_frame(cx);
        bytes
    }
    pub fn release_cpu_frame(&mut self, cx: &mut App) {
        self.cpu_frame.lock().release(cx);
    }

    /// After each output batch: take decoded images, follow the scrollback,
    /// stamp new lines.
    pub fn on_output(&mut self, session: &TerminalSession, settings: &Settings) {
        let start = Instant::now();
        self.on_output_inner(session, settings);
        feature_profiler::record(
            Feature::OutputMainThread,
            start.elapsed().as_secs_f64() * 1000.0,
            0,
        );
    }

    fn on_output_inner(&mut self, session: &TerminalSession, settings: &Settings) {
        self.last_activity = Instant::now();
        let images = session.take_images();
        if !images.is_empty() {
            self.images.ingest(images, settings);
        }
        let grid = &session.grid;
        let history = grid.scrollback_rows;
        if history < self.last_history {
            self.timestamps.shift((self.last_history - history) as i64);
        }
        self.last_history = history;
        self.images.track_history(history);
        if settings.appearance.display.line_timestamps {
            let line = history as i64 - grid.display_offset as i64 + session.cursor.1 as i64;
            self.timestamps.record(line, chrono::Local::now());
        }
    }

    /// Clear Scrollback.
    pub fn clear(&mut self) {
        self.images.clear();
        self.timestamps.clear();
    }

    /// Cursor blink: solid for 1 s after output or typing.
    pub fn blink_hold(&self) -> bool {
        self.last_activity.elapsed() < Duration::from_secs(1)
    }

    /// Whether the view was painted recently (visible).
    pub fn recently_painted(&self, within: Duration) -> bool {
        self.last_paint.elapsed() < within
    }
}

/// What `render` knows before layout.
pub struct FrameInputs {
    pub gpu_renderer: bool,
    pub metrics: CellMetrics,
    pub focused: bool,
    pub show_cursor: bool,
    pub cursor_shape: CursorShape,
    pub cursor_color: Hsla,
    pub background: Hsla,
    pub link_color: Hsla,
    pub match_color: Hsla,
    pub active_match_color: Hsla,
    /// Search matches as (absolute line, columns) and the current one.
    pub matches: Vec<(i64, Range<usize>)>,
    pub active_match: Option<usize>,
    pub marked_text: Option<String>,
    /// Viewport rows tinted as dangerous (typed command lines and output
    /// rows from the throttled scan, see `view/danger.rs`).
    pub danger_rows: Vec<usize>,
    pub timestamps: bool,
    pub timestamp_format: String,
    /// Local echo predictions as (column, screen row, character).
    pub local_echo: Vec<(i32, i32, char)>,
}

impl FrameInputs {
    /// Colors and options from the settings.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        settings: &Settings,
        metrics: CellMetrics,
        focused: bool,
        cursor_on: bool,
        matches: Vec<(i64, Range<usize>)>,
        active_match: Option<usize>,
        marked_text: Option<String>,
    ) -> Self {
        let appearance = &settings.appearance;
        let scheme = appearance.color_scheme;
        let background = scheme_color(scheme.background);
        let dark = background.l < 0.5;
        Self {
            gpu_renderer: appearance.rendering.gpu_renderer,
            metrics,
            focused,
            show_cursor: cursor_on || !focused || !appearance.cursor_blink,
            cursor_shape: appearance.cursor_shape.clone(),
            cursor_color: cursor_color(scheme, &appearance.cursor_color),
            background: background.opacity(crate::theme::content_opacity_for(settings)),
            link_color: link_color(dark),
            // NSColor.systemYellow at 28 %, systemOrange at 45 %.
            match_color: if dark {
                rgb_tuple((255, 214, 10)).opacity(0.28)
            } else {
                rgb_tuple((255, 204, 0)).opacity(0.28)
            },
            active_match_color: if dark {
                rgb_tuple((255, 159, 10)).opacity(0.45)
            } else {
                rgb_tuple((255, 149, 0)).opacity(0.45)
            },
            matches,
            active_match,
            marked_text,
            danger_rows: Vec::new(),
            timestamps: appearance.display.line_timestamps,
            timestamp_format: appearance.display.timestamp_format.clone(),
            local_echo: Vec::new(),
        }
    }
}

/// `terminal.cursorColor` when it parses, else the scheme's cursor color.
pub fn cursor_color(scheme: &ColorScheme, custom: &str) -> Hsla {
    let custom = custom.trim();
    if !custom.is_empty()
        && let Some(rgb) = chau7_next_core::color_parsing::parse_hex(custom)
    {
        return gpui::Rgba {
            r: rgb.red as f32,
            g: rgb.green as f32,
            b: rgb.blue as f32,
            a: 1.0,
        }
        .into();
    }
    scheme_color(scheme.cursor)
}

/// `NSColor.linkColor` in dark and light appearance.
pub fn link_color(dark: bool) -> Hsla {
    if dark {
        rgb_tuple((65, 156, 255))
    } else {
        rgb_tuple((0, 104, 218))
    }
}

/// Everything the paint closure needs, computed in prepaint.
pub struct PaintState {
    visibility: &'static str,
    cpu_frame: Arc<Mutex<FrameCache>>,
    inputs: FrameInputs,
    cols: u16,
    rows: u16,
    cells: Vec<OwnedCell>,
    clusters: HashMap<usize, String>,
    cursor: Option<(u16, u16)>,
    exited: bool,
    /// Rows holding a dangerous command (`CommandRiskDetection`), tinted red.
    danger_rows: Vec<usize>,
    /// Search matches in this viewport: (row, columns, current).
    highlights: Vec<(usize, Range<usize>, bool)>,
    images: Vec<Placement>,
    /// (row, label) for line timestamps.
    stamps: Vec<(usize, SharedString)>,
}

/// At most this many matches are highlighted per screen (Swift's cap).
const MAX_VISIBLE_MATCHES: usize = 300;

/// Snapshot the session for painting. `overlays` places the images and
/// timestamps for this viewport.
pub fn prepaint(
    session: &TerminalSession,
    mut inputs: FrameInputs,
    overlays: &mut Overlays,
) -> PaintState {
    let visibility = session.profiling_phase();
    let mut stage =
        chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::work(
            "prepaint_snapshot",
            "layout",
            visibility,
            "terminal_painter",
            chau7_next_core::work_profiler::Queue::Main,
        ));
    stage.items(session.grid.cells.len());
    overlays.last_paint = Instant::now();
    let grid = &session.grid;
    let offset = grid.display_offset as i32;
    let cursor_row = session.cursor.1 as i32 + offset;
    let cursor = (grid.cursor_visible
        && inputs.show_cursor
        && session.exited.is_none()
        && cursor_row >= 0
        && cursor_row < grid.rows as i32)
        .then_some((session.cursor.0, cursor_row as u16));
    let danger_rows = std::mem::take(&mut inputs.danger_rows);
    // Absolute line of viewport row 0.
    let top = grid.scrollback_rows as i64 - grid.display_offset as i64;
    let mut highlights = Vec::new();
    for (index, (line, range)) in inputs.matches.iter().enumerate() {
        let row = line - top;
        if (0..grid.rows as i64).contains(&row) {
            highlights.push((
                row as usize,
                range.clone(),
                Some(index) == inputs.active_match,
            ));
            if highlights.len() >= MAX_VISIBLE_MATCHES {
                break;
            }
        }
    }
    // Keep the current match even past the cap.
    if let Some((line, range)) = inputs.active_match.and_then(|i| inputs.matches.get(i))
        && !highlights.iter().any(|h| h.2)
        && (0..grid.rows as i64).contains(&(line - top))
    {
        highlights.push(((line - top) as usize, range.clone(), true));
    }
    let m = &inputs.metrics;
    let images = if overlays.images.is_empty() {
        overlays.images.last_placements.clear();
        Vec::new()
    } else {
        overlays.images.place(
            (f32::from(m.cell_width), f32::from(m.line_height)),
            (grid.cols, grid.rows),
            grid.scrollback_rows,
            grid.display_offset,
        )
    };
    let stamps = if inputs.timestamps && !overlays.timestamps.is_empty() {
        let now = chrono::Local::now();
        (0..grid.rows as usize)
            .filter_map(|row| {
                let date = overlays.timestamps.get(top + row as i64)?;
                let label = line_timestamps::relative(date, now, &inputs.timestamp_format);
                Some((row, SharedString::from(label)))
            })
            .collect()
    } else {
        Vec::new()
    };
    let mut clusters = grid.clusters.clone();
    for &(col, row, _) in &inputs.local_echo {
        let row = row + offset;
        if col >= 0 && col < grid.cols as i32 && row >= 0 {
            clusters.remove(&(row as usize * grid.cols as usize + col as usize));
        }
    }
    PaintState {
        visibility,
        cpu_frame: overlays.cpu_frame.clone(),
        clusters,
        cols: grid.cols,
        rows: grid.rows,
        cells: with_local_echo(grid.cells.clone(), grid.cols, offset, &inputs.local_echo),
        cursor,
        exited: session.exited.is_some(),
        danger_rows,
        highlights,
        images,
        stamps,
        inputs,
    }
}

/// The grid cells with local echo predictions drawn in (screen rows are
/// shifted by the scroll offset).
pub fn with_local_echo(
    mut cells: Vec<chau7_terminal::OwnedCell>,
    cols: u16,
    offset: i32,
    echo: &[(i32, i32, char)],
) -> Vec<chau7_terminal::OwnedCell> {
    for &(col, row, c) in echo {
        let row = row + offset;
        if col < 0 || row < 0 || col >= cols as i32 {
            continue;
        }
        if let Some(cell) = cells.get_mut(row as usize * cols as usize + col as usize) {
            cell.character = c;
        }
    }
    cells
}

/// A Unicode grapheme may span several native terminal cells. Keep the
/// original column range for positioning while shaping the sequence together.
#[derive(Debug, PartialEq, Eq)]
struct TextChunk {
    columns: Range<usize>,
    natural: bool,
}
fn text_chunks(
    cells: &[OwnedCell],
    clusters: &HashMap<usize, String>,
    start: usize,
) -> Vec<TextChunk> {
    use unicode_segmentation::UnicodeSegmentation;
    let mut text = String::new();
    let mut spans = Vec::new();
    for (col, cell) in cells.iter().enumerate() {
        if cell.continuation {
            continue;
        }
        let offset = text.len();
        text.push_str(&cell_text(cell, clusters.get(&(start + col))));
        spans.push((col, offset, text.len()));
    }
    let mut chunks: Vec<TextChunk> = Vec::new();
    let mut span = 0;
    for (offset, grapheme) in text.grapheme_indices(true) {
        while span < spans.len() && spans[span].2 <= offset {
            span += 1;
        }
        if span == spans.len() {
            break;
        }
        let first = span;
        let end = offset + grapheme.len();
        while span + 1 < spans.len() && spans[span + 1].1 < end {
            span += 1;
        }
        let first_col = spans[first].0;
        let last_col = spans[span].0;
        if chunks.last().is_some_and(|previous| {
            previous.columns.start <= first_col && previous.columns.end > last_col
        }) {
            continue;
        }
        let natural = first != span
            || cells[first_col].width > 1
            || clusters.contains_key(&(start + first_col));
        if !natural
            && let Some(previous) = chunks.last_mut()
            && !previous.natural
            && previous.columns.end == first_col
        {
            previous.columns.end = last_col + 1;
        } else {
            chunks.push(TextChunk {
                columns: first_col..last_col + 1,
                natural,
            });
        }
    }
    chunks
}

fn cell_text(cell: &OwnedCell, cluster: Option<&String>) -> String {
    if cell.flags & CELL_FLAG_HIDDEN != 0 {
        return " ".to_string();
    }
    cluster.cloned().unwrap_or_else(|| match cell.character {
        '\0' => " ".to_string(),
        c => c.to_string(),
    })
}

fn cell_colors(cell: &OwnedCell) -> ((u8, u8, u8), (u8, u8, u8)) {
    if cell.flags & CELL_FLAG_INVERSE != 0 {
        (cell.bg, cell.fg)
    } else {
        (cell.fg, cell.bg)
    }
}

/// Underline drawn by hand (GPUI draws only straight and wavy lines).
struct Decoration {
    col: usize,
    len: usize,
    style: u8,
    color: Hsla,
}

/// How a cell is underlined: the run style GPUI draws, or a hand-drawn variant.
fn underline_for(cell: &OwnedCell, color: Hsla, link_color: Hsla) -> (Option<UnderlineStyle>, u8) {
    if cell.flags & CELL_FLAG_UNDERLINE != 0 {
        return match cell.underline {
            UNDERLINE_CURL => (
                Some(UnderlineStyle {
                    thickness: px(1.0),
                    color: Some(color),
                    wavy: true,
                }),
                0,
            ),
            UNDERLINE_DOUBLE | UNDERLINE_DOTTED | UNDERLINE_DASHED => (None, cell.underline),
            _ => (
                Some(UnderlineStyle {
                    thickness: px(1.0),
                    color: Some(color),
                    wavy: false,
                }),
                0,
            ),
        };
    }
    // OSC 8 hyperlinks: underlined in the link color.
    if cell.link_id != 0 {
        return (
            Some(UnderlineStyle {
                thickness: px(1.0),
                color: Some(link_color),
                wavy: false,
            }),
            0,
        );
    }
    (None, 0)
}

pub fn paint_grid(bounds: Bounds<Pixels>, state: PaintState, window: &mut Window, cx: &mut App) {
    if crate::hang_watchdog::render_blocked() {
        return;
    }
    let mut stage =
        chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::work(
            "grid_paint",
            "draw",
            state.visibility,
            "terminal_painter",
            chau7_next_core::work_profiler::Queue::Main,
        ));
    stage.items(state.cells.len());
    feature_profiler::measure(Feature::TerminalRender, 0, || {
        paint_grid_inner(bounds, state, window, cx)
    })
}

fn paint_grid_inner(bounds: Bounds<Pixels>, state: PaintState, window: &mut Window, cx: &mut App) {
    let mut canvas = GridCanvas::new(
        window,
        bounds,
        state.inputs.gpu_renderer,
        state.cpu_frame.clone(),
        state.visibility,
        cx,
    );
    let window = &mut canvas;
    let inputs = &state.inputs;
    let m = &inputs.metrics;
    let cols = state.cols as usize;
    window.paint_quad(fill(bounds, inputs.background));
    let default_bg = {
        let c = inputs.background.to_rgb();
        (
            (c.r * 255.0).round() as u8,
            (c.g * 255.0).round() as u8,
            (c.b * 255.0).round() as u8,
        )
    };
    let cell_rect = |col: usize, row: usize, len: usize| {
        Bounds::new(
            point(
                bounds.left() + m.cell_width * col as f32,
                bounds.top() + m.line_height * row as f32,
            ),
            size(m.cell_width * len as f32, m.line_height),
        )
    };

    for row in 0..state.rows as usize {
        let y = bounds.top() + m.line_height * row as f32;
        let start = row * cols;
        let Some(row_cells) = state.cells.get(start..start + cols) else {
            break;
        };

        // Backgrounds: merge runs of the same non-default color.
        let mut col = 0;
        while col < cols {
            let (_, bg) = cell_colors(&row_cells[col]);
            let mut end = col + 1;
            while end < cols && cell_colors(&row_cells[end]).1 == bg {
                end += 1;
            }
            if bg != default_bg {
                window.paint_quad(fill(cell_rect(col, row, end - col), rgb_tuple(bg)));
            }
            col = end;
        }

        if state.danger_rows.contains(&row) {
            window.paint_quad(fill(
                Bounds::new(
                    point(bounds.left(), y),
                    size(bounds.size.width, m.line_height),
                ),
                gpui::hsla(0.0, 0.85, 0.5, 0.14),
            ));
            window.paint_quad(fill(
                Bounds::new(
                    point(bounds.left() - px(3.0), y),
                    size(px(2.0), m.line_height),
                ),
                gpui::hsla(0.0, 0.85, 0.55, 0.9),
            ));
        }

        // Search matches, inset by half a point like `TerminalHighlightView`.
        for (hl_row, range, active) in &state.highlights {
            if *hl_row != row || range.start >= cols {
                continue;
            }
            let len = (range.end.min(cols) - range.start).max(1);
            let rect = cell_rect(range.start, row, len);
            let rect = Bounds::new(
                point(rect.left() + px(0.5), rect.top() + px(0.5)),
                size(rect.size.width - px(1.0), rect.size.height - px(1.0)),
            );
            let color = if *active {
                inputs.active_match_color
            } else {
                inputs.match_color
            };
            window.paint_quad(fill(rect, color));
        }

        // Text runs.
        let mut decorations: Vec<Decoration> = Vec::new();
        for chunk in text_chunks(row_cells, &state.clusters, start) {
            let mut text = String::with_capacity(chunk.columns.len());
            let mut runs: Vec<TextRun> = Vec::new();
            let mut any_visible = false;
            for col in chunk.columns.clone() {
                let cell = &row_cells[col];
                if cell.continuation {
                    continue;
                }
                let contents = cell_text(cell, state.clusters.get(&(start + col)));
                // One extended grapheme uses its leading cell style. Style
                // boundaries inside a ZWJ sequence must not split its shaping.
                let cell = if chunk.natural {
                    &row_cells[chunk.columns.start]
                } else {
                    cell
                };
                let (fg, bg) = cell_colors(cell);
                let mut color = rgb_tuple(if cell.flags & CELL_FLAG_HIDDEN != 0 {
                    bg
                } else {
                    fg
                });
                if cell.flags & CELL_FLAG_DIM != 0 {
                    color.a *= 0.6;
                }
                let mut run_font = m.font.clone();
                if chunk.natural {
                    run_font.features = FontFeatures::default();
                }
                if cell.flags & CELL_FLAG_BOLD != 0 {
                    run_font.weight = FontWeight(run_font.weight.0.max(FontWeight::BOLD.0));
                }
                if cell.flags & CELL_FLAG_ITALIC != 0 {
                    run_font.style = FontStyle::Italic;
                }
                let (underline, hand_drawn) = underline_for(cell, color, inputs.link_color);
                if hand_drawn != 0 {
                    match decorations.last_mut() {
                        Some(d)
                            if d.style == hand_drawn
                                && d.color == color
                                && d.col + d.len == col =>
                        {
                            d.len += usize::from(cell.width.max(1))
                        }
                        _ => decorations.push(Decoration {
                            col,
                            len: usize::from(cell.width.max(1)),
                            style: hand_drawn,
                            color,
                        }),
                    }
                }
                let strikethrough =
                    (cell.flags & CELL_FLAG_STRIKETHROUGH != 0).then(|| StrikethroughStyle {
                        thickness: px(1.0),
                        color: Some(color),
                    });
                let len = contents.len();
                any_visible |= contents != " " || underline.is_some() || strikethrough.is_some();
                text.push_str(&contents);
                match runs.last_mut() {
                    Some(last)
                        if last.color == color
                            && last.font == run_font
                            && last.underline == underline
                            && last.strikethrough == strikethrough =>
                    {
                        last.len += len;
                    }
                    _ => runs.push(TextRun {
                        len,
                        font: run_font,
                        color,
                        background_color: None,
                        underline,
                        strikethrough,
                    }),
                }
            }
            if any_visible {
                let shape = chau7_next_core::work_profiler::begin(
                    chau7_next_core::work_profiler::Key::work(
                        "shape_line",
                        "draw",
                        state.visibility,
                        "terminal_painter",
                        chau7_next_core::work_profiler::Queue::Main,
                    ),
                );
                let line = window.text_system().shape_line(
                    text.into(),
                    m.font_size,
                    &runs,
                    // Full clusters are shaped naturally, independently of the
                    // next chunk's position. Normal runs keep the fast grid layout.
                    (!chunk.natural).then_some(m.cell_width),
                );
                drop(shape);
                let _ = window.paint_line(
                    &line,
                    point(bounds.left() + m.cell_width * chunk.columns.start as f32, y),
                    m.line_height,
                    &runs,
                    cx,
                );
            }
        }
        for d in decorations {
            paint_decoration(&d, bounds.left(), y, m, window);
        }
    }

    // Images over the text, clipped to the grid.
    for placement in &state.images {
        let image_bounds = Bounds::new(
            bounds.origin + placement.bounds.origin,
            placement.bounds.size,
        );
        let _ = window.paint_image(
            bounds,
            image_bounds,
            gpui::Corners::default(),
            placement.render.clone(),
            0,
            false,
        );
    }

    // Line timestamps in the right margin (`TimestampOverlayView`: 9 pt, secondary).
    if !state.stamps.is_empty() {
        let fg = scheme_fg_muted(inputs.background);
        let font_size = px(9.0);
        for (row, label) in &state.stamps {
            let run = TextRun {
                len: label.len(),
                font: m.font.clone(),
                color: fg,
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            let line = window.text_system().shape_line(
                label.clone(),
                font_size,
                std::slice::from_ref(&run),
                None,
            );
            let x = bounds.right() - line.width - px(2.0);
            let _ = window.paint_line(
                &line,
                point(x, bounds.top() + m.line_height * *row as f32),
                m.line_height,
                std::slice::from_ref(&run),
                cx,
            );
        }
    }

    paint_cursor(bounds, &state, window, cx);

    if state.exited {
        let label: SharedString =
            crate::l10n::platform("[Process exited. Press Cmd+W to close the tab.]").into();
        let run = TextRun {
            len: label.len(),
            font: m.font.clone(),
            color: gpui::hsla(0.0, 0.0, 0.6, 1.0),
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        let line =
            window
                .text_system()
                .shape_line(label, m.font_size, std::slice::from_ref(&run), None);
        let _ = window.paint_line(
            &line,
            point(
                bounds.left() + px(4.0),
                bounds.bottom() - m.line_height - px(4.0),
            ),
            m.line_height,
            std::slice::from_ref(&run),
            cx,
        );
    }
    canvas.finish(cx);
}

fn scheme_fg_muted(background: Hsla) -> Hsla {
    if background.l < 0.5 {
        gpui::hsla(0.0, 0.0, 0.85, 0.55)
    } else {
        gpui::hsla(0.0, 0.0, 0.15, 0.55)
    }
}

/// Double, dotted and dashed underlines (`RustGridView.draw` decorations).
fn paint_decoration(
    d: &Decoration,
    left: Pixels,
    y: Pixels,
    m: &CellMetrics,
    window: &mut GridCanvas<'_>,
) {
    let x0 = left + m.cell_width * d.col as f32;
    let width = m.cell_width * d.len as f32;
    let uy = y + m.underline_y;
    let thickness = px(1.0);
    let line = |x: Pixels, y: Pixels, w: Pixels| Bounds::new(point(x, y), size(w, thickness));
    match d.style {
        UNDERLINE_DOUBLE => {
            // Second line two thicknesses above (Swift draws it below the baseline line).
            window.paint_quad(fill(line(x0, uy, width), d.color));
            window.paint_quad(fill(line(x0, uy - thickness * 2.0, width), d.color));
        }
        UNDERLINE_DOTTED => {
            let step = 3.0;
            let mut x = 0.0;
            while x < f32::from(width) {
                let w = (f32::from(width) - x).min(1.5);
                window.paint_quad(fill(line(x0 + px(x), uy, px(w)), d.color));
                x += step;
            }
        }
        UNDERLINE_DASHED => {
            // Per cell: dash 30 % of the cell, gap 15 %.
            let cw = f32::from(m.cell_width);
            let (dash, gap) = (cw * 0.3, cw * 0.15);
            let mut x = 0.0;
            while x < f32::from(width) {
                let w = (f32::from(width) - x).min(dash);
                window.paint_quad(fill(line(x0 + px(x), uy, px(w)), d.color));
                x += dash + gap;
            }
        }
        _ => {}
    }
}

fn paint_cursor(
    bounds: Bounds<Pixels>,
    state: &PaintState,
    window: &mut GridCanvas<'_>,
    cx: &mut App,
) {
    let inputs = &state.inputs;
    let m = &inputs.metrics;
    let cols = state.cols as usize;
    let Some((col, row)) = state.cursor else {
        return;
    };
    let origin = point(
        bounds.left() + m.cell_width * col as f32,
        bounds.top() + m.line_height * row as f32,
    );
    let index = row as usize * cols + col as usize;
    let width = state.cells.get(index).map_or(1, |cell| cell.width.max(1));
    let cell_bounds = Bounds::new(origin, size(m.cell_width * f32::from(width), m.line_height));
    if !inputs.focused {
        window.paint_quad(outline(
            cell_bounds,
            inputs.cursor_color,
            gpui::BorderStyle::Solid,
        ));
    } else {
        match inputs.cursor_shape {
            CursorShape::Block => {
                window.paint_quad(fill(cell_bounds, inputs.cursor_color));
                let index = row as usize * cols + col as usize;
                if let Some(cell) = state.cells.get(index)
                    && cell.character != ' '
                    && cell.character != '\0'
                {
                    let mut f = m.font.clone();
                    if cell.flags & CELL_FLAG_BOLD != 0 {
                        f.weight = FontWeight(f.weight.0.max(FontWeight::BOLD.0));
                    }
                    let s: SharedString = cell_text(cell, state.clusters.get(&index)).into();
                    let run = TextRun {
                        len: s.len(),
                        font: f,
                        color: inputs.background.opacity(1.0),
                        background_color: None,
                        underline: None,
                        strikethrough: None,
                    };
                    let line = window.text_system().shape_line(
                        s,
                        m.font_size,
                        std::slice::from_ref(&run),
                        None,
                    );
                    let _ = window.paint_line(
                        &line,
                        origin,
                        m.line_height,
                        std::slice::from_ref(&run),
                        cx,
                    );
                }
            }
            CursorShape::Bar => {
                window.paint_quad(fill(
                    Bounds::new(origin, size(px(2.0), m.line_height)),
                    inputs.cursor_color,
                ));
            }
            CursorShape::Underline => {
                window.paint_quad(fill(
                    Bounds::new(
                        point(origin.x, origin.y + m.line_height - px(2.0)),
                        size(m.cell_width * f32::from(width), px(2.0)),
                    ),
                    inputs.cursor_color,
                ));
            }
        }
    }
    // IME composition text, underlined at the cursor.
    if let Some(marked) = inputs.marked_text.clone() {
        let s: SharedString = marked.into();
        let width = m.cell_width * s.chars().count() as f32;
        window.paint_quad(fill(
            Bounds::new(origin, size(width, m.line_height)),
            inputs.background,
        ));
        let run = TextRun {
            len: s.len(),
            font: m.font.clone(),
            color: inputs.cursor_color,
            background_color: None,
            underline: Some(UnderlineStyle {
                thickness: px(1.0),
                color: Some(inputs.cursor_color),
                wavy: false,
            }),
            strikethrough: None,
        };
        let line = window.text_system().shape_line(
            s,
            m.font_size,
            std::slice::from_ref(&run),
            Some(m.cell_width),
        );
        let _ = window.paint_line(&line, origin, m.line_height, std::slice::from_ref(&run), cx);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concealed_color_emoji_never_reaches_either_renderer() {
        let cell = OwnedCell {
            character: '👩',
            flags: CELL_FLAG_HIDDEN,
            ..Default::default()
        };
        assert_eq!(cell_text(&cell, Some(&"👩‍💻".to_string())), " ");
    }
    #[test]
    fn full_graphemes_are_anchored_to_grid_columns() {
        let mut cells = vec![OwnedCell::default(); 7];
        cells[0].character = 'a';
        cells[1].character = 'e';
        cells[2].character = '👩';
        cells[2].width = 2;
        cells[3].continuation = true;
        cells[3].width = 0;
        cells[4].character = '中';
        cells[4].width = 2;
        cells[5].continuation = true;
        cells[5].width = 0;
        cells[6].character = 'z';
        let clusters = HashMap::from([(8, "e\u{301}".to_string()), (9, "👩‍💻".to_string())]);
        assert_eq!(
            text_chunks(&cells, &clusters, 7)
                .into_iter()
                .map(|chunk| chunk.columns)
                .collect::<Vec<_>>(),
            vec![0..1, 1..2, 2..3, 4..5, 6..7]
        );
        assert_eq!(cell_text(&cells[1], clusters.get(&8)), "e\u{301}");
        assert_eq!(cell_text(&cells[2], clusters.get(&9)), "👩‍💻");
    }

    #[test]
    fn painter_consumes_the_terminal_snapshot_clusters() {
        let term = chau7_terminal::Chau7Terminal::new_headless(30, 1).unwrap();
        term.inject_output("❤\u{fe0f}👩‍💻🇫🇷a\u{20dd}z".as_bytes());
        let grid = term.grid_copy();
        let mut painted = String::new();
        for chunk in text_chunks(&grid.cells, &grid.clusters, 0) {
            for index in chunk.columns {
                if grid.cells[index].continuation {
                    continue;
                }
                painted.push_str(&cell_text(&grid.cells[index], grid.clusters.get(&index)));
            }
        }
        assert!(painted.starts_with("❤\u{fe0f}👩‍💻🇫🇷a\u{20dd}z"), "{painted}");
    }

    #[test]
    fn native_grid_emoji_sequences_are_each_one_naturally_shaped_chunk() {
        let term = chau7_terminal::Chau7Terminal::new_headless(80, 1).unwrap();
        term.inject_output("A👩🏽‍💻B👨‍👩‍👧‍👦C🇫🇷Da\u{20dd}E".as_bytes());
        let grid = term.grid_copy();
        let chunks = text_chunks(&grid.cells, &grid.clusters, 0);
        let rendered: Vec<(String, Range<usize>, bool)> = chunks
            .iter()
            .map(|chunk| {
                let text = chunk
                    .columns
                    .clone()
                    .filter(|index| !grid.cells[*index].continuation)
                    .map(|index| cell_text(&grid.cells[index], grid.clusters.get(&index)))
                    .collect::<String>();
                (text, chunk.columns.clone(), chunk.natural)
            })
            .collect();
        for sequence in ["👩🏽‍💻", "👨‍👩‍👧‍👦", "🇫🇷", "a\u{20dd}"] {
            let matching: Vec<_> = rendered
                .iter()
                .filter(|(text, _, _)| text == sequence)
                .collect();
            assert_eq!(matching.len(), 1, "{sequence}: {rendered:?}");
            assert!(matching[0].2);
        }
        let woman = rendered.iter().find(|(text, _, _)| text == "👩🏽‍💻").unwrap();
        assert_eq!(woman.1, 1..6);
        let family = rendered.iter().find(|(text, _, _)| text == "👨‍👩‍👧‍👦").unwrap();
        assert_eq!(family.1, 8..15);
        assert!(
            rendered
                .iter()
                .any(|(text, range, natural)| text == "B" && range.start == 7 && !*natural)
        );
    }

    #[test]
    fn control_boundaries_inside_one_native_cell_do_not_duplicate_its_paint() {
        let cells = vec![OwnedCell::default()];
        let clusters = HashMap::from([(0, "a\u{200b}".to_string())]);
        let chunks = text_chunks(&cells, &clusters, 0);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].columns, 0..1);
        assert!(chunks[0].natural);
    }
    #[test]
    fn ascii_rows_still_shape_in_one_batch() {
        let cells = vec![OwnedCell::default(); 80];
        assert_eq!(
            text_chunks(&cells, &HashMap::new(), 0)
                .into_iter()
                .map(|chunk| chunk.columns)
                .collect::<Vec<_>>(),
            vec![0..80]
        );
    }

    #[test]
    fn font_weights_follow_ns_font_manager() {
        assert_eq!(ns_font_weight(5), FontWeight::NORMAL);
        assert_eq!(ns_font_weight(9), FontWeight::BOLD);
        assert_eq!(ns_font_weight(-1), FontWeight(100.0));
        assert_eq!(ns_font_weight(99), FontWeight(900.0));
    }

    #[test]
    fn ligature_features() {
        assert_eq!(font_features(false).is_calt_enabled(), Some(false));
        assert_eq!(font_features(true).is_calt_enabled(), Some(true));
    }

    #[test]
    fn cursor_color_override() {
        let scheme = ColorScheme::named("Default");
        assert_eq!(cursor_color(scheme, ""), scheme_color(scheme.cursor));
        assert_eq!(
            cursor_color(scheme, "nonsense"),
            scheme_color(scheme.cursor)
        );
        let red = cursor_color(scheme, "#FF0000");
        assert_eq!(red.to_rgb().r, 1.0);
        assert_eq!(red.to_rgb().g, 0.0);
    }

    #[test]
    fn underline_variants() {
        let color = gpui::red();
        let link = gpui::blue();
        let mut cell = OwnedCell {
            flags: CELL_FLAG_UNDERLINE,
            underline: UNDERLINE_CURL,
            ..Default::default()
        };
        assert!(underline_for(&cell, color, link).0.unwrap().wavy);
        cell.underline = UNDERLINE_DOUBLE;
        assert_eq!(underline_for(&cell, color, link), (None, UNDERLINE_DOUBLE));
        cell.underline = 1;
        assert!(!underline_for(&cell, color, link).0.unwrap().wavy);
        // Hyperlink without SGR underline: link color.
        let link_cell = OwnedCell {
            link_id: 3,
            ..Default::default()
        };
        assert_eq!(
            underline_for(&link_cell, color, link).0.unwrap().color,
            Some(link)
        );
        assert_eq!(underline_for(&OwnedCell::default(), color, link), (None, 0));
    }
}
