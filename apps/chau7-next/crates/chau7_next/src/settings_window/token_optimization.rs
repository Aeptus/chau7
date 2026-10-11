//! Token Optimization (`TokenOptimizationSettingsView.swift`): the mode, the
//! input prefix, the optimizer and wrapper health, the runtime telemetry, the
//! recent optimizer commands, the token savings, per-tab control, the list of
//! optimized commands and "How It Works".

use chau7_next_core::cto_wrappers;
use chau7_next_core::debug_console::{CtoLogEntry, Tone, outcome_tone};
use chau7_next_core::token_optimization::{
    CTORuntimeAssessmentIssue, CTORuntimeHealthState, CTORuntimeSnapshot, TokenOptimizationMode,
    cto_rewrite, supported_commands,
};
use chrono::{Local, TimeZone};
use gpui::{App, Entity, SharedString, Subscription, Window, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::widgets::{button, chip, description, info_row, row, section as titled, toggle};
use super::{SectionContext, SettingsView, update};
use crate::cto::{GainCache, Health};
use crate::debug::ui::tone_color;
use crate::settings::token_optimization::clean_prefix;
use crate::theme::Chrome;
use crate::workspace::AppData;

/// The text field of the section: the input prefix.
pub(super) struct CtoInputs {
    prefix: Entity<InputState>,
    _subscription: Subscription,
}

impl CtoInputs {
    pub(super) fn new(window: &mut Window, cx: &mut gpui::Context<SettingsView>) -> Self {
        let initial = crate::settings::Settings::get(cx).cto.prefix.clone();
        let prefix = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("/think")
                .default_value(initial)
        });
        let subscription = cx.subscribe(&prefix, |_, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                let value = clean_prefix(input.read(cx).value().as_ref());
                if value != crate::settings::Settings::get(cx).cto.prefix {
                    update(cx, |s| s.cto.prefix = value);
                }
            }
        });
        Self {
            prefix,
            _subscription: subscription,
        }
    }
}

/// What the section reads from outside the settings (files, monitor, tabs).
/// Read only while the section is shown.
#[derive(Default)]
pub struct CtoData {
    health: Health,
    runtime: CTORuntimeSnapshot,
    log: Vec<CtoLogEntry>,
    success_rate: Option<f64>,
    gain: GainCache,
    /// Open tabs: shell id and title.
    tabs: Vec<(String, String)>,
}

impl CtoData {
    pub(super) fn read(shown: bool, cx: &App) -> Self {
        if !shown {
            return Self::default();
        }
        let mut tabs: Vec<(String, String)> = AppData::live(cx)
            .into_iter()
            .flat_map(|(_, ws)| ws.read(cx).cto_tabs(cx))
            .collect();
        tabs.sort_by_key(|(_, title)| title.to_lowercase());
        let all = crate::cto::command_log(5000);
        Self {
            health: crate::cto::health(),
            runtime: crate::cto::runtime_snapshot(),
            success_rate: cto_wrappers::command_success_rate(&all),
            log: all.into_iter().rev().take(50).collect(),
            gain: crate::cto::gain_cache(),
            tabs,
        }
    }
}

fn mode_name(mode: TokenOptimizationMode) -> &'static str {
    match mode {
        TokenOptimizationMode::Off => "Off",
        TokenOptimizationMode::AllTabs => "All Commands",
        TokenOptimizationMode::AiOnly => "AI Commands Only",
        TokenOptimizationMode::Manual => "Manual (Per-Tab)",
    }
}

fn mode_description(mode: TokenOptimizationMode) -> &'static str {
    match mode {
        TokenOptimizationMode::Off => "Token optimization is disabled",
        TokenOptimizationMode::AllTabs => "Active in every tab for all commands",
        TokenOptimizationMode::AiOnly => "Activates when an AI CLI is detected",
        TokenOptimizationMode::Manual => "Manually enable per tab",
    }
}

fn mode_detail(mode: TokenOptimizationMode) -> &'static str {
    match mode {
        TokenOptimizationMode::Off => "",
        TokenOptimizationMode::AllTabs => {
            "All tabs optimized by default. A red wand badge appears on tabs you opt out."
        }
        TokenOptimizationMode::AiOnly => {
            "AI tabs auto-optimize. Yellow wand when you force a tab on, red wand when you force off."
        }
        TokenOptimizationMode::Manual => {
            "No tabs optimized by default. A yellow wand badge appears on tabs you opt in."
        }
    }
}

fn mode_tone(mode: TokenOptimizationMode) -> Tone {
    match mode {
        TokenOptimizationMode::Off => Tone::Muted,
        TokenOptimizationMode::AllTabs => Tone::Warn,
        TokenOptimizationMode::AiOnly => Tone::Accent,
        TokenOptimizationMode::Manual => Tone::Info,
    }
}

fn on(ctx: &SectionContext) -> bool {
    ctx.settings.cto.mode != TokenOptimizationMode::Off
}

fn empty() -> gpui::Div {
    div()
}

fn mono(text: impl Into<SharedString>, chrome: Chrome) -> gpui::Div {
    div()
        .px_1p5()
        .py_0p5()
        .rounded_sm()
        .bg(chrome.tab_bg)
        .text_xs()
        .font_family("Menlo")
        .text_color(chrome.text)
        .child(text.into())
}

/// Optimization Mode: the picker and what the mode does.
pub(super) fn mode(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let current = ctx.settings.cto.mode;
    let chips =
        div()
            .flex()
            .flex_wrap()
            .gap_1()
            .children(TokenOptimizationMode::ALL.into_iter().map(move |m| {
                chip(
                    SharedString::from(format!("cto-mode-{}", m.raw_value())),
                    mode_name(m),
                    current == m,
                    chrome,
                )
                .cursor_pointer()
                .on_click(move |_, _, cx| update(cx, |s| s.cto.mode = m))
            }));
    let mut summary = div()
        .flex()
        .flex_col()
        .gap_1()
        .p_3()
        .rounded_md()
        .bg(chrome.tab_bg)
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(tone_color(mode_tone(current), chrome))
                .child(mode_name(current)),
        )
        .child(description(mode_description(current), chrome));
    if current != TokenOptimizationMode::Off {
        summary = summary.child(description(mode_detail(current), chrome));
    }
    titled("Optimization Mode", chrome)
        .child(row("Mode", chips, chrome))
        .child(description(
            "Controls when token-optimized command output is active",
            chrome,
        ))
        .child(summary)
}

/// Input Prefix: on or off and the text.
pub(super) fn prefix(ctx: &SectionContext) -> gpui::Div {
    if !on(ctx) {
        return empty();
    }
    let chrome = ctx.chrome;
    let c = &ctx.settings.cto;
    titled("Input Prefix", chrome)
        .child(row(
            "Enable Input Prefix",
            toggle("cto-prefix-enabled", c.prefix_enabled, chrome, |s, v| {
                s.cto.prefix_enabled = v
            }),
            chrome,
        ))
        .child(description(
            "When enabled, the prefix text is prepended to terminal input.",
            chrome,
        ))
        .child(row(
            "Input Prefix",
            div().w(px(220.0)).child(Input::new(&ctx.view.cto.prefix)),
            chrome,
        ))
        .child(description(
            "Prefix text to prepend (supports per-tab overrides).",
            chrome,
        ))
}

fn status_dot(tone: Tone, chrome: Chrome) -> gpui::Div {
    div()
        .size(px(8.0))
        .rounded_full()
        .bg(tone_color(tone, chrome))
}

/// Optimizer: install status, wrapper health, the markdown renderer.
pub(super) fn optimizer(ctx: &SectionContext) -> gpui::Div {
    if !on(ctx) {
        return empty();
    }
    let chrome = ctx.chrome;
    let h = &ctx.cto.health;
    let installed = div()
        .flex()
        .items_center()
        .gap_2()
        .child(status_dot(
            if h.optimizer_installed {
                Tone::Good
            } else {
                Tone::Warn
            },
            chrome,
        ))
        .child(if h.optimizer_installed {
            div()
                .flex()
                .flex_col()
                .child(div().text_sm().child(crate::l10n::tr("Installed")))
                .child(
                    div()
                        .text_xs()
                        .font_family("Menlo")
                        .text_color(chrome.text_muted)
                        .child(h.optimizer_path.to_string_lossy().to_string()),
                )
        } else {
            div().text_sm().child(crate::l10n::tr(
                "Not installed - commands will pass through unoptimized",
            ))
        });
    let reinstall_bundle = button("cto-reinstall-bundle", "Reinstall from Bundle", chrome)
        .on_click(|_, _, cx| {
            crate::cto::reinstall_optimizer();
            crate::cto::refresh_gain(cx);
            cx.refresh_windows();
        });
    let all_good = cto_wrappers::is_fully_installed(&h.wrappers);
    let health_line = div()
        .flex()
        .items_center()
        .justify_between()
        .gap_2()
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(status_dot(
                    if all_good { Tone::Good } else { Tone::Warn },
                    chrome,
                ))
                .child(div().text_sm().child(if all_good {
                    "All wrapper scripts installed and executable"
                } else {
                    "Some wrapper scripts need attention"
                })),
        )
        .child(
            button("cto-reinstall-wrappers", "Reinstall", chrome).on_click(|_, _, cx| {
                let root = cx.global::<AppData>().root.clone();
                crate::cto::setup(&root);
                cx.refresh_windows();
            }),
        );
    let md = h.markdown_installed;
    let wrapper_rows = div()
        .flex()
        .flex_col()
        .gap_0p5()
        .children(h.wrappers.iter().map(|w| {
            let tone = if w.is_installed && w.is_executable {
                Tone::Good
            } else if w.is_installed {
                Tone::Warn
            } else {
                Tone::Bad
            };
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(status_dot(tone, chrome))
                .child(
                    div()
                        .text_sm()
                        .font_family("Menlo")
                        .child(w.command.clone()),
                )
                .when(w.command == "cat" && md, |d| {
                    d.child(
                        div()
                            .text_xs()
                            .font_family("Menlo")
                            .text_color(tone_color(Tone::Accent, chrome))
                            .child("+ md"),
                    )
                })
                .child(div().flex_1())
                .when(!w.is_installed, |d| {
                    d.child(
                        div()
                            .text_xs()
                            .text_color(tone_color(Tone::Bad, chrome))
                            .child(crate::l10n::tr("Missing")),
                    )
                })
                .when(w.is_installed && !w.is_executable, |d| {
                    d.child(
                        div()
                            .text_xs()
                            .text_color(tone_color(Tone::Warn, chrome))
                            .child(crate::l10n::tr("Not executable")),
                    )
                })
        }));
    let md_row = div()
        .flex()
        .items_center()
        .gap_2()
        .child(status_dot(
            if md { Tone::Good } else { Tone::Muted },
            chrome,
        ))
        .child(
            div()
                .text_sm()
                .font_family("Menlo")
                .child(crate::l10n::tr("chau7-md")),
        )
        .child(description("Markdown renderer", chrome))
        .child(div().flex_1())
        .when(!md, |d| d.child(description("Not installed", chrome)));
    titled("Optimizer", chrome)
        .child(description(
            "The optimizer filters and compresses command output before it reaches your LLM context, typically saving 60-90% of tokens. It ships built-in - no external dependencies required.",
            chrome,
        ))
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .gap_2()
                .child(installed)
                .child(reinstall_bundle),
        )
        .child(health_line)
        .child(wrapper_rows)
        .child(md_row)
        .when(md, |d| {
            d.child(description(
                "cat README.md renders with ANSI formatting in terminal",
                chrome,
            ))
        })
}

fn percent(value: f64) -> String {
    format!("{value:.1}%")
}

/// `1h 02m 03s`, `4m 05s`, `6s`.
fn duration(seconds: i64) -> String {
    if seconds < 0 {
        return "0s".into();
    }
    let (h, m, s) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60);
    if h > 0 {
        format!("{h}h {m:02}m {s:02}s")
    } else if m > 0 {
        format!("{m}m {s:02}s")
    } else {
        format!("{s}s")
    }
}

fn duration_f(seconds: f64) -> String {
    if seconds < 1.0 {
        format!("{:.0}ms", seconds * 1000.0)
    } else {
        duration(seconds as i64)
    }
}

fn delay(ms: Option<i64>) -> String {
    ms.map_or_else(|| "n/a".into(), |v| format!("{v}ms"))
}

fn issue_label(issue: CTORuntimeAssessmentIssue) -> &'static str {
    chau7_next_core::debug_console::health_issue_label(issue)
}

/// `HH:mm:ss.SSS` of a reference-date time.
fn compact_time(reference_seconds: f64) -> String {
    let unix = reference_seconds + 978_307_200.0;
    Local
        .timestamp_millis_opt((unix * 1000.0) as i64)
        .single()
        .map_or_else(String::new, |t| t.format("%H:%M:%S%.3f").to_string())
}

/// CTO Runtime Telemetry (dev).
pub(super) fn runtime(ctx: &SectionContext) -> gpui::Div {
    if !on(ctx) {
        return empty();
    }
    let chrome = ctx.chrome;
    let snap = &ctx.cto.runtime;
    let health = snap.assessment();
    let tone = match health.state {
        CTORuntimeHealthState::Healthy => Tone::Good,
        CTORuntimeHealthState::Warning => Tone::Warn,
        CTORuntimeHealthState::Critical => Tone::Bad,
    };
    let summary = match health.state {
        CTORuntimeHealthState::Healthy => "Healthy",
        CTORuntimeHealthState::Warning => "Needs review",
        CTORuntimeHealthState::Critical => "Requires attention",
    };
    let stat = |label: &'static str, value: String| info_row(label, value, chrome);
    let mut block = titled("CTO Runtime Telemetry", chrome)
        .child(row(
            "Runtime health",
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(status_dot(tone, chrome))
                .child(div().text_sm().child(summary)),
            chrome,
        ))
        .child(stat("Health score", format!("{}/100", health.score)))
        .child(stat(
            "Decision change rate",
            percent(snap.decisions_change_rate_percent()),
        ))
        .child(stat(
            "Deferred skip rate",
            percent(snap.deferred_skip_rate_percent()),
        ))
        .child(stat(
            "Deferred flush rate",
            percent(snap.deferred_flush_rate_percent()),
        ))
        .child(stat(
            "Active sessions ratio",
            percent(snap.active_session_ratio_percent()),
        ));
    if let Some(age) = snap.age_since_last_decision_seconds() {
        block = block.child(stat("Last decision age", duration(age)));
    }
    if let Some(v) = snap.decision_interval_average_seconds() {
        block = block.child(stat("Decision interval (avg)", duration_f(v)));
    }
    if let Some(v) = snap.decision_interval_min_seconds() {
        block = block.child(stat("Decision interval (min)", duration_f(v)));
    }
    if let Some(v) = snap.decision_interval_max_seconds() {
        block = block.child(stat("Decision interval (max)", duration_f(v)));
    }
    block = if health.issues.is_empty() {
        block.child(description("No health signals", chrome))
    } else {
        block
            .child(description("Health signals", chrome))
            .children(health.issues.iter().map(|issue| {
                div()
                    .text_xs()
                    .font_family("Menlo")
                    .text_color(tone_color(Tone::Warn, chrome))
                    .child(issue_label(*issue))
            }))
    };
    block = block
        .child(stat("Monitor uptime", duration(snap.uptime_seconds)))
        .child(stat(
            "Decisions/min",
            format!("{:.1}", snap.decisions_per_minute),
        ))
        .child(stat(
            "Decision recalculations",
            snap.recalc_count.to_string(),
        ))
        .child(stat("Created flags", snap.created_count.to_string()))
        .child(stat("Removed flags", snap.removed_count.to_string()))
        .child(stat("Unchanged", snap.unchanged_count.to_string()))
        .child(stat("Runtime setups", snap.setup_count.to_string()))
        .child(stat("Runtime teardowns", snap.teardown_count.to_string()))
        .child(stat("Mode changes", snap.mode_change_count.to_string()))
        .child(stat(
            "Pending deferred sessions",
            snap.pending_deferred_sessions.to_string(),
        ))
        .child(stat("Deferred sets", snap.deferred_set_count.to_string()))
        .child(stat(
            "Deferred flushes",
            snap.deferred_flush_count.to_string(),
        ))
        .child(stat("Deferred skips", snap.deferred_skip_count.to_string()))
        .child(stat(
            "Deferred cancellations",
            snap.deferred_cancel_count.to_string(),
        ))
        .child(stat(
            "Eligible deferrals",
            snap.deferred_eligible_count().to_string(),
        ))
        .child(stat(
            "Deferred delay samples",
            snap.deferred_flush_delay_count.to_string(),
        ))
        .child(stat(
            "Deferred delay (min / max / avg / last)",
            format!(
                "{} / {} / {} / {}",
                delay(snap.deferred_flush_delay_min_ms),
                delay(snap.deferred_flush_delay_max_ms),
                delay(
                    snap.deferred_flush_delay_average_ms
                        .map(|v| v.round() as i64)
                ),
                delay(snap.deferred_flush_delay_last_ms),
            ),
        ));
    if let Some(paths) = crate::cto::paths() {
        block=block.child(stat("Diagnostic state file",paths.state_file().display().to_string())).child(description("Five-minute heartbeat while enabled. Removed when CTO is off. Flag files remain the wrapper hot path.",chrome));
    }
    if let Some(gain) = &snap.gain_stats {
        block = block.child(stat(
            "Last observed gain",
            format!(
                "{} commands; {} tokens saved ({:.1}%)",
                gain.commands, gain.saved_tokens, gain.savings_pct
            ),
        ));
    }
    if let Some(sample) = snap.gain_stats_last_sampled_at {
        block = block.child(stat(
            "Gain sample age",
            duration(
                (chau7_next_core::token_optimization::reference_now() - sample).max(0.0) as i64,
            ),
        ));
    }
    if !snap.trigger_breakdown.is_empty() {
        let mut triggers: Vec<_> = snap.trigger_breakdown.iter().collect();
        triggers.sort();
        block = block
            .child(description("Decision triggers", chrome))
            .children(
                triggers
                    .into_iter()
                    .map(|(trigger, count)| info_row(trigger.clone(), count.to_string(), chrome)),
            );
    }
    if !snap.reason_breakdown.is_empty() {
        let total: i64 = snap.reason_breakdown.values().sum();
        let mut reasons: Vec<(&String, &i64)> = snap.reason_breakdown.iter().collect();
        reasons.sort();
        block = block
            .child(description("Decision reasons", chrome))
            .children(reasons.into_iter().map(|(reason, count)| {
                let ratio = if total > 0 {
                    *count as f64 / total as f64 * 100.0
                } else {
                    0.0
                };
                div()
                    .flex()
                    .gap_2()
                    .text_xs()
                    .font_family("Menlo")
                    .text_color(chrome.text_muted)
                    .child(div().w(px(160.0)).child(reason.clone()))
                    .child(format!("{count} ({ratio:.1}%)"))
            }));
    }
    block = if snap.recent_decisions.is_empty() {
        block.child(description("No decisions recorded yet", chrome))
    } else {
        block
            .child(description("Recent decisions", chrome))
            .children(snap.recent_decisions.iter().rev().take(5).map(|d| {
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_xs()
                    .child(status_dot(
                        if d.changed { Tone::Good } else { Tone::Warn },
                        chrome,
                    ))
                    .child(
                        div()
                            .min_w(px(110.0))
                            .font_family("Menlo")
                            .text_color(chrome.text_muted)
                            .child(compact_time(d.timestamp)),
                    )
                    .child(
                        div()
                            .font_family("Menlo")
                            .child(d.session_id.chars().take(8).collect::<String>()),
                    )
                    .child(
                        div()
                            .text_color(chrome.text_muted)
                            .child(format!("{} {} {:?}", d.mode, d.override_mode, d.reason)),
                    )
            }))
    };
    block
        .child(
            div()
                .flex()
                .gap_2()
                .child(
                    button("cto-runtime-refresh", "Refresh", chrome)
                        .on_click(|_, _, cx| cx.refresh_windows()),
                )
                .child(
                    button("cto-runtime-reset", "Reset", chrome).on_click(|_, _, cx| {
                        crate::cto::reset_monitor();
                        cx.refresh_windows();
                    }),
                ),
        )
        .child(description(
            format!("Tracked: {}", snap.tracked_sessions),
            chrome,
        ))
}

/// Recent Optimizer Commands: the last 50 wrapper outcomes.
pub(super) fn command_log(ctx: &SectionContext) -> gpui::Div {
    if !on(ctx) {
        return empty();
    }
    let chrome = ctx.chrome;
    let log = &ctx.cto.log;
    let block = titled("Recent Optimizer Commands", chrome);
    if log.is_empty() {
        return block.child(description("No optimizer commands recorded yet", chrome));
    }
    let count = |outcome: &str| log.iter().filter(|e| e.outcome == outcome).count();
    let (optimized, fallthrough, skipped) =
        (count("optimized"), count("fallthrough"), count("skipped"));
    let errors = log.len() - optimized - fallthrough - skipped;
    let counter = |tone: Tone, label: &'static str, n: usize| {
        div()
            .flex()
            .items_center()
            .gap_1()
            .text_xs()
            .child(status_dot(tone, chrome))
            .child(format!("{n} {label}"))
    };
    let summary = div()
        .flex()
        .items_center()
        .gap_4()
        .child(counter(Tone::Good, "optimized", optimized))
        .child(counter(Tone::Warn, "fallthrough", fallthrough))
        .child(counter(Tone::Muted, "skipped", skipped))
        .child(counter(Tone::Bad, "errors", errors))
        .child(div().flex_1())
        .when_some(ctx.cto.success_rate, |d, rate| {
            d.child(description(format!("Success rate: {rate:.0}%"), chrome))
        });
    let list = div()
        .id("cto-command-log")
        .flex()
        .flex_col()
        .gap_0p5()
        .max_h(px(200.0))
        .overflow_y_scroll()
        .children(log.iter().map(|e| {
            let time = Local
                .timestamp_millis_opt((e.timestamp * 1000.0) as i64)
                .single()
                .map_or_else(String::new, |t| t.format("%H:%M:%S%.3f").to_string());
            div()
                .flex()
                .items_center()
                .gap_2()
                .when(e.is_intentional_skip(), |d| d.opacity(0.5))
                .child(
                    div()
                        .text_xs()
                        .font_family("Menlo")
                        .text_color(chrome.text_muted)
                        .child(time),
                )
                .child(
                    div()
                        .text_xs()
                        .font_family("Menlo")
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .child(e.command.clone()),
                )
                .child(div().flex_1())
                .child(
                    div()
                        .text_xs()
                        .text_color(tone_color(outcome_tone(&e.outcome), chrome))
                        .child(e.outcome.clone()),
                )
        }));
    block.child(summary).child(list)
}

fn thousands(n: i64) -> String {
    let digits = n.abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    if n < 0 { format!("-{out}") } else { out }
}

/// Token Savings from `chau7-optim gain`.
pub(super) fn savings(ctx: &SectionContext) -> gpui::Div {
    if !on(ctx) {
        return empty();
    }
    let chrome = ctx.chrome;
    let gain = &ctx.cto.gain;
    let block = titled("Token Savings", chrome);
    let refresh = || {
        button("cto-savings-refresh", "Refresh", chrome).on_click(|_, _, cx| {
            crate::cto::refresh_gain(cx);
            cx.refresh_windows();
        })
    };
    if gain.loading {
        return block.child(description("Loading token savings...", chrome));
    }
    match gain.response.as_ref().map(|r| &r.summary) {
        Some(stats) if stats.commands > 0 => block
            .child(info_row("Total commands", thousands(stats.commands), chrome))
            .child(info_row(
                "Input tokens",
                thousands(stats.input_tokens),
                chrome,
            ))
            .child(info_row(
                "Output tokens",
                thousands(stats.output_tokens),
                chrome,
            ))
            .child(info_row(
                "Tokens saved",
                thousands(stats.saved_tokens),
                chrome,
            ))
            .child(info_row("Avg savings", percent(stats.savings_pct), chrome))
            .child(info_row(
                "Avg response time",
                format!("{}ms", stats.avg_time_ms),
                chrome,
            ))
            .child(div().flex().justify_end().child(refresh())),
        _ => block
            .child(description(
                "No token savings data yet. Run some commands with optimization active to see analytics.",
                chrome,
            ))
            .child(div().flex().justify_end().child(refresh())),
    }
}

fn info_line(tone: Tone, text: &'static str, chrome: Chrome) -> gpui::Div {
    div()
        .flex()
        .items_center()
        .gap_2()
        .child(status_dot(tone, chrome))
        .child(description(text, chrome))
}

/// A switch with a handler that captures (the per-tab rows).
fn switch(
    id: SharedString,
    on: bool,
    chrome: Chrome,
    handler: impl Fn(&mut App, bool) + 'static,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .w(px(38.0))
        .h(px(22.0))
        .rounded_full()
        .p(px(2.0))
        .flex()
        .when(on, |d| d.justify_end())
        .bg(if on { chrome.accent } else { chrome.border })
        .child(div().size(px(18.0)).rounded_full().bg(gpui::white()))
        .on_click(move |_, _, cx| handler(cx, !on))
}

/// Per-Tab Control: what the wand badges mean, and the input prefix per tab.
pub(super) fn per_tab(ctx: &SectionContext) -> gpui::Div {
    if !on(ctx) {
        return empty();
    }
    let chrome = ctx.chrome;
    let mut block = titled("Per-Tab Control", chrome);
    block = match ctx.settings.cto.mode {
        TokenOptimizationMode::Off => block,
        TokenOptimizationMode::AllTabs => block
            .child(info_line(
                Tone::Warn,
                "All tabs optimized by default - no badge shown",
                chrome,
            ))
            .child(info_line(
                Tone::Bad,
                "Red wand appears on tabs you opt out",
                chrome,
            )),
        TokenOptimizationMode::AiOnly => block
            .child(info_line(
                Tone::Warn,
                "Yellow wand when you force a tab on",
                chrome,
            ))
            .child(info_line(
                Tone::Bad,
                "Red wand when you force a tab off",
                chrome,
            )),
        TokenOptimizationMode::Manual => block
            .child(info_line(
                Tone::Warn,
                "Yellow wand appears on tabs you opt in",
                chrome,
            ))
            .child(info_line(
                Tone::Muted,
                "No badge on tabs following the default",
                chrome,
            )),
    };
    let tabs = &ctx.cto.tabs;
    if tabs.is_empty() {
        return block.child(row(
            "No active tabs",
            description("Open a tab to enable per-tab settings.", chrome),
            chrome,
        ));
    }
    let ids: Vec<String> = tabs.iter().map(|(id, _)| id.clone()).collect();
    let set_all = |id: &'static str, label: &'static str, ids: Vec<String>, value: bool| {
        button(id, label, chrome).on_click(move |_, _, cx| {
            let ids = ids.clone();
            update(cx, move |s| {
                for tab in &ids {
                    s.cto.set_override(tab, value);
                }
            })
        })
    };
    let clear_ids = ids.clone();
    block = block.child(row(
        "Apply to all open tabs",
        div()
            .flex()
            .gap_2()
            .child(set_all("cto-enable-all", "Enable all", ids.clone(), true))
            .child(set_all("cto-disable-all", "Disable all", ids, false))
            .child(
                button("cto-clear-all", "Use global on all", chrome).on_click(move |_, _, cx| {
                    let ids = clear_ids.clone();
                    update(cx, move |s| {
                        for tab in &ids {
                            s.cto.clear_override(tab);
                        }
                    })
                }),
            ),
        chrome,
    ));
    let cto = &ctx.settings.cto;
    for (id, title) in tabs {
        let has_override = cto.override_for(id).is_some();
        let global = cto.prefix_enabled;
        let tab = id.clone();
        let toggle_id = SharedString::from(format!("cto-tab-{id}"));
        let clear_id = SharedString::from(format!("cto-tab-clear-{id}"));
        let clear_tab = id.clone();
        block = block
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_4()
                    .min_h(px(30.0))
                    .child(div().text_sm().child(title.clone()))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_3()
                            .child(switch(
                                toggle_id,
                                cto.prefix_enabled_for(id),
                                chrome,
                                move |cx, value| {
                                    let tab = tab.clone();
                                    update(cx, move |s| {
                                        if value == global {
                                            s.cto.clear_override(&tab);
                                        } else {
                                            s.cto.set_override(&tab, value);
                                        }
                                    })
                                },
                            ))
                            .when(has_override, |d| {
                                d.child(button(clear_id, "Use global", chrome).on_click(
                                    move |_, _, cx| {
                                        let tab = clear_tab.clone();
                                        update(cx, move |s| s.cto.clear_override(&tab))
                                    },
                                ))
                            }),
                    ),
            )
            .child(description(
                if has_override {
                    "Overrides global optimization setting for this tab."
                } else {
                    "Uses global optimization setting."
                },
                chrome,
            ));
    }
    block
}

/// Optimized Commands: every wrapped command and where it goes.
pub(super) fn commands(ctx: &SectionContext) -> gpui::Div {
    if !on(ctx) {
        return empty();
    }
    let chrome = ctx.chrome;
    titled("Optimized Commands", chrome).children(supported_commands().into_iter().map(|c| {
        div()
            .flex()
            .items_center()
            .gap_2()
            .child(status_dot(Tone::Good, chrome))
            .child(div().text_sm().font_family("Menlo").child(c))
            .child(match cto_rewrite(c) {
                Some(sub) => div()
                    .text_xs()
                    .font_family("Menlo")
                    .text_color(tone_color(Tone::Accent, chrome))
                    .child(format!("-> optim {sub}")),
                None => div()
                    .text_xs()
                    .font_family("Menlo")
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::tr("exec only")),
            })
    }))
}

fn flow_row(number: &'static str, text: &'static str, chrome: Chrome) -> gpui::Div {
    div()
        .flex()
        .items_start()
        .gap_1p5()
        .child(
            div()
                .w(px(16.0))
                .text_xs()
                .font_family("Menlo")
                .text_color(chrome.text_muted)
                .child(number),
        )
        .child(description(text, chrome))
}

/// How It Works (also shown when the mode is off).
pub(super) fn how_it_works(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let paths = cto_wrappers::CtoPaths::from_root(ctx.root);
    let home = ctx.home.trim_end_matches('/');
    let short = |p: &std::path::Path| {
        let text = p.to_string_lossy().to_string();
        match text.strip_prefix(home) {
            Some(rest) => format!("~{rest}"),
            None => text,
        }
    };
    let bold = |text: &'static str| {
        div()
            .pt_1()
            .text_xs()
            .font_weight(gpui::FontWeight::SEMIBOLD)
            .child(text)
    };
    titled("How It Works", chrome)
        .child(bold("The Optimizer"))
        .child(description(
            "chau7-optim is a built-in binary that intercepts command output and compresses it for LLM consumption. For example, `cat large_file.rs` strips comments and blank lines, `git diff` condenses to changed lines only, and `cargo build` filters out Compiling... progress, keeping only errors.",
            chrome,
        ))
        .child(mono(short(&paths.optimizer()), chrome))
        .child(bold("Wrapper Scripts"))
        .child(description(
            "When active, Chau7 Next prepends a directory of wrapper scripts to your PATH. Each wrapper shadows a real binary (cat, ls, git, etc.) and decides whether to optimize:",
            chrome,
        ))
        .child(mono(format!("{}/", short(&paths.wrapper_dir)), chrome))
        .child(bold("Decision flow for each command:"))
        .child(flow_row(
            "1.",
            "Check for a per-session flag file - if absent, exec the real binary directly (zero overhead)",
            chrome,
        ))
        .child(flow_row(
            "2.",
            "If the flag is set and the optimizer is installed, route through chau7-optim for filtered output",
            chrome,
        ))
        .child(flow_row(
            "3.",
            "Special case: cat on .md files routes through chau7-md for ANSI-formatted markdown",
            chrome,
        ))
        .child(flow_row(
            "4.",
            "Fallback: exec the real binary unmodified",
            chrome,
        ))
        .child(description("Per-session flag files:", chrome))
        .child(mono(format!("{}/<SESSION_ID>", short(&paths.flag_dir)), chrome))
        .child(description(
            "All flag files and wrappers are cleaned up when the app quits or when the mode is set to Off.",
            chrome,
        ))
}
