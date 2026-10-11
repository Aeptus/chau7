//! Syntax colors for the editor, preview and diff panes, plugged into the
//! gpui-kit code editor as an `InputHighlighter`.
//!
//! The editor uses the Swift regex rules of its language
//! (`EditorLanguage.highlightingRules`, EDT-005), reapplied 150 ms after the
//! last edit (`applySyntaxHighlighting` behind a 0.15 s timer); between the
//! edit and the new pass the old colors move with the text. The preview
//! uses output-style colors (`SyntaxHighlighter`, EDT-001) line by line
//! through the shared line cache, and the diff pane colors whole rows.
//!
//! Every byte gets an explicit color (the theme's text color where no rule
//! applies), so the editor theme does not depend on the gpui-kit theme.

use std::cell::RefCell;
use std::ops::Range;
use std::rc::Rc;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use chau7_next_core::editor::config::EditorTheme;
use chau7_next_core::editor::diff::DiffRowKind;
use chau7_next_core::editor::language::EditorLanguage;
use chau7_next_core::editor::output_highlight::{OutputHighlightOptions, OutputHighlighter};
use chau7_next_core::editor::{HighlightColor, HighlightSpan};
use gpui::{FontWeight, HighlightStyle, Hsla, SharedString, Task, UnderlineStyle, Window, px};
use gpui_kit::base::input::{
    EditorState, FoldRange, HighlightStyleResolver, InputEdit, InputHighlighter,
    InputHighlighterFactory, Rope,
};

/// How a pane's text is colored.
#[derive(Clone)]
pub enum HighlightMode {
    /// Language rules (text editor).
    Language(&'static EditorLanguage),
    /// Output-style colors, per line (file preview).
    Output(OutputHighlightOptions),
    /// One kind per line (diff viewer).
    Diff(Arc<Vec<DiffRowKind>>),
}

/// Colors a highlighter paints with.
#[derive(Clone, Copy, PartialEq)]
pub struct Palette {
    pub theme: EditorTheme,
    /// Window appearance, for the themes that follow it.
    pub dark: bool,
}

impl Palette {
    pub fn foreground(&self) -> Hsla {
        rgb(self.theme.colors(self.dark).foreground)
    }

    /// A language rule color in the editor theme (strings, keywords...).
    pub fn color(&self, color: HighlightColor) -> Hsla {
        rgb(self.theme.syntax_rgb(color, self.dark))
    }

    /// A status color (errors red, additions green): the system color for
    /// the theme's background, whatever the theme maps rule colors to.
    pub fn status(&self, color: HighlightColor) -> Hsla {
        let dark = self.theme.colors(self.dark).dark;
        rgb(chau7_next_core::editor::config::system_rgb(color, dark))
    }
}

pub fn rgb(value: u32) -> Hsla {
    gpui::rgb(value).into()
}

/// The output highlighter shared by every preview pane (one line cache, as
/// `SyntaxHighlighter.shared`).
fn output_highlighter() -> &'static Mutex<OutputHighlighter> {
    static SHARED: OnceLock<Mutex<OutputHighlighter>> = OnceLock::new();
    SHARED.get_or_init(|| Mutex::new(OutputHighlighter::default()))
}

/// Styled ranges for `text`, sorted, not overlapping.
fn compute(
    mode: &HighlightMode,
    palette: Palette,
    text: &str,
) -> Vec<(Range<usize>, HighlightStyle)> {
    // Language rules use the theme's colors; output colors mean a status.
    let output = matches!(mode, HighlightMode::Output(_));
    let paint = |color: HighlightColor| {
        if output {
            palette.status(color)
        } else {
            palette.color(color)
        }
    };
    let style_of = |span: &HighlightSpan| HighlightStyle {
        color: Some(paint(span.color)),
        font_weight: span.bold.then_some(FontWeight::BOLD),
        underline: span.link.as_ref().map(|_| UnderlineStyle {
            thickness: px(1.0),
            color: Some(paint(span.color)),
            wavy: false,
        }),
        ..Default::default()
    };
    match mode {
        HighlightMode::Language(lang) => lang
            .highlight(text)
            .iter()
            .map(|s| (s.range.clone(), style_of(s)))
            .collect(),
        HighlightMode::Output(options) => {
            let mut highlighter = output_highlighter()
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            highlighter.set_options(*options);
            let mut out = Vec::new();
            let mut offset = 0;
            for line in text.split('\n') {
                for span in highlighter.highlight(line) {
                    out.push((
                        span.range.start + offset..span.range.end + offset,
                        style_of(&span),
                    ));
                }
                offset += line.len() + 1;
            }
            out
        }
        HighlightMode::Diff(kinds) => {
            let mut out = Vec::new();
            let mut offset = 0;
            for (index, line) in text.split('\n').enumerate() {
                let range = offset..offset + line.len();
                offset += line.len() + 1;
                if range.is_empty() {
                    continue;
                }
                let style = match kinds.get(index) {
                    Some(DiffRowKind::Addition) => HighlightStyle {
                        color: Some(palette.status(HighlightColor::Green)),
                        background_color: Some(palette.status(HighlightColor::Green).opacity(0.15)),
                        ..Default::default()
                    },
                    Some(DiffRowKind::Deletion) => HighlightStyle {
                        color: Some(palette.status(HighlightColor::Red)),
                        background_color: Some(palette.status(HighlightColor::Red).opacity(0.15)),
                        ..Default::default()
                    },
                    Some(DiffRowKind::HunkHeader) => HighlightStyle {
                        color: Some(palette.status(HighlightColor::Blue)),
                        background_color: Some(palette.status(HighlightColor::Blue).opacity(0.1)),
                        font_weight: Some(FontWeight::MEDIUM),
                        ..Default::default()
                    },
                    _ => continue,
                };
                out.push((range, style));
            }
            out
        }
    }
}

struct Inner {
    mode: HighlightMode,
    palette: Palette,
    spans: Vec<(Range<usize>, HighlightStyle)>,
}

/// Debounce of the editor re-highlight (`syntaxTimer`, 0.15 s).
const DEBOUNCE: Duration = Duration::from_millis(150);
/// Larger texts are colored in the background even on the first pass.
const SYNC_MAX_BYTES: usize = 512 * 1024;

pub struct SpanHighlighter {
    inner: Rc<RefCell<Inner>>,
    task: Rc<RefCell<Option<Task<()>>>>,
}

impl SpanHighlighter {
    fn new(mode: HighlightMode, palette: Palette) -> Self {
        Self {
            inner: Rc::new(RefCell::new(Inner {
                mode,
                palette,
                spans: Vec::new(),
            })),
            task: Rc::new(RefCell::new(None)),
        }
    }

    /// Recolor `text` after `delay` on a background thread.
    fn schedule(
        &mut self,
        text: &Rope,
        delay: Duration,
        window: &mut Window,
        cx: &mut gpui::Context<EditorState>,
    ) {
        let inner = self.inner.clone();
        let (mode, palette) = {
            let i = inner.borrow();
            (i.mode.clone(), i.palette)
        };
        let text = text.to_string();
        let task = cx.spawn_in(window, async move |entity, cx| {
            if !delay.is_zero() {
                cx.background_executor().timer(delay).await;
            }
            let spans = cx
                .background_executor()
                .spawn(async move { compute(&mode, palette, &text) })
                .await;
            inner.borrow_mut().spans = spans;
            let _ = entity.update(cx, |_, cx| cx.notify());
        });
        self.task.borrow_mut().replace(task);
    }

    /// Move the current colors with an edit until the next pass.
    fn shift(&mut self, edit: &InputEdit) {
        let delta = edit.new_end_byte as isize - edit.old_end_byte as isize;
        let mut inner = self.inner.borrow_mut();
        inner.spans.retain_mut(|(range, _)| {
            if range.start >= edit.old_end_byte {
                range.start = (range.start as isize + delta).max(0) as usize;
                range.end = (range.end as isize + delta).max(0) as usize;
                true
            } else if range.end <= edit.start_byte {
                true
            } else {
                // Touched by the edit: keep the part before it.
                range.end = edit.start_byte;
                range.start < range.end
            }
        });
    }
}

impl InputHighlighter for SpanHighlighter {
    fn language(&self) -> SharedString {
        match &self.inner.borrow().mode {
            HighlightMode::Language(lang) => lang.id.into(),
            _ => "text".into(),
        }
    }

    fn update(
        &mut self,
        edit: Option<InputEdit>,
        text: &Rope,
        _folding: bool,
        window: &mut Window,
        cx: &mut gpui::Context<EditorState>,
    ) {
        match edit {
            Some(edit) => {
                self.shift(&edit);
                self.schedule(text, DEBOUNCE, window, cx);
            }
            None if text.len() <= SYNC_MAX_BYTES => {
                self.task.borrow_mut().take();
                let (mode, palette) = {
                    let i = self.inner.borrow();
                    (i.mode.clone(), i.palette)
                };
                let spans = compute(&mode, palette, &text.to_string());
                self.inner.borrow_mut().spans = spans;
            }
            None => self.schedule(text, Duration::ZERO, window, cx),
        }
    }

    fn styles(
        &self,
        range: &Range<usize>,
        _resolver: &dyn HighlightStyleResolver,
    ) -> Vec<(Range<usize>, HighlightStyle)> {
        let inner = self.inner.borrow();
        let plain = HighlightStyle {
            color: Some(inner.palette.foreground()),
            ..Default::default()
        };
        let spans = &inner.spans;
        // First span that ends after the range start.
        let first = spans.partition_point(|(r, _)| r.end <= range.start);
        let mut out = Vec::new();
        let mut cursor = range.start;
        for (span, style) in &spans[first..] {
            if span.start >= range.end {
                break;
            }
            let start = span.start.max(range.start);
            let end = span.end.min(range.end);
            if start > cursor {
                out.push((cursor..start, plain));
            }
            if end > start.max(cursor) {
                let mut style = *style;
                if style.color.is_none() {
                    style.color = plain.color;
                }
                out.push((start.max(cursor)..end, style));
                cursor = end;
            }
        }
        if cursor < range.end {
            out.push((cursor..range.end, plain));
        }
        out
    }

    fn fold_ranges(&self, _text: &Rope) -> Vec<FoldRange> {
        Vec::new()
    }
}

/// A factory that gives every editor state of a pane this mode and palette.
pub fn factory(mode: HighlightMode, palette: Palette) -> InputHighlighterFactory {
    Rc::new(move |_language| {
        Some(Box::new(SpanHighlighter::new(mode.clone(), palette)) as Box<dyn InputHighlighter>)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct NoStyles;
    impl HighlightStyleResolver for NoStyles {
        fn style(&self, _: &str) -> Option<HighlightStyle> {
            None
        }
    }

    fn palette() -> Palette {
        Palette {
            theme: EditorTheme::Default,
            dark: true,
        }
    }

    #[test]
    fn styles_cover_the_whole_range_in_order() {
        let text = "let x = \"s\"; // c";
        let h = SpanHighlighter::new(
            HighlightMode::Language(&chau7_next_core::editor::language::RUST),
            palette(),
        );
        let mode = h.inner.borrow().mode.clone();
        h.inner.borrow_mut().spans = compute(&mode, palette(), text);
        for range in [0..text.len(), 2..9, 5..6] {
            let runs = h.styles(&range, &NoStyles);
            assert_eq!(runs.first().unwrap().0.start, range.start);
            assert_eq!(runs.last().unwrap().0.end, range.end);
            for pair in runs.windows(2) {
                assert_eq!(pair[0].0.end, pair[1].0.start);
            }
            assert!(runs.iter().all(|(_, s)| s.color.is_some()));
        }
    }

    #[test]
    fn edits_move_colors() {
        let mut h = SpanHighlighter::new(HighlightMode::Output(Default::default()), palette());
        h.inner.borrow_mut().spans = vec![
            (0..3, HighlightStyle::default()),
            (10..12, HighlightStyle::default()),
        ];
        h.shift(&InputEdit {
            start_byte: 5,
            old_end_byte: 5,
            new_end_byte: 8,
            start_position: gpui_kit::base::input::Point::new(0, 0),
            old_end_position: gpui_kit::base::input::Point::new(0, 0),
            new_end_position: gpui_kit::base::input::Point::new(0, 0),
        });
        let spans: Vec<_> = h
            .inner
            .borrow()
            .spans
            .iter()
            .map(|(r, _)| r.clone())
            .collect();
        assert_eq!(spans, vec![0..3, 13..15]);
    }

    #[test]
    fn diff_rows_get_line_colors() {
        let kinds = Arc::new(vec![
            DiffRowKind::HunkHeader,
            DiffRowKind::Context,
            DiffRowKind::Addition,
        ]);
        let spans = compute(&HighlightMode::Diff(kinds), palette(), "@@ x\n ctx\n+add");
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[1].0, 10..14);
        assert!(spans[1].1.background_color.is_some());
    }
}
