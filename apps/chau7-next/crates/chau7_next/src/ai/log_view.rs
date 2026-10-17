//! Log view of AI tool output (`AnsiLogView.swift` in the Swift main
//! panel): the last 250 lines of the Claude and Codex PTY logs, ANSI colors
//! (16, 256, true color), bold, dim, italic, underline and inverse,
//! `[INPUT]` lines in bold, new lines appended and the view kept at the end.
//!
//! The Swift app shows it in its legacy menu bar panel (`MenuBarPanelView`,
//! STB-016, not carried over); Chau7 Next opens it in its own window ("AI
//! Terminal Logs" in the command palette).

use std::time::Duration;

use chau7_next_core::ansi_log::{AnsiStyle, Rgb, parse_line};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, FontStyle, FontWeight, Global, HighlightStyle, Hsla,
    Render, ScrollHandle, SharedString, StyledText, Task, UnderlineStyle, Window, WindowBounds,
    WindowOptions, actions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;

use crate::theme::Chrome;

actions!(
    chau7_ai,
    [
        /// "AI Terminal Logs": the PTY logs of AI sessions.
        ShowAiLogs
    ]
);

#[derive(Default)]
struct LogWindow(Option<AnyWindowHandle>);
impl Global for LogWindow {}

/// Tools with a log, in display order (provider key, label).
const TOOLS: [(&str, &str); 2] = [("claude", "Claude"), ("codex", "Codex")];

pub fn register(cx: &mut App) {
    cx.on_action(|_: &ShowAiLogs, cx| open(cx));
}

pub fn open(cx: &mut App) {
    if let Some(handle) = cx.try_global::<LogWindow>().and_then(|h| h.0)
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        return;
    }
    let bounds = Bounds::centered(None, size(px(760.0), px(520.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(420.0), px(300.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |_, cx| cx.new(AiLogView::new)) {
        Ok((handle, _)) => cx.set_global(LogWindow(Some(handle))),
        Err(err) => log::error!("AI logs window: {err}"),
    }
}

struct AiLogView {
    tool: &'static str,
    scroll: ScrollHandle,
    seen: usize,
    _refresh: Task<()>,
}

impl AiLogView {
    fn new(cx: &mut Context<Self>) -> Self {
        // New lines arrive from the hub's tailers; redraw twice a second.
        let refresh = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(500))
                    .await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        });
        Self {
            tool: TOOLS[0].0,
            scroll: ScrollHandle::new(),
            seen: 0,
            _refresh: refresh,
        }
    }
}

fn hsla((r, g, b): Rgb) -> Hsla {
    gpui::Rgba { r, g, b, a: 1.0 }.into()
}

/// Text and highlights of one line (`AnsiParser.attributes`): inverse
/// swaps colors, dim fades the text, `[INPUT]` lines are bold.
pub fn styled_line(line: &str, base_fg: Hsla, base_bg: Hsla) -> StyledText {
    let spans = parse_line(line);
    let input = line.starts_with("[INPUT]");
    let mut text = String::new();
    let mut highlights = Vec::new();
    for span in spans {
        let start = text.len();
        text.push_str(&span.text);
        let style: AnsiStyle = span.style;
        let mut fg = style.fg.map(hsla).unwrap_or(base_fg);
        let mut bg = style.bg.map(hsla);
        if style.inverse {
            let old = fg;
            fg = bg.unwrap_or(base_bg);
            bg = Some(old);
        }
        if style.dim {
            fg = fg.opacity(0.6);
        }
        highlights.push((
            start..text.len(),
            HighlightStyle {
                color: Some(fg),
                background_color: bg,
                font_weight: (style.bold || input).then_some(FontWeight::BOLD),
                font_style: style.italic.then_some(FontStyle::Italic),
                underline: style.underline.then(|| UnderlineStyle {
                    thickness: px(1.0),
                    color: Some(fg),
                    wavy: false,
                }),
                ..Default::default()
            },
        ));
    }
    if text.is_empty() {
        text.push(' ');
    }
    StyledText::new(SharedString::from(text)).with_highlights(highlights)
}

impl Render for AiLogView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(&crate::l10n::tr("AI Terminal Logs"));
        let chrome = Chrome::panels(cx);
        let lines = crate::history::monitor::terminal_lines(self.tool, cx);
        let ansi = crate::history::monitor::terminal_ansi(cx);
        // Auto-scroll to the end when lines were added.
        if lines.len() != self.seen {
            self.seen = lines.len();
            self.scroll.scroll_to_bottom();
        }
        let tabs = TOOLS.iter().map(|(key, label)| {
            let key: &'static str = key;
            let selected = self.tool == key;
            div()
                .id(SharedString::from(format!("ai-log-{key}")))
                .px_2p5()
                .py_1()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .border_1()
                .border_color(if selected {
                    chrome.accent
                } else {
                    chrome.border
                })
                .bg(if selected {
                    chrome.accent.opacity(0.18)
                } else {
                    chrome.tab_bg
                })
                .child(*label)
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.tool = key;
                    this.seen = 0;
                    cx.notify();
                }))
        });
        let body = if lines.is_empty() {
            div()
                .p_3()
                .text_sm()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr("No logs yet."))
                .into_any_element()
        } else {
            div()
                .id("ai-log-lines")
                .flex_1()
                .min_h_0()
                .overflow_y_scroll()
                .track_scroll(&self.scroll)
                .p_2()
                .font_family("Menlo")
                .text_size(px(11.0))
                .children(lines.iter().map(|line| {
                    if ansi {
                        div().child(styled_line(line, chrome.text, chrome.panel_bg))
                    } else {
                        // Plain text, escape sequences removed.
                        div().text_color(chrome.text).child(SharedString::from(
                            chau7_next_core::escape_sanitizer::sanitize(line),
                        ))
                    }
                }))
                .into_any_element()
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                crate::theme::panel_titlebar(chrome)
                    .child(div().text_sm().child(crate::l10n::tr("AI Terminal Logs"))),
            )
            .child(div().flex().gap_1().p_2().children(tabs))
            .child(body)
    }
}
