//! State tab (`stateView`): application counts, every tab, p50/p95 latency,
//! the highlight tuning controls and the feature flags.

use chau7_next_core::debug_console::Tone;
use gpui::{AnyElement, Context, IntoElement, SharedString, div, prelude::*, px};

use crate::debug::console::DebugConsole;
use crate::debug::{registry, snapshot, ui};
use crate::monitoring_status::MonitoringStatus;
use crate::settings::Settings;
use crate::settings::dangerous_commands::{
    HIGHLIGHT_IDLE_DELAY_RANGE, HIGHLIGHT_MAX_INTERVAL_RANGE,
};
use crate::settings_window;
use crate::theme::Chrome;

impl DebugConsole {
    pub(in crate::debug) fn state_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tabs = snapshot::tabs(cx);
        let monitoring = MonitoringStatus::get(cx);
        let (event_count, claude_event_count) = registry::event_counts(cx);
        let claude_sessions = registry::claude_sessions(cx).len();
        let active = tabs.iter().position(|t| t.selected).unwrap_or(0);

        let application = ui::group("Application", chrome)
            .child(ui::state_row(
                "Monitoring",
                if monitoring.events {
                    "Active"
                } else {
                    "Paused"
                },
                chrome,
            ))
            .child(ui::state_row("Tabs", tabs.len().to_string(), chrome))
            .child(ui::state_row(
                "Active Tab",
                (active + 1).to_string(),
                chrome,
            ))
            .child(ui::state_row(
                "Claude Sessions",
                claude_sessions.to_string(),
                chrome,
            ))
            .child(ui::state_row(
                "Event Count",
                event_count.to_string(),
                chrome,
            ))
            .child(ui::state_row(
                "Claude Event Count",
                claude_event_count.to_string(),
                chrome,
            ));

        let mut tabs_box = ui::group("Tabs", chrome);
        for (index, tab) in tabs.iter().enumerate() {
            let title = tab
                .custom_title
                .clone()
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| tab.title.clone());
            let mut block = div()
                .flex()
                .flex_col()
                .gap_0p5()
                .py_1()
                .when(index > 0, |d| d.border_t_1().border_color(chrome.border))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(
                            div()
                                .flex()
                                .gap_2()
                                .text_xs()
                                .child(
                                    div()
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .child(format!("Tab {}", index + 1)),
                                )
                                .when(tab.selected, |d| {
                                    d.child(
                                        div()
                                            .text_color(ui::tone_color(Tone::Good, chrome))
                                            .child("(active)"),
                                    )
                                }),
                        )
                        // The command state ("idle": no command running), not the tab's
                        // activity that the Health tab counts.
                        .child(ui::mono_line(
                            format!("command: {}", tab.status),
                            chrome.text_muted,
                        )),
                )
                .child(ui::state_row("Title", title, chrome))
                .child(ui::state_row(
                    "App",
                    tab.ai_app.clone().unwrap_or_else(|| "none".into()),
                    chrome,
                ))
                .child(ui::state_row("Directory", tab.cwd.clone(), chrome))
                .child(ui::state_row("Input Lag", tab.input_lag.clone(), chrome))
                .child(ui::state_row("Output Lag", tab.output_lag.clone(), chrome))
                .child(ui::state_row(
                    "Highlight Lag",
                    tab.highlight_lag.clone(),
                    chrome,
                ));
            if tab.is_git_repo {
                block = block.child(ui::state_row(
                    "Git Branch",
                    tab.git_branch.clone().unwrap_or_else(|| "unknown".into()),
                    chrome,
                ));
            }
            tabs_box = tabs_box.child(block);
        }
        if tabs.is_empty() {
            tabs_box = tabs_box.child(ui::caption("No tabs", chrome));
        }

        let mut summary = ui::group("Performance Summary", chrome);
        match tabs.iter().find(|t| t.selected) {
            Some(tab) => {
                summary = summary
                    .child(ui::state_row(
                        "Input p50/p95",
                        tab.input_percentiles.clone(),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "Output p50/p95",
                        tab.output_percentiles.clone(),
                        chrome,
                    ))
                    .child(ui::state_row(
                        "Highlight p50/p95",
                        tab.highlight_percentiles.clone(),
                        chrome,
                    ));
            }
            None => summary = summary.child(ui::caption("n/a", chrome)),
        }

        let danger = Settings::get(cx).dangerous_commands.clone();
        let performance = ui::group("Performance", chrome)
            .child(
                ui::switch(
                    "highlight-low-power",
                    "Low-Power Highlighting",
                    danger.highlight_low_power,
                    chrome,
                )
                .on_click(move |_, _, cx| {
                    settings_window::update(cx, |s| {
                        s.dangerous_commands.highlight_low_power = !danger.highlight_low_power
                    })
                }),
            )
            .child(stepper(
                "highlight-idle",
                "Highlight Idle Delay (ms)",
                danger.highlight_idle_delay_ms,
                HIGHLIGHT_IDLE_DELAY_RANGE,
                50,
                |s, v| s.dangerous_commands.highlight_idle_delay_ms = v,
                chrome,
            ))
            .child(stepper(
                "highlight-max",
                "Highlight Max Interval (ms)",
                danger.highlight_max_interval_ms,
                HIGHLIGHT_MAX_INTERVAL_RANGE,
                250,
                |s, v| s.dangerous_commands.highlight_max_interval_ms = v,
                chrome,
            ));

        let mut flags = ui::group("Feature Flags", chrome);
        let values = snapshot::feature_flags(cx);
        for (label, key) in [
            ("Snippets", "snippets"),
            ("Repo Snippets", "repoSnippets"),
            ("Broadcast Mode", "broadcastMode"),
            ("Clipboard History", "clipboardHistory"),
            ("Bookmarks", "bookmarks"),
        ] {
            flags = flags.child(flag_row(
                label,
                values.get(key).copied().unwrap_or(false),
                chrome,
            ));
        }

        ui::page(
            "state-page",
            div()
                .flex()
                .flex_col()
                .gap_3()
                .child(application)
                .child(tabs_box)
                .child(summary)
                .child(performance)
                .child(flags),
        )
        .into_any_element()
    }
}

fn flag_row(label: &'static str, enabled: bool, chrome: Chrome) -> gpui::Div {
    let tone = if enabled { Tone::Good } else { Tone::Muted };
    div()
        .flex()
        .items_center()
        .justify_between()
        .text_xs()
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .size(px(8.0))
                        .rounded_full()
                        .bg(ui::tone_color(tone, chrome)),
                )
                .child(label),
        )
        .child(ui::mono_line(
            if enabled { "ON" } else { "OFF" },
            ui::tone_color(tone, chrome),
        ))
}

/// `performanceSettingRow`: a label, the value and - / + buttons.
fn stepper(
    id: &'static str,
    label: &'static str,
    value: u32,
    (min, max): (u32, u32),
    step: u32,
    apply: fn(&mut Settings, u32),
    chrome: Chrome,
) -> gpui::Div {
    let button = |suffix: &'static str, text: &'static str, next: u32| {
        ui::button(SharedString::from(format!("{id}-{suffix}")), text, chrome)
            .on_click(move |_, _, cx| settings_window::update(cx, |s| apply(s, next)))
    };
    div()
        .flex()
        .items_center()
        .justify_between()
        .text_xs()
        .child(label)
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(button(
                    "dec",
                    "\u{2212}",
                    value.saturating_sub(step).max(min),
                ))
                .child(
                    div()
                        .min_w(px(48.0))
                        .text_center()
                        .font_family("Menlo")
                        .child(value.to_string()),
                )
                .child(button("inc", "+", (value + step).min(max))),
        )
}
