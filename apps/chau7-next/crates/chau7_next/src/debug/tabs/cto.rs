//! Token Optimizer tab (`tokenOptimizerView`): period picker, hero metrics,
//! per-tab table, provider consumption, recent commands and the advanced
//! telemetry. The data comes from the optimizer module through
//! `debug::set_token_optimizer_source`.

use chau7_next_core::debug_console::{
    CtoPeriod, Tone, command_rate, count_outcome, filter_log, format_cost, format_delay,
    format_percent, format_token_count, format_uptime, health_issue_label, outcome_tone,
    per_tab_rows, per_tab_stats, rate_tone, token_rate_tone,
};
use chau7_next_core::token_optimization::{CTORuntimeHealthState, CTORuntimeSnapshot};
use gpui::{AnyElement, Context, IntoElement, SharedString, div, prelude::*, px};

use super::{compact_time, tab_label};
use crate::debug::console::DebugConsole;
use crate::debug::{registry, snapshot, ui};
use crate::theme::Chrome;

/// Seconds between the Unix epoch and the Swift reference date.
const REFERENCE_DATE_UNIX_OFFSET: f64 = 978_307_200.0;

fn now_unix() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// Midnight today (local time) in Unix seconds.
fn start_of_today() -> f64 {
    use chrono::{Local, TimeZone};
    let now = Local::now();
    Local
        .with_ymd_and_hms(
            chrono::Datelike::year(&now),
            chrono::Datelike::month(&now),
            chrono::Datelike::day(&now),
            0,
            0,
            0,
        )
        .single()
        .map_or(0.0, |t| t.timestamp() as f64)
}

fn health_tone(state: CTORuntimeHealthState) -> Tone {
    match state {
        CTORuntimeHealthState::Healthy => Tone::Good,
        CTORuntimeHealthState::Warning => Tone::Warn,
        CTORuntimeHealthState::Critical => Tone::Bad,
    }
}

fn cell(text: impl Into<String>, tone: Option<Tone>) -> (SharedString, Option<Tone>) {
    (SharedString::from(text.into()), tone)
}

fn reason_name(reason: &chau7_next_core::token_optimization::CTODecisionReason) -> String {
    serde_json::to_value(reason)
        .ok()
        .and_then(|v| v.as_str().map(str::to_string))
        .unwrap_or_default()
}

impl DebugConsole {
    pub(in crate::debug) fn token_optimizer_tab(
        &mut self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(source) = registry::token_optimizer(cx) else {
            return ui::page(
                "cto-page",
                ui::empty_note(
                    "The token optimizer has not registered its data yet (debug::set_token_optimizer_source).",
                    chrome,
                ),
            )
            .into_any_element();
        };
        let period = self.cto_period;
        let mut data = (source.data)(period, cx);
        let cutoff = period.cutoff(
            data.runtime.first_seen_at + REFERENCE_DATE_UNIX_OFFSET,
            start_of_today(),
            now_unix(),
        );
        data.log = filter_log(&data.log, cutoff);
        let tabs = snapshot::tabs(cx);

        let mut picker = div().flex().gap_1();
        for candidate in CtoPeriod::ALL {
            picker = picker.child(
                ui::chip(
                    SharedString::from(format!("cto-period-{}", candidate.label())),
                    candidate.label(),
                    candidate == period,
                    chrome.accent,
                    chrome,
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.cto_period = candidate;
                    cx.notify();
                })),
            );
        }

        // Hero metrics.
        let rate = command_rate(&data.log);
        let gain = data.gain.as_ref();
        let dash = || "--".to_string();
        let hero = ui::group("", chrome).child(
            div()
                .flex()
                .gap_1()
                .child(ui::metric(
                    "Command Rate",
                    format_percent(rate),
                    rate_tone(rate),
                    chrome,
                ))
                .child(ui::metric(
                    period.savings_title("Token Rate"),
                    gain.map_or_else(dash, |g| format!("{:.0}%", g.savings_pct)),
                    token_rate_tone(gain),
                    chrome,
                ))
                .child(ui::metric(
                    period.savings_title("Tokens Saved"),
                    gain.map_or_else(dash, |g| format_token_count(g.saved_tokens)),
                    Tone::Good,
                    chrome,
                ))
                .child(ui::metric(
                    "Optimized",
                    outcome_count(&data.log, "optimized"),
                    Tone::Info,
                    chrome,
                ))
                .child(ui::metric(
                    "Fallthrough",
                    outcome_count(&data.log, "fallthrough"),
                    Tone::Warn,
                    chrome,
                ))
                .child(ui::metric(
                    "Skipped",
                    outcome_count(&data.log, "skipped"),
                    Tone::Muted,
                    chrome,
                )),
        );

        // Per-tab table.
        let mut per_tab = ui::group("Per-Tab Stats", chrome);
        let tab_stats = per_tab_stats(&data.log);
        if data.log.is_empty() && data.tab_consumption.is_empty() {
            per_tab = per_tab.child(ui::caption("No command data yet", chrome));
        } else {
            let weights = [2.3, 1.0, 1.0, 1.0, 1.0, 1.1, 1.4, 1.4, 1.3, 1.6];
            per_tab = per_tab.child(ui::table_row(
                [
                    "Tab",
                    "Cmds",
                    "Opt",
                    "Fall",
                    "Skip",
                    "Rate",
                    "In Tok",
                    "Out Tok",
                    "Cost",
                    "CTO Saved",
                ]
                .into_iter()
                .map(|h| cell(h, None))
                .collect(),
                &weights,
                true,
                chrome,
            ));
            for id in per_tab_rows(&tab_stats, &data.tab_consumption) {
                let stat = tab_stats.iter().find(|s| s.session_id == id);
                let ai = data.tab_consumption.iter().find(|a| a.tab_id == id);
                let saved = data.session_gain.get(&id);
                let label = tab_label(
                    &id,
                    &tabs,
                    ai.and_then(|a| a.last_provider.as_deref()),
                    ai.and_then(|a| a.last_location_path.as_deref()),
                );
                per_tab = per_tab.child(ui::table_row(
                    vec![
                        cell(label, None),
                        cell(stat.map_or(0, |s| s.total).to_string(), None),
                        cell(
                            stat.map_or(0, |s| s.optimized).to_string(),
                            Some(Tone::Good),
                        ),
                        cell(
                            stat.map_or(0, |s| s.fallthrough).to_string(),
                            Some(Tone::Warn),
                        ),
                        cell(stat.map_or(0, |s| s.skipped).to_string(), Some(Tone::Muted)),
                        cell(
                            stat.map_or_else(dash, |s| format!("{:.0}%", s.rate())),
                            Some(stat.map_or(Tone::Muted, |s| rate_tone(Some(s.rate())))),
                        ),
                        cell(
                            ai.map_or_else(dash, |a| format_token_count(a.total_input_tokens)),
                            None,
                        ),
                        cell(
                            ai.map_or_else(dash, |a| format_token_count(a.total_output_tokens)),
                            None,
                        ),
                        cell(
                            ai.map_or_else(dash, |a| format_cost(a.total_cost_usd)),
                            None,
                        ),
                        cell(
                            saved.map_or_else(dash, |g| format_token_count(g.saved_tokens)),
                            Some(Tone::Good),
                        ),
                    ],
                    &weights,
                    false,
                    chrome,
                ));
            }
        }

        // Provider consumption.
        let mut providers = ui::group("Provider Consumption", chrome);
        if data.provider_consumption.is_empty() {
            providers = providers.child(ui::caption("No AI run data yet", chrome));
        } else {
            let weights = [3.0, 1.2, 1.7, 1.7, 1.7, 1.6];
            providers = providers.child(ui::table_row(
                ["Provider", "Runs", "Input", "Output", "Total", "Cost"]
                    .into_iter()
                    .map(|h| cell(h, None))
                    .collect(),
                &weights,
                true,
                chrome,
            ));
            let (mut runs, mut input, mut output, mut cost) = (0, 0, 0, 0.0);
            for stat in &data.provider_consumption {
                runs += stat.run_count;
                input += stat.total_input_tokens;
                output += stat.total_output_tokens;
                cost += stat.total_cost_usd;
                providers = providers.child(ui::table_row(
                    vec![
                        cell(stat.provider.clone(), None),
                        cell(stat.run_count.to_string(), None),
                        cell(format_token_count(stat.total_input_tokens), None),
                        cell(format_token_count(stat.total_output_tokens), None),
                        cell(
                            format_token_count(stat.total_input_tokens + stat.total_output_tokens),
                            None,
                        ),
                        cell(format_cost(stat.total_cost_usd), None),
                    ],
                    &weights,
                    false,
                    chrome,
                ));
            }
            providers = providers.child(
                div().pt_1().border_t_1().border_color(chrome.border).child(
                    ui::table_row(
                        vec![
                            cell("Total", None),
                            cell(runs.to_string(), None),
                            cell(format_token_count(input), None),
                            cell(format_token_count(output), None),
                            cell(format_token_count(input + output), None),
                            cell(format_cost(cost), None),
                        ],
                        &weights,
                        false,
                        chrome,
                    )
                    .font_weight(gpui::FontWeight::SEMIBOLD),
                ),
            );
        }

        // Recent commands.
        let mut recent = ui::group("Recent Commands", chrome);
        if data.log.is_empty() {
            recent = recent.child(ui::caption(
                "No commands logged yet. Commands are logged when CTO is active.",
                chrome,
            ));
        } else {
            for entry in data.log.iter().rev().take(20) {
                let tone = outcome_tone(&entry.outcome);
                let color = ui::tone_color(tone, chrome);
                recent = recent.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .text_xs()
                        .font_family("Menlo")
                        .when(entry.is_intentional_skip(), |d| d.opacity(0.5))
                        .child(div().size(px(6.0)).rounded_full().bg(color))
                        .child(div().w(px(70.0)).child(compact_time(entry.timestamp)))
                        .child(div().w(px(80.0)).child(entry.command.clone()))
                        .child(
                            div()
                                .w(px(80.0))
                                .text_color(color)
                                .child(entry.outcome.clone()),
                        )
                        .when(entry.exit_code != 0 && entry.outcome == "error", |d| {
                            d.child(
                                div()
                                    .text_color(ui::tone_color(Tone::Bad, chrome))
                                    .child(format!("exit {}", entry.exit_code)),
                            )
                        }),
                );
            }
        }

        let advanced = self.advanced_section(&data.runtime, chrome, cx);

        let mode = data.runtime.mode.clone();
        let refresh = source.refresh.clone();
        let reset = source.reset.clone();
        let actions = div()
            .flex()
            .items_center()
            .gap_2()
            .child(
                ui::button("cto-refresh", "Refresh", chrome).on_click(cx.listener(
                    move |_, _, _, cx| {
                        if let Some(refresh) = &refresh {
                            refresh(cx);
                        }
                        cx.notify();
                    },
                )),
            )
            .child(
                ui::button("cto-reset", "Reset Monitor", chrome).on_click(cx.listener(
                    move |_, _, _, cx| {
                        if let Some(reset) = &reset {
                            reset(cx);
                        }
                        cx.notify();
                    },
                )),
            )
            .child(div().flex_1())
            .child(ui::caption(format!("Global Mode: {mode}"), chrome));

        ui::page(
            "cto-page",
            div()
                .flex()
                .flex_col()
                .gap_3()
                .child(picker)
                .child(ui::caption(period.note(), chrome))
                .child(hero)
                .child(per_tab)
                .child(providers)
                .child(recent)
                .child(advanced)
                .child(actions),
        )
        .into_any_element()
    }

    /// "Advanced Telemetry" (a disclosure group).
    fn advanced_section(
        &self,
        runtime: &CTORuntimeSnapshot,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> gpui::Div {
        let open = self.cto_advanced;
        let header = div()
            .id("cto-advanced")
            .flex()
            .items_center()
            .gap_1()
            .cursor_pointer()
            .text_xs()
            .font_weight(gpui::FontWeight::SEMIBOLD)
            .child(if open { "\u{25BE}" } else { "\u{25B8}" })
            .child(crate::l10n::tr("Advanced Telemetry"))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cto_advanced = !this.cto_advanced;
                cx.notify();
            }));
        let mut section = div().flex().flex_col().gap_2().child(header);
        if !open {
            return section;
        }
        let health = runtime.assessment();
        let tone = health_tone(health.state);
        let state_text = serde_json::to_value(health.state)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();
        let mut body = ui::group("", chrome)
            .child(ui::caption(
                "Runtime telemetry below is monitor-lifetime and ignores the period filter.",
                chrome,
            ))
            .child(ui::value_row(
                "Runtime health",
                state_text,
                Some(tone),
                chrome,
            ))
            .child(ui::value_row(
                "Health score",
                format!("{}/100", health.score),
                Some(tone),
                chrome,
            ))
            .child(ui::state_row(
                "Recalculations",
                runtime.recalc_count.to_string(),
                chrome,
            ))
            .child(ui::state_row(
                "Flags created",
                runtime.created_count.to_string(),
                chrome,
            ))
            .child(ui::state_row(
                "Flags removed",
                runtime.removed_count.to_string(),
                chrome,
            ))
            .child(ui::state_row(
                "Unchanged",
                runtime.unchanged_count.to_string(),
                chrome,
            ))
            .child(ui::state_row(
                "Change rate",
                format!("{:.1}%", runtime.decisions_change_rate_percent()),
                chrome,
            ))
            .child(ui::state_row(
                "Decisions/min",
                format!("{:.1}", runtime.decisions_per_minute),
                chrome,
            ))
            .child(ui::state_row(
                "Uptime",
                format_uptime(runtime.uptime_seconds),
                chrome,
            ))
            .child(ui::state_row(
                "Active sessions",
                format!(
                    "{} / {}",
                    runtime.active_session_count, runtime.tracked_sessions
                ),
                chrome,
            ));
        if runtime.deferred_set_count > 0 {
            body = body
                .child(ui::state_row(
                    "Deferred set / flush / skip",
                    format!(
                        "{} / {} / {}",
                        runtime.deferred_set_count,
                        runtime.deferred_flush_count,
                        runtime.deferred_skip_count
                    ),
                    chrome,
                ))
                .child(ui::state_row(
                    "Deferred delay (min/avg/max)",
                    format!(
                        "{} / {} / {}",
                        format_delay(runtime.deferred_flush_delay_min_ms),
                        format_delay(
                            runtime
                                .deferred_flush_delay_average_ms
                                .map(|v| v.round() as i64)
                        ),
                        format_delay(runtime.deferred_flush_delay_max_ms)
                    ),
                    chrome,
                ));
        }
        for issue in &health.issues {
            body = body.child(ui::value_row(
                "\u{26A0}",
                health_issue_label(*issue),
                Some(Tone::Warn),
                chrome,
            ));
        }
        if !runtime.reason_breakdown.is_empty() {
            let total: i64 = runtime.reason_breakdown.values().sum();
            let mut reasons: Vec<_> = runtime.reason_breakdown.iter().collect();
            reasons.sort();
            body = body.child(ui::caption("Decision Reasons", chrome));
            for (reason, count) in reasons {
                let share = if total > 0 {
                    *count as f64 / total as f64 * 100.0
                } else {
                    0.0
                };
                body = body.child(ui::state_row(
                    reason.clone(),
                    format!("{count} ({share:.0}%)"),
                    chrome,
                ));
            }
        }
        if !runtime.recent_decisions.is_empty() {
            body = body.child(ui::caption("Recent Decisions", chrome));
            for decision in runtime.recent_decisions.iter().rev().take(6) {
                let id: String = decision.session_id.chars().take(8).collect();
                body = body.child(ui::mono_line(
                    format!(
                        "{} {} {} {}",
                        if decision.changed { "\u{26A1}" } else { "=" },
                        compact_time(decision.timestamp + REFERENCE_DATE_UNIX_OFFSET),
                        id,
                        reason_name(&decision.reason)
                    ),
                    chrome.text_muted,
                ));
            }
        }
        section = section.child(body);
        section
    }
}

fn outcome_count(log: &[chau7_next_core::debug_console::CtoLogEntry], outcome: &str) -> String {
    if log.is_empty() {
        "--".into()
    } else {
        count_outcome(log, outcome).to_string()
    }
}
