//! The Help window (`HelpWindowController`, `HelpView`): a topic list with
//! a search box on the left, one topic on the right, "Related Topics"
//! buttons at the end. One window is reused; opening it again selects the
//! asked topic.

use chau7_next_core::help::{
    self, Block, HelpTopic, Span, WINDOW_TITLE, filter_topics, initial_topic, parse_blocks,
    parse_inline,
};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, Entity, FontWeight, HighlightStyle, IntoElement, Render,
    ScrollHandle, SharedString, StyledText, Window, WindowBounds, WindowOptions, div, prelude::*,
    px, size,
};
use gpui_kit::component::TitleBar;
use gpui_kit::component::input::{Input, InputState};

use super::ViewsState;
use crate::theme::Chrome;

pub(crate) struct HelpHandle {
    window: AnyWindowHandle,
    view: Entity<HelpView>,
}

/// Open the Help window, on a topic when given (Help > Chau7 Help,
/// Technology, Licenses & Acknowledgments).
pub fn open_help(topic: Option<&str>, cx: &mut App) {
    let existing = cx
        .global::<ViewsState>()
        .help
        .as_ref()
        .map(|h| (h.window, h.view.clone()));
    if let Some((window, view)) = existing {
        let topic = initial_topic(topic).id;
        let alive = window
            .update(cx, |_, window, cx| {
                window.activate_window();
                view.update(cx, |view, cx| view.select(topic, cx));
            })
            .is_ok();
        if alive {
            return;
        }
        cx.global_mut::<ViewsState>().help = None;
    }
    let bounds = Bounds::centered(None, size(px(860.0), px(620.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(640.0), px(420.0))),
        ..TitleBar::window_options()
    };
    let start = initial_topic(topic).id;
    match gpui_kit::open_window(options, cx, move |window, cx| {
        cx.new(|cx| HelpView::new(start, window, cx))
    }) {
        Ok((window, view)) => {
            cx.global_mut::<ViewsState>().help = Some(HelpHandle { window, view });
            cx.on_window_closed(|cx, _| {
                let dead = cx
                    .global::<ViewsState>()
                    .help
                    .as_ref()
                    .is_some_and(|h| !cx.windows().contains(&h.window));
                if dead {
                    cx.global_mut::<ViewsState>().help = None;
                }
            })
            .detach();
        }
        Err(err) => log::error!("help window: {err}"),
    }
}

pub(crate) struct HelpView {
    selected: &'static str,
    search: Entity<InputState>,
    scroll: ScrollHandle,
}

impl HelpView {
    fn new(selected: &'static str, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search =
            cx.new(|cx| InputState::new(window, cx).placeholder(crate::l10n::tr("Search help")));
        cx.observe(&search, |_, _, cx| cx.notify()).detach();
        Self {
            selected,
            search,
            scroll: ScrollHandle::new(),
        }
    }

    fn select(&mut self, id: &str, cx: &mut Context<Self>) {
        self.selected = initial_topic(Some(id)).id;
        self.scroll.set_offset(gpui::point(px(0.0), px(0.0)));
        cx.notify();
    }
}

/// Text with bold and code spans.
fn inline(text: &str, chrome: Chrome) -> StyledText {
    let mut plain = String::new();
    let mut highlights = Vec::new();
    for span in parse_inline(text) {
        let start = plain.len();
        match span {
            Span::Text(t) => plain.push_str(&t),
            Span::Bold(t) => {
                plain.push_str(&t);
                highlights.push((
                    start..plain.len(),
                    HighlightStyle {
                        font_weight: Some(FontWeight::BOLD),
                        ..Default::default()
                    },
                ));
            }
            Span::Code(t) => {
                plain.push_str(&t);
                highlights.push((
                    start..plain.len(),
                    HighlightStyle {
                        color: Some(chrome.accent),
                        background_color: Some(chrome.tab_bg),
                        ..Default::default()
                    },
                ));
            }
        }
    }
    StyledText::new(plain).with_highlights(highlights)
}

fn block(b: &Block, chrome: Chrome) -> gpui::AnyElement {
    match b {
        Block::Heading { level, text } => {
            let size = match level {
                1 => px(24.0),
                2 => px(18.0),
                _ => px(15.0),
            };
            div()
                .pt_2()
                .text_size(size)
                .font_weight(FontWeight::BOLD)
                .child(text.clone())
                .into_any_element()
        }
        Block::Paragraph(text) => div()
            .text_sm()
            .child(inline(text, chrome))
            .into_any_element(),
        Block::Bullets(items) => div()
            .flex()
            .flex_col()
            .gap_1()
            .children(items.iter().map(|item| {
                div()
                    .flex()
                    .gap_2()
                    .pl(px(12.0 * item.indent as f32))
                    .text_sm()
                    .child(div().text_color(chrome.text_muted).child("\u{2022}"))
                    .child(div().flex_1().child(inline(&item.text, chrome)))
            }))
            .into_any_element(),
        Block::Code(code) => div()
            .p_2()
            .rounded_md()
            .bg(chrome.tab_bg)
            .border_1()
            .border_color(chrome.border)
            .font_family("Menlo")
            .text_xs()
            .child(code.clone())
            .into_any_element(),
        Block::Table(table) => {
            let row = |cells: &[String], header: bool| {
                div()
                    .flex()
                    .gap_3()
                    .py_1()
                    .border_b_1()
                    .border_color(chrome.border)
                    .children(cells.iter().enumerate().map(|(i, cell)| {
                        let base = div().flex_1().min_w_0().text_sm().child(cell.clone());
                        if header {
                            base.font_weight(FontWeight::SEMIBOLD)
                        } else if i == 1 {
                            base.font_family("Menlo").text_xs()
                        } else {
                            base
                        }
                    }))
            };
            div()
                .flex()
                .flex_col()
                .child(row(&table.header, true))
                .children(table.rows.iter().map(|r| row(r, false)))
                .into_any_element()
        }
    }
}

impl Render for HelpView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        window.set_window_title(&crate::l10n::tr(WINDOW_TITLE));
        let query = self.search.read(cx).value().to_string();
        let topics = filter_topics(&query);
        let current: &'static HelpTopic = help::topic(self.selected).unwrap_or(&help::TOPICS[0]);

        let list = topics.iter().map(|t| {
            let id = t.id;
            let on = t.id == current.id;
            div()
                .id(SharedString::from(format!("help-topic-{id}")))
                .px_2p5()
                .py_1p5()
                .rounded_md()
                .text_sm()
                .cursor_pointer()
                .bg(if on {
                    chrome.accent.opacity(0.18)
                } else {
                    chrome.panel_bg
                })
                .hover(|d| d.bg(chrome.tab_hover_bg))
                .child(t.title)
                .on_click(cx.listener(move |this, _, _, cx| this.select(id, cx)))
        });

        let blocks: Vec<_> = parse_blocks(current.content)
            .iter()
            .map(|b| block(b, chrome))
            .collect();
        let related = current
            .related
            .iter()
            .filter_map(|id| help::topic(id))
            .map(|t| {
                let id = t.id;
                crate::debug::ui::button(
                    SharedString::from(format!("help-rel-{id}")),
                    t.title,
                    chrome,
                )
                .on_click(cx.listener(move |this, _, _, cx| this.select(id, cx)))
            });

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                crate::theme::panel_titlebar(chrome)
                    .child(div().text_sm().child(crate::l10n::tr(WINDOW_TITLE))),
            )
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .child(
                        div()
                            .w(px(220.0))
                            .flex_shrink_0()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .p_2()
                            .border_r_1()
                            .border_color(chrome.border)
                            .child(Input::new(&self.search))
                            .child(div().flex().flex_col().gap_0p5().children(list))
                            .when(topics.is_empty(), |d| {
                                d.child(
                                    div()
                                        .p_2()
                                        .text_xs()
                                        .text_color(chrome.text_muted)
                                        .child(crate::l10n::tr("No topics match.")),
                                )
                            }),
                    )
                    .child(
                        div()
                            .id("help-content")
                            .flex_1()
                            .min_w_0()
                            .overflow_y_scroll()
                            .track_scroll(&self.scroll)
                            .p_5()
                            .flex()
                            .flex_col()
                            .gap_3()
                            .children(blocks)
                            .when(!current.related.is_empty(), |d| {
                                d.child(
                                    div()
                                        .pt_3()
                                        .flex()
                                        .flex_col()
                                        .gap_2()
                                        .child(
                                            div()
                                                .text_sm()
                                                .font_weight(FontWeight::SEMIBOLD)
                                                .child(crate::l10n::tr("Related Topics")),
                                        )
                                        .child(div().flex().flex_wrap().gap_2().children(related)),
                                )
                            }),
                    ),
            )
    }
}
