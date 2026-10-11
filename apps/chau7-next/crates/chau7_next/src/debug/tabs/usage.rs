//! Current provider quota status, explicit capture controls and consumption evidence.
use crate::{
    debug::{
        registry::{Panel, register_panel},
        ui,
    },
    settings::Settings,
    telemetry::usage,
    theme::Chrome,
};
use chau7_next_core::l10n::numbers;
use chau7_next_core::telemetry::latency::{Aggregate, LatencyDashboard};
use gpui::{AnyElement, App, ClipboardItem, IntoElement, div, prelude::*};
pub fn register(cx: &mut App) {
    let first_open = std::cell::Cell::new(true);
    register_panel(
        cx,
        Panel::new("usage", "Usage", move |_, cx| {
            if first_open.replace(false) {
                usage::refresh(cx);
                usage::refresh_latency(cx);
            }
            render(cx)
        })
        .auto_refresh(),
    );
}
fn render(cx: &mut App) -> AnyElement {
    let chrome = Chrome::get(cx);
    let view = usage::view(cx);
    let settings = Settings::get(cx).general.clone();
    let latency = usage::latency_view(cx);
    let mut page = div().flex().flex_col().gap_3();
    page = page.child(
        div()
            .flex()
            .gap_2()
            .child(
                ui::button(
                    "usage-refresh",
                    if view.refreshing {
                        "Refreshing…"
                    } else {
                        "Refresh"
                    },
                    chrome,
                )
                .on_click(|_, _, cx| {
                    usage::refresh(cx);
                    usage::refresh_latency(cx);
                }),
            )
            .child(
                ui::button(
                    "usage-monitor",
                    if settings.usage_monitoring {
                        "Disable monitoring"
                    } else {
                        "Enable monitoring"
                    },
                    chrome,
                )
                .on_click(move |_, _, cx| {
                    crate::settings_window::update(cx, |s| {
                        s.general.usage_monitoring = !s.general.usage_monitoring
                    });
                    usage::refresh(cx);
                }),
            )
            .child(
                ui::button(
                    "usage-capture",
                    if view.capture_working {
                        "Updating capture…"
                    } else if view.capture_installed {
                        "Uninstall Claude capture"
                    } else {
                        "Install Claude capture"
                    },
                    chrome,
                )
                .on_click(move |_, _, cx| {
                    if !view.capture_working {
                        usage::set_capture(!view.capture_installed, cx);
                    }
                }),
            ),
    );
    page = page.child(
        ui::button(
            "usage-warnings",
            if settings.usage_quota_warnings {
                "Disable quota warnings"
            } else {
                "Enable quota warnings"
            },
            chrome,
        )
        .on_click(|_, _, cx| {
            crate::settings_window::update(cx, |s| {
                s.general.usage_quota_warnings = !s.general.usage_quota_warnings
            });
            usage::refresh(cx);
        }),
    );
    page = page.child(ui::caption(
        format!(
            "Claude capture: {} · Monitoring: {} · Quota warnings: {}",
            if view.capture_working {
                "Updating"
            } else if view.capture_installed {
                "Installed"
            } else {
                "Not installed"
            },
            if settings.usage_monitoring {
                "Enabled"
            } else {
                "Disabled"
            },
            if settings.usage_quota_warnings {
                "Enabled"
            } else {
                "Disabled"
            }
        ),
        chrome,
    ));
    let mut formats = div()
        .flex()
        .flex_wrap()
        .gap_2()
        .child(ui::caption("Number format", chrome));
    for format in numbers::RegionalNumberFormat::ALL {
        formats = formats.child(
            ui::chip(
                format!("usage-format-{}", format.id()),
                format!("{} ({})", format.display_name(), format.example()),
                format == settings.regional_number_format,
                chrome.accent,
                chrome,
            )
            .on_click(move |_, _, cx| {
                crate::settings_window::update(cx, |s| s.general.regional_number_format = format)
            }),
        );
    }
    page = page.child(formats).child(
        ui::button(
            "usage-copy-diagnostics",
            "Copy usage diagnostics JSON",
            chrome,
        )
        .on_click(|_, _, cx| {
            if let Ok(json) = serde_json::to_string_pretty(&usage::diagnostics(cx)) {
                cx.write_to_clipboard(ClipboardItem::new_string(json));
            }
        }),
    );
    if let Some(error) = view.last_error {
        page = page.child(ui::caption(format!("Capture error: {error}"), chrome));
    }
    if let Some(at) = view.last_refresh {
        page = page.child(ui::caption(
            format!(
                "Last refreshed: {}",
                at.with_timezone(&chrono::Local).format("%H:%M:%S")
            ),
            chrome,
        ));
    }
    let mut health = ui::group("Provider status", chrome);
    let statuses = usage::provider_health(cx);
    if statuses.is_empty() {
        health = health.child(ui::caption(
            "Status unavailable. No recent successful provider observation.",
            chrome,
        ));
    }
    for snapshot in statuses {
        let url = snapshot.source_url.clone();
        health = health.child(
            div()
                .flex()
                .justify_between()
                .text_xs()
                .child(format!(
                    "{} · {:?}: {}",
                    snapshot.provider, snapshot.severity, snapshot.summary
                ))
                .child(
                    ui::button(
                        format!("provider-health-{}", snapshot.provider),
                        "Open status",
                        chrome,
                    )
                    .on_click(move |_, _, cx| cx.open_url(&url)),
                ),
        );
    }
    page = page.child(health);
    let mut timing = ui::group("Provider response latency", chrome);
    let mut ranges = div().flex().flex_wrap().gap_2();
    for range in chau7_next_core::telemetry::latency::TimeRange::ALL {
        ranges = ranges.child(
            ui::button(
                format!("latency-range-{:?}", range),
                format!(
                    "{}{}",
                    if range == latency.range { "✓ " } else { "" },
                    range.label()
                ),
                chrome,
            )
            .on_click(move |_, _, cx| usage::select_latency(Some(range), None, None, None, cx)),
        );
    }
    timing = timing.child(ranges);
    let mut controls = div().flex().flex_wrap().gap_2();
    for metric in [
        chau7_next_core::telemetry::latency::MetricKind::ApiRequest,
        chau7_next_core::telemetry::latency::MetricKind::FirstResponse,
    ] {
        controls = controls.child(
            ui::button(
                format!("latency-metric-{:?}", metric),
                format!(
                    "{}{}",
                    if metric == latency.metric { "✓ " } else { "" },
                    metric.label()
                ),
                chrome,
            )
            .on_click(move |_, _, cx| usage::select_latency(None, None, Some(metric), None, cx)),
        );
    }
    for bucket in chau7_next_core::telemetry::latency::BucketKind::ALL {
        controls = controls.child(
            ui::button(
                format!("latency-bucket-{:?}", bucket),
                format!(
                    "{}{}",
                    if bucket == latency.bucket { "✓ " } else { "" },
                    bucket.label()
                ),
                chrome,
            )
            .on_click(move |_, _, cx| usage::select_latency(None, Some(bucket), None, None, cx)),
        );
    }
    timing = timing.child(controls);
    let mut providers = div().flex().flex_wrap().gap_2();
    for provider in &latency.providers {
        let provider = provider.clone();
        let selected = latency.selected_provider.as_ref() == Some(&provider);
        providers = providers.child(
            ui::button(
                format!("latency-provider-{provider}"),
                format!("{}{provider}", if selected { "✓ " } else { "" }),
                chrome,
            )
            .on_click(move |_, _, cx| {
                usage::select_latency(None, None, None, Some(provider.clone()), cx)
            }),
        );
    }
    timing = timing.child(providers);
    if let Some(dashboard) = &latency.dashboard {
        let coverage = usage::LatencyCoverage::from_dashboard(dashboard);
        timing = timing.child(ui::caption(
            format!(
                "Coverage: {} latency samples / {} captured interactions · {}",
                numbers::integer(coverage.sampled_count as i64),
                numbers::integer(coverage.interaction_count as i64),
                coverage
                    .fraction
                    .map(numbers::percent)
                    .unwrap_or_else(|| "Coverage unavailable".into())
            ),
            chrome,
        ));
        timing = timing.child(ui::caption("Latency buckets use P50 (median); P95 shows the slower tail. Activity uses all captured interactions; latency uses the subset with valid evidence. Avg can be affected by streaming and outliers.", chrome));
        if let Some(a) = &dashboard.aggregate {
            timing = timing.child(ui::caption(
                format!(
                    "{} samples · Avg {} · P50 {} · P95 {} · Min {} · Max {}",
                    numbers::integer(a.count as i64),
                    chau7_next_core::proxy::format_latency(a.average_latency_ms.round() as i64),
                    chau7_next_core::proxy::format_latency(a.p50_latency_ms),
                    chau7_next_core::proxy::format_latency(a.p95_latency_ms),
                    chau7_next_core::proxy::format_latency(a.min_latency_ms),
                    chau7_next_core::proxy::format_latency(a.max_latency_ms)
                ),
                chrome,
            ));
        } else {
            timing = timing.child(ui::caption(
                "Latency unavailable for this metric and range.",
                chrome,
            ));
        }
        if latency.bucket_dashboards.is_empty() {
            timing = timing.child(render_buckets(dashboard, chrome));
        } else {
            for bucket in &latency.bucket_dashboards {
                timing = timing.child(
                    ui::group(
                        format!("{} · P50 latency and activity", bucket.kind.label()),
                        chrome,
                    )
                    .child(render_buckets(&bucket.dashboard, chrome)),
                );
            }
        }
    } else {
        timing = timing.child(ui::caption("No observed response latency yet.", chrome));
    }
    if let Some(at) = latency.refreshed_at {
        timing=timing.child(ui::caption(format!("Updated {} · Terminal timing is an estimate; transcript rounds replace it. API response uses TTFT when observed.",at.with_timezone(&chrono::Local).format("%H:%M:%S")),chrome));
    }
    page = page.child(timing);
    if let Some(evidence) = latency.evidence {
        let mut group = ui::group("Reconciled usage evidence", chrome);
        group = group.child(ui::caption(
            format!(
                "{} retained observations · {} reconciled groups · {} unassigned requests",
                numbers::integer(evidence.retained_records as i64),
                numbers::integer(evidence.reconciled_groups as i64),
                evidence
                    .unassigned_requests
                    .map(|n| numbers::integer(n as i64))
                    .unwrap_or_else(|| "Unavailable".into())
            ),
            chrome,
        ));
        group = group.child(ui::caption(
            format!(
                "{} billable tokens · {} · {} groups without cost",
                if evidence.token_groups > 0 {
                    numbers::integer(evidence.token_usage.total_billable_tokens())
                } else {
                    "Unavailable".into()
                },
                evidence
                    .total_cost_usd
                    .map(numbers::cost_precise)
                    .unwrap_or_else(|| "Cost unavailable".into()),
                numbers::integer(evidence.missing_cost_groups as i64)
            ),
            chrome,
        ));
        if evidence.incomplete_window {
            group=group.child(ui::caption("Incomplete evidence window: retained query budget exceeded. Totals describe only the displayed retained observations.",chrome));
        }
        for evidence in evidence.groups {
            group = group.child(ui::caption(
                format!(
                    "{} · {} · {} · {} tokens · {} · {} alternatives",
                    evidence.scope,
                    evidence.source,
                    evidence.confidence,
                    evidence
                        .tokens
                        .map(numbers::integer)
                        .unwrap_or_else(|| "Unavailable".into()),
                    evidence
                        .cost_usd
                        .map(numbers::cost_precise)
                        .unwrap_or_else(|| "Cost unavailable".into()),
                    numbers::integer(evidence.alternatives as i64)
                ),
                chrome,
            ));
        }
        page = page.child(group);
    }

    if view.providers.is_empty() {
        page=page.child(ui::empty_note("No provider quota snapshot yet. Enable monitoring for Codex or install Claude capture. Unknown quota remains unavailable.",chrome));
    }
    for provider in view.providers {
        let mut group = ui::group(
            format!(
                "{} · {}",
                provider.snapshot.provider,
                provider
                    .snapshot
                    .plan_type
                    .as_deref()
                    .unwrap_or("Plan unavailable")
            ),
            chrome,
        );
        if let Some(credits) = provider.snapshot.credits {
            group = group.child(ui::caption(
                format!("Credits: {}", numbers::decimal(credits, 2)),
                chrome,
            ));
        }
        for warning in &provider.active_warnings {
            group = group.child(ui::caption(
                format!("{} · {}", warning.window.id, warning_label(warning.kind)),
                chrome,
            ));
        }
        for metric in provider.metrics {
            let window = &metric.window;
            group = group.child(
                div()
                    .flex()
                    .justify_between()
                    .text_xs()
                    .child(window.id.clone())
                    .child(format!(
                        "{} remaining · {} used",
                        numbers::percent(window.remaining() / 100.),
                        numbers::percent(window.used_percent / 100.)
                    )),
            );
            if let Some(fraction) = quota_progress(window.used_percent) {
                group = group.child(
                    div()
                        .h(gpui::px(5.))
                        .w(gpui::px(180.))
                        .bg(chrome.tab_bg)
                        .child(
                            div()
                                .h_full()
                                .w(gpui::px(180. * fraction as f32))
                                .bg(chrome.accent),
                        ),
                );
            }
            if let Some(minutes) = metric.remaining_minutes {
                group = group.child(ui::caption(
                    format!("Reset in {}", minutes_label(minutes)),
                    chrome,
                ));
            }
            if let Some(sustainable) = metric.sustainable_percent_per_minute {
                group = group.child(ui::caption(
                    format!("Sustainable: {}%/min", numbers::decimal(sustainable, 2)),
                    chrome,
                ));
            }
            if let Some(reset) = window.resets_at {
                group = group.child(ui::caption(
                    format!(
                        "Resets {}",
                        reset.with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M")
                    ),
                    chrome,
                ));
            }
            if let Some(burn) = metric.recent_burn_percent_per_minute {
                group = group.child(ui::caption(
                    format!(
                        "Recent burn: {}%/min{}",
                        numbers::decimal(burn, 2),
                        if metric.is_unsustainable {
                            " · Above sustainable pace"
                        } else {
                            ""
                        }
                    ),
                    chrome,
                ));
            }
        }
        group = group.child(ui::caption(
            format!(
                "Source: {} · Captured {}",
                provider.snapshot.source,
                provider
                    .snapshot
                    .captured_at
                    .with_timezone(&chrono::Local)
                    .format("%Y-%m-%d %H:%M")
            ),
            chrome,
        ));
        page = page.child(group);
    }
    if let Some(stats) = view.recent_consumption {
        let mut group = ui::group("Recent run consumption (10 minutes)", chrome);
        if stats.is_empty() {
            group = group.child(ui::caption("No captured runs in this interval.", chrome));
        }
        for s in stats {
            let observed = s.token_observed_run_count.unwrap_or(0);
            group = group.child(ui::caption(
                format!(
                    "{} · {} runs with token evidence / {} captured runs",
                    s.provider,
                    numbers::integer(observed),
                    numbers::integer(s.run_count)
                ),
                chrome,
            ));
            if observed > 0 {
                group = group.child(ui::caption(format!("{} runs · Input {} · Cache write {} · Cache read {} · Other cached {} · Output {} · Reasoning {}",
                numbers::integer(s.run_count), numbers::integer(s.total_input_tokens),
                numbers::integer(s.total_cache_creation_input_tokens), numbers::integer(s.total_cache_read_input_tokens),
                numbers::integer(s.uncategorized_cached_input_tokens()), numbers::integer(s.total_output_tokens),
                numbers::integer(s.total_reasoning_output_tokens)), chrome));
            } else {
                group = group.child(ui::caption(
                    "Token categories unavailable: no observed token counters.",
                    chrome,
                ));
            }
            group = group.child(ui::caption(
                format!(
                    "{}: {} · {}",
                    s.provider,
                    if observed > 0 {
                        format!(
                            "{} observed tokens",
                            numbers::integer(s.total_billable_tokens())
                        )
                    } else {
                        "Tokens unavailable".into()
                    },
                    crate::l10n::run_cost_label(
                        s.total_cost_usd,
                        s.priced_run_count,
                        s.missing_cost_run_count
                    )
                ),
                chrome,
            ));
        }
        page = page.child(group);
    } else {
        page = page.child(ui::caption(
            "Recent run consumption unavailable until history is refreshed.",
            chrome,
        ));
    }
    ui::page("usage-page", page).into_any_element()
}

fn quota_progress(used_percent: f64) -> Option<f64> {
    used_percent
        .is_finite()
        .then(|| (used_percent / 100.).clamp(0., 1.))
}
fn minutes_label(minutes: f64) -> String {
    if minutes >= 120. {
        format!("{}h", numbers::decimal(minutes / 60., 1))
    } else {
        format!("{}m", numbers::integer(minutes.round() as i64))
    }
}
fn warning_label(kind: &str) -> &str {
    match kind {
        "remaining5" => "5% or less remaining",
        "remaining10" => "10% or less remaining",
        "remaining20" => "20% or less remaining",
        "unsustainablePace" => "Unsustainable pace",
        other => other,
    }
}
fn median_bar_width(aggregate: &Aggregate, max_p50_ms: i64) -> f32 {
    let p50_ms = aggregate.p50_latency_ms;
    if max_p50_ms > 0 {
        (180. * p50_ms.max(0) as f64 / max_p50_ms as f64).clamp(0., 180.) as f32
    } else {
        0.
    }
}
fn render_buckets(dashboard: &LatencyDashboard, chrome: Chrome) -> gpui::Div {
    let mut charts = div().flex().flex_col().gap_2();
    let max_p50 = dashboard
        .buckets
        .iter()
        .filter_map(|b| b.aggregate.as_ref().map(|a| a.p50_latency_ms))
        .max()
        .unwrap_or(0);
    let max_activity = dashboard
        .buckets
        .iter()
        .map(|b| b.interactions)
        .max()
        .unwrap_or(0);
    for bucket in &dashboard.buckets {
        let latency_width = bucket
            .aggregate
            .as_ref()
            .map(|a| median_bar_width(a, max_p50))
            .unwrap_or(0.);
        let activity_width = if max_activity > 0 {
            180. * bucket.interactions as f32 / max_activity as f32
        } else {
            0.
        };
        let latency = bucket
            .aggregate
            .as_ref()
            .map(|a| {
                format!(
                    "P50 {} · P95 {} · {} samples",
                    chau7_next_core::proxy::format_latency(a.p50_latency_ms),
                    chau7_next_core::proxy::format_latency(a.p95_latency_ms),
                    numbers::integer(a.count as i64)
                )
            })
            .unwrap_or_else(|| "Latency unavailable".into());
        charts = charts
            .child(
                div()
                    .flex()
                    .justify_between()
                    .text_xs()
                    .child(bucket.label.clone())
                    .child(format!(
                        "{} interactions · {latency}",
                        numbers::integer(bucket.interactions as i64)
                    )),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        div()
                            .h(gpui::px(4.))
                            .w(gpui::px(latency_width))
                            .bg(chrome.accent),
                    )
                    .child(
                        div()
                            .h(gpui::px(4.))
                            .w(gpui::px(activity_width))
                            .bg(chrome.text_muted),
                    ),
            );
    }
    charts
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn quota_progress_keeps_unknown_distinct_from_observed_zero() {
        assert_eq!(quota_progress(f64::NAN), None);
        assert_eq!(quota_progress(f64::INFINITY), None);
        assert_eq!(quota_progress(0.), Some(0.));
        assert_eq!(quota_progress(-5.), Some(0.));
        assert_eq!(quota_progress(140.), Some(1.));
    }
    #[test]
    fn latency_bars_use_median_and_bound_width() {
        let mut aggregate = Aggregate {
            count: 3,
            average_latency_ms: 1000.,
            p50_latency_ms: 10,
            p95_latency_ms: 3000,
            min_latency_ms: 10,
            max_latency_ms: 3000,
        };
        assert_eq!(median_bar_width(&aggregate, 100), 18.);
        aggregate.average_latency_ms = 10000.;
        assert_eq!(median_bar_width(&aggregate, 100), 18.);
        aggregate.p50_latency_ms = 0;
        assert_eq!(median_bar_width(&aggregate, 0), 0.);
        aggregate.p50_latency_ms = -1;
        assert_eq!(median_bar_width(&aggregate, 100), 0.);
        aggregate.p50_latency_ms = 150;
        assert_eq!(median_bar_width(&aggregate, 100), 180.);
    }
}
