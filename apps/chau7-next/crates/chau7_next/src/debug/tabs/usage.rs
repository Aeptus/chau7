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
                .on_click(|_, _, cx| usage::refresh(cx)),
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
                .on_click(move |_, _, cx| usage::set_capture(!view.capture_installed, cx)),
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
    if let Some(recorder) = crate::telemetry::recorder(cx) {
        let stats = recorder
            .store()
            .consumption_per_provider(Some(chrono::Utc::now() - chrono::Duration::minutes(10)));
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
