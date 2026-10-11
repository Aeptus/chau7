//! Markdown runbook view (`SplitPanes/MarkdownRunbookView.swift`): headings,
//! text with inline markdown, and fenced code blocks with their language
//! tag and a Run button that types the block into the tab's first terminal.

use std::rc::Rc;

use chau7_next_core::editor::markdown::{MarkdownSection, parse_inline, parse_markdown};
use gpui::{
    App, ElementId, FontStyle, FontWeight, HighlightStyle, Hsla, InteractiveText, SharedString,
    StrikethroughStyle, StyledText, UnderlineStyle, Window, div, prelude::*, px,
};
use gpui_kit::component::{Icon, IconName};

use crate::theme::Chrome;

type RunHandler = Rc<dyn Fn(&String, &mut Window, &mut App)>;

pub(super) fn render(
    content: &str,
    chrome: Chrome,
    background: Hsla,
    mono: SharedString,
    on_run: impl Fn(&String, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let on_run: RunHandler = Rc::new(on_run);
    let mut column = div().flex().flex_col().gap_3().p_4();
    for (index, section) in parse_markdown(content).into_iter().enumerate() {
        column = column.child(match section {
            MarkdownSection::Heading { level, text } => {
                let (size, weight) = match level {
                    1 => (22.0, FontWeight::BOLD),
                    2 => (18.0, FontWeight::SEMIBOLD),
                    3 => (15.0, FontWeight::SEMIBOLD),
                    _ => (13.0, FontWeight::MEDIUM),
                };
                div()
                    .when(level == 1, |d| d.pt_2())
                    .when(level > 1, |d| d.pt_1())
                    .text_size(px(size))
                    .font_weight(weight)
                    .child(text)
                    .into_any_element()
            }
            MarkdownSection::Text(text) => inline_text(index, &text, chrome).into_any_element(),
            MarkdownSection::CodeBlock { language, code } => {
                code_block(index, language, code, chrome, mono.clone(), on_run.clone())
                    .into_any_element()
            }
        });
    }
    div()
        .id("runbook")
        .size_full()
        .overflow_y_scroll()
        .bg(background)
        .text_color(chrome.text)
        .text_size(px(13.0))
        .child(column)
}

/// A text block with inline markdown (bold, italic, code, strike, links).
fn inline_text(index: usize, text: &str, chrome: Chrome) -> impl IntoElement {
    let runs = parse_inline(text);
    let mut full = String::new();
    let mut highlights = Vec::new();
    let mut links = Vec::new();
    for run in &runs {
        let start = full.len();
        full.push_str(&run.text);
        let range = start..full.len();
        let mut style = HighlightStyle::default();
        if run.bold {
            style.font_weight = Some(FontWeight::BOLD);
        }
        if run.italic {
            style.font_style = Some(FontStyle::Italic);
        }
        if run.code {
            style.background_color = Some(chrome.text.opacity(0.08));
        }
        if run.strike {
            style.strikethrough = Some(StrikethroughStyle {
                thickness: px(1.0),
                color: None,
            });
        }
        if let Some(url) = &run.link {
            style.color = Some(chrome.accent);
            style.underline = Some(UnderlineStyle {
                thickness: px(1.0),
                color: Some(chrome.accent),
                wavy: false,
            });
            links.push((range.clone(), url.clone()));
        }
        if style != HighlightStyle::default() {
            highlights.push((range, style));
        }
    }
    let ranges: Vec<_> = links.iter().map(|(r, _)| r.clone()).collect();
    let styled = StyledText::new(full).with_highlights(highlights);
    div().w_full().child(
        InteractiveText::new(
            ElementId::Name(format!("runbook-text-{index}").into()),
            styled,
        )
        .on_click(ranges, move |i, _, cx| {
            if let Some((_, url)) = links.get(i) {
                cx.open_url(url);
            }
        }),
    )
}

fn code_block(
    index: usize,
    language: Option<String>,
    code: String,
    chrome: Chrome,
    mono: SharedString,
    on_run: RunHandler,
) -> impl IntoElement {
    let run_code = code.clone();
    div()
        .flex()
        .flex_col()
        .rounded_md()
        .overflow_hidden()
        .border_1()
        .border_color(chrome.border)
        .child(
            div()
                .flex()
                .items_center()
                .px(px(10.0))
                .py(px(6.0))
                .bg(chrome.tab_bg)
                .children(language.filter(|l| !l.is_empty()).map(|lang| {
                    div()
                        .font_family(mono.clone())
                        .text_size(px(10.0))
                        .text_color(chrome.text_muted)
                        .child(lang)
                }))
                .child(div().flex_1())
                .child(
                    div()
                        .id(("runbook-run", index))
                        .flex()
                        .items_center()
                        .gap_1()
                        .px_2()
                        .py(px(2.0))
                        .rounded_md()
                        .border_1()
                        .border_color(chrome.border)
                        .text_size(px(11.0))
                        .cursor_pointer()
                        .hover(|d| d.bg(chrome.tab_hover_bg))
                        .child(Icon::new(IconName::Play).size(px(10.0)))
                        .child(crate::l10n::tr("Run"))
                        .on_click(move |_, window, cx| on_run(&run_code, window, cx)),
                ),
        )
        .child(
            div()
                .p(px(10.0))
                .bg(chrome.panel_bg.opacity(0.5))
                .font_family(mono)
                .text_size(px(12.0))
                .child(code),
        )
}
