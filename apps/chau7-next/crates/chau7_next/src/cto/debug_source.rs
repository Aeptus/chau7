//! Data of the Debug Console's Token Optimizer tab (`refreshCTOData`):
//! runtime counters, the command log of the period, the savings of the
//! period and per-session savings.
//!
//! The per-tab AI token table and the provider consumption come from the
//! telemetry store (runs of the same period: `tokenUsagePerTab(after:)`,
//! `consumptionPerProvider(after:)`).

use std::rc::Rc;

use chau7_next_core::cto_wrappers::{self as wrappers, DailyGainEntry};
use chau7_next_core::debug_console::{CtoPeriod, TokenOptimizerData, filter_log};
use chau7_next_core::token_optimization::CTOGainStats;
use chrono::{Local, TimeZone};
use gpui::App;

use crate::debug::{TokenOptimizerSource, set_token_optimizer_source};

/// Seconds between the Unix epoch and the Swift reference date.
const REFERENCE_DATE_UNIX_OFFSET: f64 = 978_307_200.0;

fn now_unix() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// Midnight today (local time), Unix seconds.
fn start_of_today() -> f64 {
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

/// `yyyy-MM-dd` of a Unix time, in local time.
fn local_day(unix: f64) -> String {
    Local
        .timestamp_opt(unix as i64, 0)
        .single()
        .map_or_else(String::new, |t| t.format("%Y-%m-%d").to_string())
}

/// Savings of the period (`ctoFilteredGainStats`): the optimizer's total for
/// all time, else the daily entries since the cutoff day, else the total.
pub fn period_gain(
    period: CtoPeriod,
    summary: Option<&CTOGainStats>,
    daily: &[DailyGainEntry],
    cutoff: Option<f64>,
) -> Option<CTOGainStats> {
    let Some(cutoff) = cutoff else {
        return summary.cloned();
    };
    if period == CtoPeriod::All || daily.is_empty() {
        return summary.cloned();
    }
    Some(wrappers::aggregate_daily_stats(daily, &local_day(cutoff)))
}

/// Unix seconds as a UTC time (a cutoff of the telemetry queries).
fn utc(unix: f64) -> Option<chrono::DateTime<chrono::Utc>> {
    chrono::DateTime::from_timestamp(unix as i64, 0)
}

/// What the tab shows for `period`.
pub fn data(period: CtoPeriod, cx: &App) -> TokenOptimizerData {
    let runtime = super::runtime_snapshot();
    let session_start = runtime.first_seen_at + REFERENCE_DATE_UNIX_OFFSET;
    let cutoff = period.cutoff(session_start, start_of_today(), now_unix());
    let log = filter_log(&super::command_log(5000), cutoff);
    let cache = super::gain_cache();
    let daily = cache
        .response
        .as_ref()
        .and_then(|r| r.daily.clone())
        .unwrap_or_default();
    let gain = period_gain(
        period,
        cache.response.as_ref().map(|r| &r.summary),
        &daily,
        cutoff,
    );
    // Telemetry uses the same period, `nil` (everything) for All only.
    let after = match period {
        CtoPeriod::All => None,
        _ => cutoff.and_then(utc),
    };
    let (tab_consumption, provider_consumption) = crate::telemetry::recorder(cx)
        .map(|r| {
            let store = r.store();
            (
                store.token_usage_per_tab(after),
                store.consumption_per_provider(after),
            )
        })
        .unwrap_or_default();
    TokenOptimizerData {
        runtime,
        log,
        gain,
        session_gain: cache.sessions,
        tab_consumption,
        provider_consumption,
    }
}

/// Register the tab's data and buttons.
pub fn register(cx: &mut App) {
    set_token_optimizer_source(
        cx,
        TokenOptimizerSource {
            data: Rc::new(data),
            refresh: Some(Rc::new(super::refresh_gain)),
            reset: Some(Rc::new(|_| super::reset_monitor())),
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(date: &str, commands: i64, input: i64, saved: i64) -> DailyGainEntry {
        DailyGainEntry {
            date: date.into(),
            commands,
            input_tokens: input,
            output_tokens: input - saved,
            saved_tokens: saved,
            savings_pct: 0.0,
        }
    }

    fn summary() -> CTOGainStats {
        CTOGainStats {
            commands: 99,
            input_tokens: 1000,
            output_tokens: 500,
            saved_tokens: 500,
            savings_pct: 50.0,
            total_time_ms: 0,
            avg_time_ms: 0,
        }
    }

    #[test]
    fn all_time_and_missing_daily_data_use_the_summary() {
        let s = summary();
        let daily = [day("2026-10-09", 1, 100, 50)];
        assert_eq!(
            period_gain(CtoPeriod::All, Some(&s), &daily, None),
            Some(s.clone())
        );
        assert_eq!(
            period_gain(CtoPeriod::Week, Some(&s), &[], Some(1.0)),
            Some(s.clone())
        );
        assert_eq!(period_gain(CtoPeriod::Today, None, &[], Some(1.0)), None);
    }

    #[test]
    fn a_period_sums_the_days_since_its_cutoff() {
        let daily = [
            day("2000-01-01", 5, 500, 100),
            day("2999-01-01", 2, 200, 100),
        ];
        let cutoff = now_unix();
        let got = period_gain(CtoPeriod::Week, Some(&summary()), &daily, Some(cutoff)).unwrap();
        assert_eq!((got.commands, got.saved_tokens), (2, 100));
        assert!((got.savings_pct - 50.0).abs() < 1e-9);
    }

    #[test]
    fn utc_converts_unix_seconds() {
        assert_eq!(utc(0.0).map(|t| t.timestamp()), Some(0));
        assert_eq!(
            utc(1_700_000_000.5).map(|t| t.timestamp()),
            Some(1_700_000_000)
        );
    }

    #[test]
    fn local_day_formats_the_date() {
        assert_eq!(local_day(now_unix()).len(), 10);
    }
}
