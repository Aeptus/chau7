//! Analytics tab (`analyticsView`): API calls through the proxy, AI runs and
//! repositories. The data comes from the owners of the stores through
//! `debug::set_analytics_source`.

use chau7_next_core::debug_console::{AnalyticsData, Tone, relative_time, success_tone};
use gpui::{AnyElement, Context, IntoElement, SharedString, div, prelude::*};

use super::tab_label;
use crate::debug::console::{AnalyticsMode, DebugConsole};
use crate::debug::{registry, snapshot, ui};
use crate::l10n::run_cost_label;
use crate::theme::Chrome;
use chau7_next_core::l10n::numbers;

fn capitalized(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// A line with a bold name and several right-aligned details.
fn detail_row(
    name: impl Into<SharedString>,
    details: Vec<(String, Option<Tone>)>,
    chrome: Chrome,
) -> gpui::Div {
    let mut right = div().flex().items_center().gap_3();
    for (text, tone) in details {
        right = right.child(
            div()
                .text_xs()
                .font_family("Menlo")
                .text_color(tone.map_or(chrome.text_muted, |t| ui::tone_color(t, chrome)))
                .child(text),
        );
    }
    div()
        .flex()
        .items_center()
        .justify_between()
        .gap_2()
        .child(
            div()
                .min_w_0()
                .overflow_hidden()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(name.into()),
        )
        .child(right)
}

fn proxy_page(data: &AnalyticsData, chrome: Chrome) -> gpui::Div {
    let mut summary = ui::group("Proxy API Summary", chrome);
    if data.proxy_stats.call_count == 0 {
        summary = summary.child(ui::caption("No proxy-captured API calls yet.", chrome));
    } else {
        let s = &data.proxy_stats;
        summary = summary.child(
            div()
                .flex()
                .justify_between()
                .text_xs()
                .child(format!(
                    "{}: {}",
                    crate::l10n::tr("Calls"),
                    numbers::integer(s.call_count)
                ))
                .child(format!(
                    "{}: {}",
                    crate::l10n::tr("Tokens"),
                    numbers::integer(s.total_tokens)
                ))
                .child(div().font_weight(gpui::FontWeight::BOLD).child(format!(
                    "{}: {}",
                    crate::l10n::tr("Cost"),
                    numbers::cost_precise(s.total_cost)
                )))
                .child(
                    div()
                        .text_color(chrome.text_muted)
                        .child(format!("Avg latency: {:.0}ms", s.average_latency_ms)),
                ),
        );
    }

    let mut providers = ui::group("Calls by Provider", chrome);
    if data.proxy_providers.is_empty() {
        providers = providers.child(ui::caption("No provider data yet.", chrome));
    }
    for stat in &data.proxy_providers {
        providers = providers.child(detail_row(
            capitalized(&stat.provider),
            vec![
                (
                    crate::l10n::count("task.calls", "%d calls", stat.call_count),
                    None,
                ),
                (
                    crate::l10n::count("task.tokens", "%d tokens", stat.total_tokens),
                    None,
                ),
                (numbers::cost_precise(stat.total_cost), Some(Tone::Info)),
            ],
            chrome,
        ));
    }

    let mut daily = ui::group("Daily Proxy Cost (Last 7 Days)", chrome);
    if data.proxy_daily.is_empty() {
        daily = daily.child(ui::caption("No daily proxy data yet.", chrome));
    }
    for day in &data.proxy_daily {
        daily = daily.child(detail_row(
            day.date.clone(),
            vec![
                (
                    crate::l10n::count("task.calls", "%d calls", day.call_count),
                    None,
                ),
                (
                    crate::l10n::count("task.tokens", "%d tokens", day.total_tokens),
                    None,
                ),
                (numbers::cost_precise(day.total_cost), Some(Tone::Info)),
            ],
            chrome,
        ));
    }

    let mut recent = ui::group("Recent Proxy Calls", chrome);
    if data.proxy_recent.is_empty() {
        recent = recent.child(ui::caption("No recent proxy calls recorded.", chrome));
    }
    for call in data.proxy_recent.iter().take(15) {
        recent = recent.child(detail_row(
            format!("{}  {}", call.provider, call.model),
            vec![
                (
                    crate::l10n::count("task.tokens", "%d tokens", call.total_tokens),
                    None,
                ),
                (call.formatted_cost.clone(), Some(Tone::Info)),
                (call.formatted_latency.clone(), None),
            ],
            chrome,
        ));
    }
    div()
        .flex()
        .flex_col()
        .gap_3()
        .child(summary)
        .child(providers)
        .child(daily)
        .child(recent)
}

fn runs_page(
    data: &AnalyticsData,
    tabs: &[crate::workspace::TabDebugInfo],
    chrome: Chrome,
    rebuild: Option<gpui::AnyElement>,
) -> gpui::Div {
    let mut providers = ui::group("Run Telemetry by Provider", chrome);
    if data.run_providers.is_empty() {
        providers = providers.child(ui::caption("No AI run telemetry yet.", chrome));
    }
    for stat in &data.run_providers {
        providers = providers.child(detail_row(
            stat.provider.clone(),
            vec![
                (
                    crate::l10n::count("explorer.runs.count", "%d runs", stat.run_count),
                    None,
                ),
                (
                    format!("{} billable-ish tokens", stat.total_billable_tokens()),
                    None,
                ),
                (
                    run_cost_label(
                        stat.total_cost_usd,
                        stat.priced_run_count,
                        stat.missing_cost_run_count,
                    ),
                    Some(if stat.priced_run_count > 0 {
                        Tone::Info
                    } else {
                        Tone::Muted
                    }),
                ),
            ],
            chrome,
        ));
    }

    let mut by_tab = ui::group("Run Tokens by Tab", chrome);
    if data.run_tabs.is_empty() {
        by_tab = by_tab.child(ui::caption("No per-tab run data yet.", chrome));
    }
    for stat in data.run_tabs.iter().take(20) {
        let label = tab_label(
            &stat.tab_id,
            tabs,
            stat.last_provider.as_deref(),
            stat.last_location_path.as_deref(),
        );
        by_tab = by_tab.child(detail_row(
            label,
            vec![
                (format!("billable: {}", stat.total_billable_tokens()), None),
                (
                    run_cost_label(
                        stat.total_cost_usd,
                        stat.priced_run_count,
                        stat.missing_cost_run_count,
                    ),
                    Some(if stat.priced_run_count > 0 {
                        Tone::Info
                    } else {
                        Tone::Muted
                    }),
                ),
            ],
            chrome,
        ));
    }

    let mut coverage = ui::group("Run Cost Coverage (Last 7 Days)", chrome);
    if data.run_daily.is_empty() {
        coverage = coverage.child(ui::caption("No daily run data yet.", chrome));
    }
    for day in &data.run_daily {
        coverage = coverage.child(detail_row(
            day.date.clone(),
            vec![
                (format!("{} tokens", day.tokens), None),
                (
                    run_cost_label(
                        day.cost,
                        day.priced_run_count,
                        (day.total_run_count - day.priced_run_count).max(0),
                    ),
                    Some(if day.priced_run_count > 0 {
                        Tone::Info
                    } else {
                        Tone::Muted
                    }),
                ),
            ],
            chrome,
        ));
    }

    let total_tokens: i64 = data
        .run_providers
        .iter()
        .map(|p| p.total_billable_tokens())
        .sum();
    let priced: i64 = data.run_providers.iter().map(|p| p.priced_run_count).sum();
    let missing: i64 = data
        .run_providers
        .iter()
        .map(|p| p.missing_cost_run_count)
        .sum();
    let cost: f64 = data.run_providers.iter().map(|p| p.total_cost_usd).sum();
    let summary = ui::group("Run Summary", chrome).child(
        div()
            .flex()
            .justify_between()
            .text_xs()
            .child(format!("Runs: {}", data.run_count))
            .child(format!("Billable-ish tokens: {total_tokens}"))
            .child(
                div()
                    .font_weight(gpui::FontWeight::BOLD)
                    .child(run_cost_label(cost, priced, missing)),
            ),
    );

    let mut page = div()
        .flex()
        .flex_col()
        .gap_3()
        .child(providers)
        .child(by_tab)
        .child(coverage)
        .child(summary);
    if let Some(button) = rebuild {
        page = page.child(div().flex().justify_end().child(button));
    }
    page
}

fn repos_page(data: &AnalyticsData, chrome: Chrome) -> gpui::Div {
    if data.repos.is_empty() {
        return div().child(ui::caption("No repositories tracked yet.", chrome));
    }
    let mut overview = ui::group("Repository Overview", chrome);
    for repo in &data.repos {
        let mut stats = div().flex().items_center().gap_3().text_xs();
        if repo.total_commands > 0 {
            stats = stats
                .child(
                    div()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::count(
                            "explorer.sessions.cmds",
                            "%d cmds",
                            repo.total_commands,
                        )),
                )
                .child(
                    div()
                        .font_family("Menlo")
                        .text_color(ui::tone_color(success_tone(repo.success_rate), chrome))
                        .child(format!("{:.0}%", repo.success_rate * 100.0)),
                );
        }
        if repo.total_runs > 0 {
            stats = stats.child(
                div()
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::count(
                        "explorer.sessions.runs",
                        "%d runs",
                        repo.total_runs,
                    )),
            );
        }
        if repo.total_tokens > 0 {
            stats = stats.child(
                div()
                    .font_family("Menlo")
                    .text_color(ui::tone_color(Tone::Info, chrome))
                    .child(numbers::abbreviated(repo.total_tokens)),
            );
        }
        if repo.total_cost > 0.0 {
            stats = stats.child(
                div()
                    .font_family("Menlo")
                    .text_color(ui::tone_color(Tone::Warn, chrome))
                    .child(format!("${:.2}", repo.total_cost)),
            );
        }
        stats = stats.child(div().flex_1());
        for provider in &repo.providers {
            stats = stats.child(
                div()
                    .px_1()
                    .rounded_sm()
                    .bg(chrome.text_muted.opacity(0.15))
                    .child(capitalized(provider)),
            );
        }
        let tools = repo
            .top_tools
            .iter()
            .take(4)
            .map(|(tool, count)| format!("{tool} \u{00d7}{count}"))
            .collect::<Vec<_>>()
            .join("  ");
        overview = overview.child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .py_1()
                .border_b_1()
                .border_color(chrome.border)
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(
                            div()
                                .text_xs()
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .child(format!("\u{1F4C1} {}", repo.name)),
                        )
                        .when_some(repo.last_activity_ago, |d, ago| {
                            d.child(ui::caption(relative_time(ago), chrome))
                        }),
                )
                .child(stats)
                .when(!tools.is_empty(), |d| {
                    d.child(ui::mono_line(tools, chrome.text_muted))
                }),
        );
    }
    div().child(overview)
}

impl DebugConsole {
    pub(in crate::debug) fn analytics_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut picker = div().flex().gap_1();
        for (mode, label) in [
            (AnalyticsMode::ApiCalls, "API Calls"),
            (AnalyticsMode::AiRuns, "AI Runs"),
            (AnalyticsMode::Repos, "Repos"),
        ] {
            picker = picker.child(
                ui::chip(
                    SharedString::from(format!("analytics-{label}")),
                    label,
                    mode == self.analytics_mode,
                    chrome.accent,
                    chrome,
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.analytics_mode = mode;
                    cx.notify();
                })),
            );
        }
        let Some(source) = registry::analytics(cx) else {
            return ui::page(
                "analytics-page",
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(picker)
                    .child(ui::empty_note(
                        "Analytics has not registered its data yet (debug::set_analytics_source).",
                        chrome,
                    )),
            )
            .into_any_element();
        };
        let data = (source.data)(cx);
        let tabs = snapshot::tabs(cx);
        let page = match self.analytics_mode {
            AnalyticsMode::ApiCalls => proxy_page(&data, chrome),
            AnalyticsMode::AiRuns => {
                let rebuild = source.rebuild.clone().map(|rebuild| {
                    ui::button("analytics-rebuild", "Rebuild Transcript Metrics", chrome)
                        .on_click(cx.listener(move |_, _, _, cx| {
                            rebuild(cx);
                            cx.notify();
                        }))
                        .into_any_element()
                });
                runs_page(&data, &tabs, chrome, rebuild)
            }
            AnalyticsMode::Repos => repos_page(&data, chrome),
        };
        ui::page(
            "analytics-page",
            div().flex().flex_col().gap_3().child(picker).child(page),
        )
        .into_any_element()
    }
}
