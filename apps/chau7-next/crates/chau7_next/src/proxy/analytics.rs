//! Current Swift API Analytics charts, loaded off the UI thread with one request
//! in flight and at most one queued refresh. Closing the window drops its timer.
use crate::{debug::ui, settings::Settings, theme::Chrome, workspace::AppData};
use chau7_next_core::{
    l10n::numbers,
    proxy::analytics::{self as core, AnalyticsRange, Dashboard, Measured, Metrics, TrendMetric},
};
use gpui::{
    AnyWindowHandle, App, ClipboardItem, Context, Global, Hsla, IntoElement, PathBuilder, Render,
    Task, WeakEntity, Window, WindowBounds, WindowOptions, canvas, div, point, prelude::*, px,
    size,
};
use gpui_kit::component::TitleBar;
use std::time::{Duration, Instant};

#[derive(Default)]
struct WindowHandle(Option<(AnyWindowHandle, WeakEntity<ApiAnalyticsView>)>);
impl Global for WindowHandle {}
#[derive(Default)]
struct RefreshGate {
    in_flight: bool,
    queued: bool,
}
impl RefreshGate {
    fn request(&mut self) -> bool {
        if self.in_flight {
            self.queued = true;
            false
        } else {
            self.in_flight = true;
            true
        }
    }
    fn finish(&mut self) -> bool {
        self.in_flight = false;
        std::mem::take(&mut self.queued)
    }
}
pub fn open(cx: &mut App) {
    if let Some((handle, view)) = cx.try_global::<WindowHandle>().and_then(|h| h.0.clone())
        && let Some(view) = view.upgrade()
        && handle
            .update(cx, |_, window, cx| {
                window.activate_window();
                view.update(cx, |view, cx| view.refresh(cx));
            })
            .is_ok()
    {
        return;
    }
    let bounds = gpui::Bounds::centered(None, size(px(940.), px(780.)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(620.), px(420.))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title(&crate::l10n::tr("API Analytics"));
        cx.new(ApiAnalyticsView::new)
    }) {
        Ok((handle, view)) => cx.set_global(WindowHandle(Some((handle, view.downgrade())))),
        Err(e) => log::error!("API Analytics window: {e}"),
    }
}
/// Existing proxy IPC delivery calls this once per recorded-call batch. Like
/// Swift, notifications are throttled to two seconds; the timer reconciles later.
pub fn call_recorded(cx: &mut App) {
    if let Some(view) = cx
        .try_global::<WindowHandle>()
        .and_then(|h| h.0.as_ref())
        .and_then(|(_, view)| view.upgrade())
    {
        view.update(cx, |view, cx| {
            if view
                .last_completed
                .is_none_or(|at| at.elapsed() >= Duration::from_secs(2))
            {
                view.refresh(cx);
            }
        });
    }
}
struct ApiAnalyticsView {
    range: AnalyticsRange,
    metric: TrendMetric,
    data: Option<Dashboard>,
    error: Option<String>,
    gate: RefreshGate,
    last_completed: Option<Instant>,
    _refresh: Task<()>,
}
impl ApiAnalyticsView {
    fn new(cx: &mut Context<Self>) -> Self {
        let timer = crate::observability::register_timer(
            cx,
            "analytics.api_dashboard",
            "API Analytics window refresh",
            "analytics",
            30_000,
        );
        let refresh = cx.spawn(async move |this, cx| {
            let _timer = timer;
            loop {
                cx.background_executor()
                    .timer(Duration::from_secs(30))
                    .await;
                if this.update(cx, |this, cx| this.refresh(cx)).is_err() {
                    break;
                }
            }
        });
        let mut view = Self {
            range: AnalyticsRange::default(),
            metric: TrendMetric::default(),
            data: None,
            error: None,
            gate: RefreshGate::default(),
            last_completed: None,
            _refresh: refresh,
        };
        view.refresh(cx);
        view
    }
    fn refresh(&mut self, cx: &mut Context<Self>) {
        if !self.gate.request() {
            cx.notify();
            return;
        }
        let range = self.range;
        let path = cx.global::<AppData>().root.proxy_db();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { core::load(&path, range) })
                .await;
            let _ = this.update(cx, |this, cx| {
                let queued = this.gate.finish();
                this.last_completed = Some(Instant::now());
                if this.range == range {
                    match result {
                        Ok(data) => {
                            this.data = Some(data);
                            this.error = None;
                        }
                        Err(error) => this.error = Some(error),
                    }
                }
                if queued || this.range != range {
                    this.refresh(cx);
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
}
fn color(provider: &str) -> Hsla {
    match provider {
        "anthropic" => gpui::hsla(0.76, 0.65, 0.60, 1.),
        "openai" => gpui::hsla(0.40, 0.65, 0.48, 1.),
        "google" => gpui::hsla(0.57, 0.75, 0.57, 1.),
        other => gpui::hsla(
            (other
                .bytes()
                .fold(0u32, |h, b| h.wrapping_mul(31).wrapping_add(u32::from(b)))
                % 360) as f32
                / 360.,
            0.5,
            0.58,
            1.,
        ),
    }
}
fn token_label(metric: &Measured<i64>) -> String {
    metric
        .value
        .map(numbers::integer)
        .unwrap_or_else(|| "Unavailable".into())
}
fn cost_label(metrics: &Metrics) -> String {
    metrics
        .recorded_cost_usd
        .value
        .map(|value| {
            let value = numbers::cost_precise(value);
            if metrics.recorded_cost_usd.observed_calls < metrics.calls {
                format!("{value} partial")
            } else {
                value
            }
        })
        .unwrap_or_else(|| "Cost unavailable".into())
}
fn latency_label(metric: &Measured<f64>) -> String {
    metric
        .value
        .map(|v| chau7_next_core::proxy::format_latency(v.round() as i64))
        .unwrap_or_else(|| "Unavailable".into())
}
fn token_breakdown(metrics: &Metrics) -> String {
    format!(
        "Input {} · Cache write {} · Cache read {} · Output {} · Reasoning {}",
        token_label(&metrics.input),
        token_label(&metrics.cache_write),
        token_label(&metrics.cache_read),
        token_label(&metrics.output),
        token_label(&metrics.reasoning)
    )
}
fn coverage(metrics: &Metrics) -> String {
    format!(
        "{} calls · Tokens {}/{} · Input/output {}/{} · Recorded cost {}/{} · Latency {}/{} · Status {}/{} · Dates {}/{}",
        numbers::integer(metrics.calls as i64),
        numbers::integer(metrics.billable_tokens.observed_calls as i64),
        numbers::integer(metrics.calls as i64),
        numbers::integer(metrics.complete_token_calls as i64),
        numbers::integer(metrics.calls as i64),
        numbers::integer(metrics.recorded_cost_usd.observed_calls as i64),
        numbers::integer(metrics.calls as i64),
        numbers::integer(metrics.average_latency_ms.observed_calls as i64),
        numbers::integer(metrics.calls as i64),
        numbers::integer(metrics.status_observed_calls as i64),
        numbers::integer(metrics.calls as i64),
        numbers::integer(metrics.timestamp_observed_calls as i64),
        numbers::integer(metrics.calls as i64)
    )
}
fn stat(title: &str, value: String, chrome: Chrome) -> gpui::Div {
    div()
        .flex_1()
        .flex()
        .flex_col()
        .gap_1()
        .min_w(px(120.))
        .p_3()
        .rounded_lg()
        .bg(chrome.tab_bg)
        .child(
            div()
                .text_lg()
                .font_weight(gpui::FontWeight::BOLD)
                .child(value),
        )
        .child(ui::caption(title.to_string(), chrome))
}
fn trend_chart(data: &Dashboard, metric: TrendMetric, chrome: Chrome) -> gpui::Div {
    let maximum = data
        .daily
        .iter()
        .filter_map(|p| core::trend_value(p, metric))
        .fold(0., f64::max);
    let mut bars = div().flex().items_end().gap_2().h(px(150.));
    for point in &data.daily {
        let value = core::trend_value(point, metric);
        let label = match metric {
            TrendMetric::Cost => cost_label(&point.metrics),
            TrendMetric::Tokens => token_label(&point.metrics.billable_tokens),
        };
        let bar = core::normalized_bar(value, maximum)
            .map(|fraction| {
                div()
                    .w(px(24.))
                    .h(px((fraction * 110.).max(2.)))
                    .rounded_sm()
                    .bg(chrome.accent.opacity(0.65))
            })
            .unwrap_or_else(|| {
                div()
                    .w(px(24.))
                    .h(px(2.))
                    .bg(chrome.text_muted.opacity(0.2))
            });
        bars = bars.child(
            div()
                .flex_none()
                .flex()
                .flex_col()
                .items_center()
                .justify_end()
                .gap_1()
                .w(px(74.))
                .child(div().text_size(px(9.)).child(label))
                .child(bar)
                .child(
                    div()
                        .text_size(px(9.))
                        .child(point.date.get(5..).unwrap_or(&point.date).to_string()),
                ),
        );
    }
    let mut group = ui::group(
        match data.range {
            AnalyticsRange::AllTime => "Daily Trends (Last 90 Days)",
            AnalyticsRange::Today => "Daily Trends (Last Day)",
            _ => "Daily Trends",
        },
        chrome,
    );
    if data.daily.is_empty() {
        group = group.child(ui::caption("No captured calls for this period.", chrome));
    } else {
        group = group.child(div().id("api-trend-scroll").overflow_x_scroll().child(bars));
    }
    group.child(ui::caption("Bars use recorded cost or canonical metered tokens. Unknown values are unavailable; totals can be partial when evidence is incomplete.",chrome))
}
fn provider_chart(data: &Dashboard, chrome: Chrome) -> gpui::Div {
    let maximum = data
        .providers
        .iter()
        .filter_map(|p| p.metrics.recorded_cost_usd.value)
        .fold(0., f64::max);
    let mut rows = div().flex_1().flex().flex_col().gap_2();
    for provider in &data.providers {
        let bar = core::normalized_bar(provider.metrics.recorded_cost_usd.value, maximum)
            .map(|f| {
                div()
                    .h(px(12.))
                    .w(px(220. * f))
                    .rounded_sm()
                    .bg(color(&provider.provider).opacity(0.65))
            })
            .unwrap_or_else(|| div().h(px(12.)).w(px(0.)));
        rows = rows.child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .text_xs()
                        .child(provider.provider.clone())
                        .child(format!(
                            "{} · {} tokens",
                            cost_label(&provider.metrics),
                            token_label(&provider.metrics.billable_tokens)
                        )),
                )
                .child(bar)
                .child(ui::caption(coverage(&provider.metrics), chrome)),
        );
    }
    let segments = core::cost_segments(&data.providers);
    let mut group = ui::group("Provider Breakdown", chrome);
    if data.providers.is_empty() {
        return group.child(ui::caption("No provider data in this range.", chrome));
    }
    if segments.is_empty() {
        return group.child(rows).child(ui::caption(
            "No positive recorded cost for a pie chart.",
            chrome,
        ));
    }
    let pie = canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let center = bounds.center();
            let radius = 50.;
            for segment in segments {
                let mut path = PathBuilder::fill();
                path.move_to(center);
                let steps = ((segment.end - segment.start) * 96.).ceil().max(2.) as usize;
                for index in 0..=steps {
                    let angle = std::f64::consts::TAU
                        * (segment.start
                            + (segment.end - segment.start) * index as f64 / steps as f64)
                        - std::f64::consts::FRAC_PI_2;
                    path.line_to(point(
                        center.x + px((radius * angle.cos()) as f32),
                        center.y + px((radius * angle.sin()) as f32),
                    ));
                }
                path.close();
                if let Ok(path) = path.build() {
                    window.paint_path(path, color(&segment.provider));
                }
            }
        },
    )
    .size(px(120.));
    group = group.child(div().flex().gap_4().child(rows).child(pie));
    group.child(ui::caption("Pie shares cover recorded positive cost only; calls without cost evidence have no invented slice.",chrome))
}
fn model_table(data: &Dashboard, chrome: Chrome) -> gpui::Div {
    let maximum = data
        .models
        .iter()
        .filter_map(|m| m.metrics.recorded_cost_usd.value)
        .fold(0., f64::max);
    let mut group = ui::group("Model Breakdown (Top 15 by Recorded Cost)", chrome);
    if data.models.is_empty() {
        return group.child(ui::caption("No model data in this range.", chrome));
    }
    for model in data.models.iter().take(15) {
        let bar = core::normalized_bar(model.metrics.recorded_cost_usd.value, maximum)
            .map(|f| {
                div()
                    .h(px(6.))
                    .w(px(180. * f))
                    .rounded_sm()
                    .bg(color(&model.provider).opacity(0.4))
            })
            .unwrap_or_else(|| div().h(px(6.)).w(px(0.)));
        group = group.child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .text_xs()
                        .child(format!(
                            "{} · {}",
                            model.provider,
                            model.model.as_deref().unwrap_or("(unknown)")
                        ))
                        .child(format!(
                            "{} calls · {} metered · {}",
                            numbers::integer(model.metrics.calls as i64),
                            token_label(&model.metrics.billable_tokens),
                            cost_label(&model.metrics)
                        )),
                )
                .child(bar)
                .child(ui::caption(token_breakdown(&model.metrics), chrome))
                .child(ui::caption(coverage(&model.metrics), chrome)),
        );
    }
    group
}
fn recent_table(data: &Dashboard, chrome: Chrome) -> gpui::Div {
    let mut group = ui::group("Recent API Calls (Latest 30, All Time)", chrome);
    if data.recent.is_empty() {
        return group.child(ui::caption("No calls recorded.", chrome));
    }
    for call in &data.recent {
        let status = call
            .status_code
            .map(|s| s.to_string())
            .unwrap_or_else(|| "Status unavailable".into());
        let at = call
            .timestamp
            .map(|at| {
                at.with_timezone(&chrono::Local)
                    .format("%Y-%m-%d %H:%M:%S")
                    .to_string()
            })
            .unwrap_or_else(|| "Timestamp unavailable".into());
        let success = call.status_code.map(|s| (200..300).contains(&s));
        let tone = match success {
            Some(true) => gpui::green(),
            Some(false) => chrome.danger,
            None => chrome.text_muted,
        };
        group = group.child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .text_xs()
                        .child(
                            div()
                                .text_color(tone)
                                .child(format!("{} · {} · {status}", call.provider, call.model)),
                        )
                        .child(format!(
                            "{} metered · {} · {} · {at}",
                            token_label(&call.metrics.billable_tokens),
                            cost_label(&call.metrics),
                            latency_label(&call.metrics.average_latency_ms)
                        )),
                )
                .child(ui::caption(token_breakdown(&call.metrics), chrome))
                .child(ui::caption(
                    format!(
                        "{} · Pricing {}",
                        call.endpoint.as_deref().unwrap_or("Endpoint unavailable"),
                        call.pricing_version
                            .as_deref()
                            .unwrap_or("version unavailable")
                    ),
                    chrome,
                )),
        );
        if let Some(error) = call.error_message.as_ref().filter(|e| !e.is_empty()) {
            group = group.child(ui::caption(error.clone(), chrome).text_color(chrome.danger));
        }
    }
    group
}
impl Render for ApiAnalyticsView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::panels(cx);
        let mut controls = div().flex().flex_wrap().gap_2();
        for range in AnalyticsRange::ALL {
            controls = controls.child(
                ui::chip(
                    format!("api-range-{range:?}"),
                    range.label(),
                    self.range == range,
                    chrome.accent,
                    chrome,
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.range = range;
                    this.refresh(cx);
                })),
            );
        }
        controls = controls.child(
            ui::button(
                "api-refresh",
                if self.gate.in_flight {
                    "Refreshing…"
                } else {
                    "Refresh"
                },
                chrome,
            )
            .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
        );
        controls=controls.child(ui::button("api-copy","Copy diagnostics JSON",chrome).on_click(cx.listener(|this,_,_,cx|{
            let value=serde_json::json!({"schema_version":1,"range":this.range,"trend_metric":this.metric,"dashboard":this.data,"error":this.error,"refreshing":this.gate.in_flight});
            if let Ok(json)=serde_json::to_string_pretty(&value){cx.write_to_clipboard(ClipboardItem::new_string(json));}
        })));
        let mut formats = div().flex().flex_wrap().gap_2();
        for format in numbers::RegionalNumberFormat::ALL {
            formats = formats.child(
                ui::chip(
                    format!("api-format-{}", format.id()),
                    format!("{} ({})", format.display_name(), format.example()),
                    format == Settings::get(cx).general.regional_number_format,
                    chrome.accent,
                    chrome,
                )
                .on_click(move |_, _, cx| {
                    crate::settings_window::update(cx, |s| {
                        s.general.regional_number_format = format
                    })
                }),
            );
        }
        let mut page = div()
            .flex()
            .flex_col()
            .gap_4()
            .child(controls)
            .child(formats);
        if let Some(error) = &self.error {
            page = page.child(ui::caption(error.clone(), chrome).text_color(chrome.danger));
        }
        if let Some(data) = &self.data {
            if self.range != data.range {
                page = page.child(ui::caption(
                    format!(
                        "Showing previous {} snapshot while {} loads.",
                        data.range.label(),
                        self.range.label()
                    ),
                    chrome,
                ));
            }
            page = page.child(ui::caption(
                format!(
                    "Snapshot {} · Read {}ms · {}",
                    data.captured_at
                        .with_timezone(&chrono::Local)
                        .format("%Y-%m-%d %H:%M:%S"),
                    numbers::decimal(data.load_elapsed_ms, 1),
                    coverage(&data.overall)
                ),
                chrome,
            ));
            let metrics = &data.overall;
            page = page.child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(stat("Recorded Cost", cost_label(metrics), chrome))
                    .child(stat(
                        "Metered Tokens",
                        token_label(&metrics.billable_tokens),
                        chrome,
                    ))
                    .child(stat(
                        "API Calls",
                        numbers::integer(metrics.calls as i64),
                        chrome,
                    ))
                    .child(stat(
                        "Avg Request Duration",
                        latency_label(&metrics.average_latency_ms),
                        chrome,
                    ))
                    .child(stat(
                        "Error Rate (Known Status)",
                        metrics
                            .error_rate()
                            .map(numbers::percent)
                            .unwrap_or_else(|| "Unavailable".into()),
                        chrome,
                    )),
            );
            page=page.child(ui::caption("Canonical counters are normalized per request; unknown token categories and costs stay unavailable. Legacy recorded values may lack pricing/version evidence. Request duration measures the whole call; Usage's API Response uses TTFT where observed.",chrome));
            let mut toggle = div().flex().gap_2();
            for metric in TrendMetric::ALL {
                toggle = toggle.child(
                    ui::chip(
                        format!("api-trend-{metric:?}"),
                        metric.label(),
                        self.metric == metric,
                        chrome.accent,
                        chrome,
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.metric = metric;
                        cx.notify();
                    })),
                );
            }
            page = page
                .child(toggle)
                .child(trend_chart(data, self.metric, chrome))
                .child(provider_chart(data, chrome))
                .child(model_table(data, chrome))
                .child(recent_table(data, chrome));
            if data.provider_dimensions_truncated || data.model_dimensions_truncated {
                page=page.child(ui::caption("Provider/model dimensions exceed the display budget. Overall totals cover the selected range and daily totals cover the rolling chart window; the dimension tables are bounded.",chrome));
            }
        } else {
            page = page.child(ui::caption(
                if self.gate.in_flight {
                    "Loading captured API analytics…"
                } else {
                    "No successful analytics snapshot yet."
                },
                chrome,
            ));
        }
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(TitleBar::new().child(div().text_sm().child(crate::l10n::tr("API Analytics"))))
            .child(
                div()
                    .id("api-analytics-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .p_4()
                    .child(page),
            )
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refresh_gate_bounds_work_and_replays_latest_request_once() {
        let mut gate = RefreshGate::default();
        assert!(gate.request());
        for _ in 0..1000 {
            assert!(!gate.request());
        }
        assert!(gate.finish());
        assert!(!gate.in_flight);
        assert!(!gate.queued);
        assert!(gate.request());
        assert!(!gate.finish());
    }
    #[test]
    fn labels_keep_unknown_distinct_from_measured_zero_and_partial_cost() {
        let mut m = Metrics::default();
        assert_eq!(token_label(&m.billable_tokens), "Unavailable");
        assert_eq!(cost_label(&m), "Cost unavailable");
        m.calls = 2;
        m.billable_tokens.value = Some(0);
        m.billable_tokens.observed_calls = 1;
        assert_ne!(token_label(&m.billable_tokens), "Unavailable");
        m.recorded_cost_usd.value = Some(0.);
        m.recorded_cost_usd.observed_calls = 1;
        assert!(cost_label(&m).ends_with(" partial"));
        m.recorded_cost_usd.observed_calls = 2;
        assert!(!cost_label(&m).ends_with(" partial"));
    }
}
