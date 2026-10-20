//! Markdown runbook view (`SplitPanes/MarkdownRunbookView.swift`): headings,
//! text with inline markdown, and fenced code blocks with their language
//! tag and a Run button that types the block into the tab's first terminal.

use std::collections::HashMap;
use std::rc::Rc;

#[derive(Clone, Copy)]
pub(super) enum BlockStatus {
    Running,
    Succeeded,
    Failed,
}

use chau7_next_core::editor::markdown::{MarkdownSection, parse_inline};
use gpui::{
    App, ElementId, FontStyle, FontWeight, HighlightStyle, Hsla, InteractiveText, SharedString,
    StrikethroughStyle, StyledText, UnderlineStyle, Window, div, prelude::*, px,
};
use gpui_kit::component::{Icon, IconName};

use crate::theme::Chrome;

type RunHandler = Rc<dyn Fn(&(usize, String), &mut Window, &mut App)>;

pub(super) struct Blocks<'a> {
    pub diagrams: &'a HashMap<usize, gpui::Entity<super::mermaid::MermaidView>>,
    pub states: &'a HashMap<(usize, String), BlockStatus>,
}

pub(super) fn render(
    sections: Vec<MarkdownSection>,
    blocks: Blocks<'_>,
    chrome: Chrome,
    background: Hsla,
    mono: SharedString,
    on_run: impl Fn(&(usize, String), &mut Window, &mut App) + 'static,
    on_toggle: impl Fn(&usize, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let on_run: RunHandler = Rc::new(on_run);
    let on_toggle = Rc::new(on_toggle);
    let mut column = div().w_full().min_w_0().flex().flex_col().gap_3().p_4();
    for (index, section) in sections.into_iter().enumerate() {
        if let Some(diagram) = blocks.diagrams.get(&index) {
            column = column.child(diagram.clone());
            continue;
        }
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
            MarkdownSection::Checkbox {
                checked,
                text,
                line,
            } => {
                let toggle = on_toggle.clone();
                div()
                    .flex()
                    .gap_2()
                    .child(
                        div()
                            .id(("runbook-checkbox", index))
                            .cursor_pointer()
                            .child(if checked { "☑" } else { "☐" })
                            .on_click(move |_, window, cx| toggle(&line, window, cx)),
                    )
                    .child(inline_text(index, &text, chrome))
                    .into_any_element()
            }
            MarkdownSection::Bullet(text) => div()
                .flex()
                .gap_2()
                .child("•")
                .child(inline_text(index, &text, chrome))
                .into_any_element(),
            MarkdownSection::Numbered { number, text } => div()
                .flex()
                .gap_2()
                .child(format!("{number}."))
                .child(inline_text(index, &text, chrome))
                .into_any_element(),
            MarkdownSection::Rule => div()
                .w_full()
                .border_b_1()
                .border_color(chrome.border)
                .into_any_element(),
            MarkdownSection::Text(text) => inline_text(index, &text, chrome).into_any_element(),
            MarkdownSection::TerminalSelection(runs) => {
                terminal_selection(index, runs, chrome, mono.clone()).into_any_element()
            }
            MarkdownSection::CodeBlock { language, code } => {
                let status = blocks.states.get(&(index, code.clone())).copied();
                code_block(
                    index,
                    language,
                    code,
                    status,
                    chrome,
                    mono.clone(),
                    on_run.clone(),
                )
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
    inline_runs(index, parse_inline(text), chrome, None)
}

fn terminal_selection(
    index: usize,
    runs: Vec<chau7_next_core::editor::markdown::InlineRun>,
    chrome: Chrome,
    mono: SharedString,
) -> impl IntoElement {
    inline_runs(index, runs, chrome, Some(mono))
}

fn inline_runs(
    index: usize,
    runs: Vec<chau7_next_core::editor::markdown::InlineRun>,
    chrome: Chrome,
    mono: Option<SharedString>,
) -> impl IntoElement {
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
        if run.underline {
            let color = run
                .foreground
                .map(|value| gpui::rgb(rgb24(value)).into())
                .unwrap_or(chrome.text);
            style.underline = Some(UnderlineStyle {
                thickness: px(1.0),
                color: Some(color),
                wavy: false,
            });
        }
        if let Some(color) = run.foreground {
            style.color = Some(gpui::rgb(rgb24(color)).into());
        }
        if let Some(color) = run.background {
            style.background_color = Some(gpui::rgb(rgb24(color)).into());
        }
        if let Some(url) = &run.link {
            if run.foreground.is_none() {
                style.color = Some(chrome.accent);
            }
            if !run.underline {
                style.underline = Some(UnderlineStyle {
                    thickness: px(1.0),
                    color: Some(
                        run.foreground
                            .map(|value| gpui::rgb(rgb24(value)).into())
                            .unwrap_or(chrome.accent),
                    ),
                    wavy: false,
                });
            }
            links.push((range.clone(), url.clone()));
        }
        if style != HighlightStyle::default() {
            highlights.push((range, style));
        }
    }
    let ranges: Vec<_> = links.iter().map(|(r, _)| r.clone()).collect();
    let styled = StyledText::new(full).with_highlights(highlights);
    let text = InteractiveText::new(
        ElementId::Name(format!("runbook-text-{index}").into()),
        styled,
    )
    .on_click(ranges, move |i, _, cx| {
        if let Some((_, url)) = links.get(i)
            && chau7_next_core::terminal_clipboard::is_safe_link(url)
        {
            cx.open_url(url);
        }
    });
    let container = div().w_full().child(text);
    if let Some(mono) = mono {
        return container
            .id(("runbook-inline-scroll", index))
            .font_family(mono)
            .whitespace_nowrap()
            .overflow_x_scroll()
            .into_any_element();
    }
    container.into_any_element()
}

fn rgb24([red, green, blue]: [u8; 3]) -> u32 {
    (u32::from(red) << 16) | (u32::from(green) << 8) | u32::from(blue)
}

fn code_block(
    index: usize,
    language: Option<String>,
    code: String,
    status: Option<BlockStatus>,
    chrome: Chrome,
    mono: SharedString,
    on_run: RunHandler,
) -> impl IntoElement {
    let executable = chau7_next_core::editor::markdown::is_shell_language(language.as_deref());
    let run_code = (index, code.clone());
    let border = match status {
        Some(BlockStatus::Running) => gpui::rgb(0xff9500).into(),
        Some(BlockStatus::Succeeded) => gpui::rgb(0x34c759).into(),
        Some(BlockStatus::Failed) => chrome.danger,
        None => chrome.border,
    };
    div()
        .flex()
        .flex_col()
        .rounded_md()
        .overflow_hidden()
        .border_1()
        .border_color(border)
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
                .when_some(status, |d, status| {
                    d.child(match status {
                        BlockStatus::Running => "Running",
                        BlockStatus::Succeeded => "Succeeded",
                        BlockStatus::Failed => "Failed",
                    })
                })
                .when(!executable, |d| d.child(crate::l10n::tr("Display only")))
                .when(executable, |d| {
                    d.child(
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
                    )
                }),
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
