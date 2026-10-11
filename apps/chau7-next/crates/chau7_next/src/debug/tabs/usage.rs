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
use gpui::{AnyElement, App, IntoElement, div, prelude::*};
pub fn register(cx: &mut App) {
    register_panel(
        cx,
        Panel::new("usage", "Usage", |_, cx| render(cx)).auto_refresh(),
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
                    if view.capture_installed {
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
    if let Some(dashboard) = latency.dashboard {
        timing = timing.child(ui::caption(
            format!(
                "{} interactions · {}",
                numbers::integer(dashboard.interaction_count as i64),
                dashboard.metric_kind.label()
            ),
            chrome,
        ));
        if let Some(a) = dashboard.aggregate {
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
        let max_latency = dashboard
            .buckets
            .iter()
            .filter_map(|b| b.aggregate.as_ref().map(|a| a.average_latency_ms))
            .fold(0_f64, f64::max);
        let max_interactions = dashboard
            .buckets
            .iter()
            .map(|b| b.interactions)
            .max()
            .unwrap_or(0);
        for bucket in dashboard.buckets {
            let latency_width = bucket
                .aggregate
                .as_ref()
                .map(|a| {
                    if max_latency > 0. {
                        180. * a.average_latency_ms / max_latency
                    } else {
                        0.
                    }
                })
                .unwrap_or(0.);
            let activity_width = if max_interactions > 0 {
                180. * bucket.interactions as f64 / max_interactions as f64
            } else {
                0.
            };
            timing = timing.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        div()
                            .h(gpui::px(4.))
                            .w(gpui::px(latency_width as f32))
                            .bg(chrome.accent),
                    )
                    .child(
                        div()
                            .h(gpui::px(4.))
                            .w(gpui::px(activity_width as f32))
                            .bg(chrome.text_muted),
                    ),
            );

            let value = bucket
                .aggregate
                .map(|a| {
                    format!(
                        "{} · P95 {} ({} samples)",
                        chau7_next_core::proxy::format_latency(a.average_latency_ms.round() as i64),
                        chau7_next_core::proxy::format_latency(a.p95_latency_ms),
                        numbers::integer(a.count as i64)
                    )
                })
                .unwrap_or_else(|| "Latency unavailable".into());
            timing = timing.child(
                div()
                    .flex()
                    .justify_between()
                    .text_xs()
                    .child(bucket.label)
                    .child(format!(
                        "{} interactions · {value}",
                        numbers::integer(bucket.interactions as i64)
                    )),
            );
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
        for s in stats {
            group = group.child(ui::caption(
                format!(
                    "{}: {} tokens · {}",
                    s.provider,
                    numbers::integer(s.total_billable_tokens()),
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
    }
    ui::page("usage-page", page).into_any_element()
}
