//! App events (`Events/AppEventEmitter.swift` and the tab open and close
//! events of `OverlayTabsModel`): user schedules, inactivity, the app's
//! memory threshold, tabs opened and closed. Each goes through
//! [`super::record_app_event`] as source `app`, tool `App`.
//!
//! Timers rebuild when `[next] notification_app_events` changes (Swift
//! rebuilds on any settings change). Unlike Swift, where nothing calls
//! `recordUserActivity`, typing in a terminal resets the inactivity clock.
//!
//! Note: the provider adapters (`NotificationProviderAdapterRegistry`) only
//! accept app types they know; `scheduled` and `inactivity_timeout` are
//! dropped at ingress exactly as in Swift, so they reach the history log
//! but never notify.

use std::time::{Duration, Instant};

use chau7_next_core::notifications::app_events::{
    InactivityTracker, MemoryMonitor, schedule_delays,
};
use chau7_next_core::notifications::settings::AppEventConfig;
use gpui::App;
use uuid::Uuid;

use super::NotificationCenter;
use crate::settings::Settings;

/// Timer state.
#[derive(Debug)]
pub struct AppEventState {
    /// Config the running timers were built from.
    config: Option<AppEventConfig>,
    /// Bumped on every rebuild; older timers stop.
    generation: u64,
    inactivity: InactivityTracker,
    memory: MemoryMonitor,
}

impl Default for AppEventState {
    fn default() -> Self {
        Self {
            config: None,
            generation: 0,
            inactivity: InactivityTracker::new(Instant::now()),
            memory: MemoryMonitor::default(),
        }
    }
}

fn state(cx: &mut App) -> &mut AppEventState {
    &mut cx.global_mut::<NotificationCenter>().app_events
}

fn config(cx: &App) -> AppEventConfig {
    Settings::get(cx).notifications.app_events.clone()
}

/// Typing or running a command (`recordUserActivity`).
pub fn record_activity(cx: &mut App) {
    if cx.has_global::<NotificationCenter>() {
        state(cx).inactivity.record_activity(Instant::now());
    }
}

/// Rebuild the timers when the config changed (`setupTimers`). Called from
/// the notification timer.
pub fn sync_timers(cx: &mut App) {
    let current = config(cx);
    if state(cx).config.as_ref() == Some(&current) {
        return;
    }
    let generation = {
        let st = state(cx);
        st.generation += 1;
        st.config = Some(current.clone());
        st.generation
    };
    for schedule in current.scheduled_events.iter().filter(|s| s.is_enabled) {
        let (first, repeat) = schedule_delays(schedule, chrono::Local::now());
        let id = schedule.id;
        cx.spawn(async move |cx| {
            let mut delay = first;
            loop {
                cx.background_executor().timer(delay).await;
                let alive = cx.update(|cx| {
                    if state(cx).generation != generation {
                        return false;
                    }
                    fire_schedule(id, cx);
                    true
                });
                if !alive || repeat.is_zero() {
                    break;
                }
                delay = repeat;
            }
        })
        .detach();
    }
    if current.inactivity_threshold_minutes > 0 {
        spawn_check(generation, Duration::from_secs(60), check_inactivity, cx);
    }
    if current.memory_threshold_mb > 0 {
        spawn_check(generation, Duration::from_secs(30), check_memory, cx);
    }
}

fn spawn_check(generation: u64, every: Duration, check: fn(&mut App), cx: &mut App) {
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(every).await;
            let alive = cx.update(|cx| {
                if state(cx).generation != generation {
                    return false;
                }
                check(cx);
                true
            });
            if !alive {
                break;
            }
        }
    })
    .detach();
}

/// `fireScheduledEvent`: skipped when the schedule was disabled meanwhile.
fn fire_schedule(id: Uuid, cx: &mut App) {
    let Some(schedule) = config(cx)
        .scheduled_events
        .into_iter()
        .find(|s| s.id == id && s.is_enabled)
    else {
        return;
    };
    super::record_app_event("scheduled", &schedule.name, cx);
}

fn check_inactivity(cx: &mut App) {
    let minutes = config(cx).inactivity_threshold_minutes;
    if let Some(message) = state(cx).inactivity.check(minutes, Instant::now()) {
        super::record_app_event("inactivity_timeout", &message, cx);
    }
}

fn check_memory(cx: &mut App) {
    let config = config(cx);
    let mb = crate::platform::process::own_resident_bytes()
        .map(|b| (b / 1024 / 1024) as i64)
        .unwrap_or(0);
    let message = state(cx).memory.check(
        mb,
        config.memory_threshold_mb,
        config.memory_hysteresis_mb,
        Instant::now(),
    );
    if let Some(message) = message {
        super::record_app_event("memory_threshold", &message, cx);
    }
}

/// A tab was opened (`notifyOnTabOpen`); `directory` for tabs opened at a
/// given folder.
pub fn tab_opened(total: usize, directory: Option<&str>, cx: &mut App) {
    if !config(cx).notify_on_tab_open {
        return;
    }
    let message = match directory {
        Some(dir) => format!("New tab opened at {dir} (total: {total})"),
        None => format!("New tab opened (total: {total})"),
    };
    super::record_app_event("tab_opened", &message, cx);
}

/// A tab was closed (`notifyOnTabClose`).
pub fn tab_closed(remaining: usize, cx: &mut App) {
    if config(cx).notify_on_tab_close {
        super::record_app_event(
            "tab_closed",
            &format!("Tab closed (remaining: {remaining})"),
            cx,
        );
    }
}
