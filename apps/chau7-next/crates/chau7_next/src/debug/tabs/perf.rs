//! Perf tab (`performanceView`): per-feature totals of the last 10 s and
//! 60 s and the recent events of the feature profiler.

use std::collections::HashMap;

use chau7_next_core::debug_console::Tone;
use chau7_next_core::feature_profiler::{self, Feature, Totals};
use chrono::{Local, TimeZone};
use gpui::{AnyElement, Context, IntoElement, SharedString, div, prelude::*};

use crate::debug::console::DebugConsole;
use crate::debug::ui;
use crate::theme::Chrome;

/// "Slow only" hides events under this many ms (`perfSlowThresholdMs`).
const SLOW_THRESHOLD_MS: i64 = 8;
/// Events shown (`prefix(160)`).
const MAX_EVENTS: usize = 160;

fn bytes_text(bytes: usize) -> String {
    if bytes == 0 {
        "-".into()
    } else {
        chau7_next_core::l10n::formatters::file_size(chau7_next_core::l10n::current(), bytes as u64)
    }
}

fn summary_section(
    title: &'static str,
    totals: &HashMap<Feature, Totals>,
    chrome: Chrome,
) -> gpui::Div {
    let mut ordered: Vec<(&Feature, &Totals)> =
        totals.iter().filter(|(_, t)| t.count > 0).collect();
    ordered.sort_by(|a, b| b.1.total_ms.total_cmp(&a.1.total_ms));
    let mut group = ui::group(title, chrome);
    if ordered.is_empty() {
        return group.child(ui::caption("No performance events recorded yet.", chrome));
    }
    let weights = [2.5, 1.3, 1.3, 1.3, 1.1, 1.6];
    let head = ["Feature", "Total", "Avg", "Max", "Count", "Bytes"]
        .into_iter()
        .map(|h| (SharedString::from(h), None))
        .collect();
    group = group.child(ui::table_row(head, &weights, true, chrome));
    for (feature, stats) in ordered {
        group = group.child(ui::table_row(
            vec![
                (SharedString::from(feature.label()), None),
                (format!("{}ms", stats.total_ms.round() as i64).into(), None),
                (
                    format!("{}ms", stats.average_ms().round() as i64).into(),
                    None,
                ),
                (format!("{}ms", stats.max_ms.round() as i64).into(), None),
                (stats.count.to_string().into(), None),
                (bytes_text(stats.total_bytes).into(), None),
            ],
            &weights,
            false,
            chrome,
        ));
    }
    group
}

impl DebugConsole {
    pub(in crate::debug) fn perf_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let snapshot = feature_profiler::snapshot();
        let slow_only = self.perf_slow_only;
        let header = div()
            .flex()
            .items_center()
            .justify_between()
            .p_2()
            .border_b_1()
            .border_color(chrome.border)
            .child(
                ui::switch("perf-slow", "Slow only", slow_only, chrome).on_click(cx.listener(
                    |this, _, _, cx| {
                        this.perf_slow_only = !this.perf_slow_only;
                        cx.notify();
                    },
                )),
            )
            .child(ui::mono_line(
                format!("Updated {}", Local::now().format("%H:%M:%S%.3f")),
                chrome.text_muted,
            ));

        let events: Vec<_> = snapshot
            .recent
            .iter()
            .filter(|e| !slow_only || e.duration_ms >= SLOW_THRESHOLD_MS)
            .take(MAX_EVENTS)
            .collect();
        let mut recent = ui::group("Recent Events", chrome);
        if events.is_empty() {
            recent = recent.child(ui::caption("No performance events recorded yet.", chrome));
        }
        for event in events {
            let time = Local
                .timestamp_opt(event.second, 0)
                .single()
                .map(|t| t.format("%H:%M:%S").to_string())
                .unwrap_or_default();
            recent = recent.child(
                div()
                    .flex()
                    .flex_col()
                    .px_2()
                    .py_0p5()
                    .rounded_sm()
                    .bg(chrome.tab_bg.opacity(0.5))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .flex()
                                    .gap_2()
                                    .child(
                                        div()
                                            .text_xs()
                                            .font_family("Menlo")
                                            .font_weight(gpui::FontWeight::SEMIBOLD)
                                            .text_color(ui::tone_color(Tone::Info, chrome))
                                            .child(event.feature.label()),
                                    )
                                    .child(ui::mono_line(time, chrome.text_muted)),
                            )
                            .child(
                                div()
                                    .flex()
                                    .gap_2()
                                    .child(
                                        div()
                                            .text_xs()
                                            .font_family("Menlo")
                                            .font_weight(gpui::FontWeight::SEMIBOLD)
                                            .child(format!("{}ms", event.duration_ms)),
                                    )
                                    .when(event.bytes > 0, |d| {
                                        d.child(ui::mono_line(
                                            bytes_text(event.bytes),
                                            chrome.text_muted,
                                        ))
                                    }),
                            ),
                    )
                    .when_some(
                        event.metadata.clone().filter(|m| !m.is_empty()),
                        |d, meta| d.child(ui::caption(meta, chrome)),
                    ),
            );
        }

        let body = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(summary_section("Last 10s", &snapshot.last_10s, chrome))
            .child(summary_section("Last 60s", &snapshot.last_60s, chrome))
            .child(recent);
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(header)
            .child(ui::page("perf-page", body).flex_1().min_h_0())
            .into_any_element()
    }
}
