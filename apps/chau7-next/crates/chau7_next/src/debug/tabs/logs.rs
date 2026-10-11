//! Logs tab (`logsView`): the last 200 lines of the log, newest first, with a
//! text filter, level chips and category chips.

use chau7_next_core::debug_console::Tone;
use chau7_next_core::logging::{LogCategory, LogLevel};
use gpui::{AnyElement, Context, IntoElement, SharedString, div, prelude::*};
use gpui_kit::component::input::Input;

use crate::debug::console::DebugConsole;
use crate::debug::ui;
use crate::logging;
use crate::theme::Chrome;

/// Lines read (`suffix(200)`).
const LOG_LINES: usize = 200;

fn level_tone(level: LogLevel) -> Tone {
    match level {
        LogLevel::Error => Tone::Bad,
        LogLevel::Warn => Tone::Warn,
        LogLevel::Debug => Tone::Warn,
        LogLevel::Trace => Tone::Muted,
        LogLevel::Info => Tone::Info,
    }
}

impl DebugConsole {
    /// `loadLogs`: the newest lines first.
    pub(in crate::debug) fn load_logs(&mut self) {
        let mut lines = logging::recent_lines(LOG_LINES);
        if lines.is_empty() && logging::file_path().is_none() {
            self.log_lines = vec!["(Unable to read log file)".to_string()];
            return;
        }
        lines.reverse();
        self.log_lines = lines;
    }

    pub(in crate::debug) fn logs_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let filtered: Vec<String> = self
            .log_filter
            .apply(&self.log_lines)
            .into_iter()
            .cloned()
            .collect();

        let top = div()
            .flex()
            .items_center()
            .gap_2()
            .p_2()
            .border_b_1()
            .border_color(chrome.border)
            .child(div().flex_1().child(Input::new(&self.log_input)))
            .child(
                ui::button("logs-refresh", "Refresh", chrome).on_click(cx.listener(
                    |this, _, _, cx| {
                        this.load_logs();
                        cx.notify();
                    },
                )),
            )
            .child(
                ui::button("logs-open", "Open File", chrome).on_click(|_, _, cx| {
                    if let Some(path) = logging::file_path() {
                        logging::flush();
                        cx.open_url(&format!("file://{}", path.display()));
                    }
                }),
            );

        let mut levels = div()
            .flex()
            .items_center()
            .flex_wrap()
            .gap_1()
            .px_2()
            .py_1();
        levels = levels.child(ui::caption("Level:", chrome));
        for level in LogLevel::ALL {
            let active = self.log_filter.levels.contains(&level);
            levels = levels.child(
                ui::chip(
                    SharedString::from(format!("level-{}", level.tag())),
                    level.tag(),
                    active,
                    ui::tone_color(level_tone(level), chrome),
                    chrome,
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.log_filter.toggle_level(level);
                    cx.notify();
                })),
            );
        }
        levels = levels
            .child(div().flex_1())
            .child(
                ui::button("levels-all", "All", chrome).on_click(cx.listener(|this, _, _, cx| {
                    this.log_filter.all_levels();
                    cx.notify();
                })),
            )
            .child(
                ui::button("levels-errors", "Errors", chrome).on_click(cx.listener(
                    |this, _, _, cx| {
                        this.log_filter.errors_only();
                        cx.notify();
                    },
                )),
            );

        let mut categories = div()
            .flex()
            .items_center()
            .flex_wrap()
            .gap_1()
            .px_2()
            .py_1();
        categories = categories.child(ui::caption("Category:", chrome));
        for category in LogCategory::ALL {
            let active = self.log_filter.categories.contains(&category);
            categories = categories.child(
                ui::chip(
                    SharedString::from(format!("category-{}", category.label())),
                    format!("{} {}", category.emoji(), category.label()),
                    active,
                    chrome.accent,
                    chrome,
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.log_filter.toggle_category(category);
                    cx.notify();
                })),
            );
        }

        let mut list = div().flex().flex_col().p_2();
        for (i, line) in filtered.iter().enumerate() {
            list = list.child(
                div()
                    .id(SharedString::from(format!("log-line-{i}")))
                    .text_xs()
                    .font_family("Menlo")
                    .text_color(chrome.text)
                    .child(line.clone()),
            );
        }

        let memory = logging::current_memory_mb()
            .map(|m| format!("Memory: {m:.1} MB"))
            .unwrap_or_default();
        let status = div()
            .flex()
            .items_center()
            .justify_between()
            .px_2()
            .py_1()
            .border_t_1()
            .border_color(chrome.border)
            .bg(chrome.tab_bg.opacity(0.5))
            .child(ui::caption(
                format!("{} / {} entries", filtered.len(), self.log_lines.len()),
                chrome,
            ))
            .child(ui::caption(memory, chrome));

        div()
            .size_full()
            .flex()
            .flex_col()
            .child(top)
            .child(levels)
            .child(categories)
            .child(
                div()
                    .id("logs-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .border_t_1()
                    .border_color(chrome.border)
                    .child(list),
            )
            .child(status)
            .into_any_element()
    }
}
