//! The notification engine, app side (`Notifications/NotificationManager.swift`,
//! `AppModel.recordEvent` and the wiring in `Chau7App.swift`). The decision
//! logic is in `chau7_next_core::notifications`.
//!
//! # Feeding events
//!
//! Every producer builds an [`AiEvent`] (`chau7_next_core::ai::event`) and
//! calls one function:
//!
//! ```ignore
//! crate::notifications::ingest(event, cx);           // notify (most callers)
//! crate::notifications::record_event(event, false, cx); // log only
//! ```
//!
//! `ingest` may be called from anywhere on the main thread, including from
//! inside an entity update (the work is deferred). It mirrors
//! `AppModel.recordEvent` + `NotificationManager.notify`:
//!
//! 1. the message is cleaned of escape sequences and a missing `tab_id` is
//!    resolved across windows ([`routing::resolve`]: tab id, AI session id,
//!    tool name, directory);
//! 2. the provider adapters ([`adapters::ingest`]) drop unsupported events
//!    or map them to the canonical kinds; accepted events join the recent
//!    events list (last 25, [`recent_events`]);
//! 3. events with the same identity within 0.25 s are coalesced, then each
//!    is prepared (disabled triggers dropped, tab resolved), authoritative
//!    events without a tab are retried at 0.05, 0.15 and 0.5 s, fallback
//!    events shadowed by a recent authoritative one are dropped;
//! 4. the pipeline decides (trigger, conditions, Focus, app focus, selected
//!    tab), the rate limiter checks, and the actions run ([`executor`]);
//! 5. every step is recorded in the history ledger ([`history`]).
//!
//! Sources: app events ([`app_events`]) and everything published on the
//! AI event feed (`crate::ai::events_out`, subscribed in `crate::seams`):
//! shell events of each session (`ShellEventDetector`), the AI event logs,
//! Claude Code hooks, history idle notices and file conflicts. Every event
//! that enters here is also recorded in the Debug Console's Events tab.
//! Tab ids in events are `tab_resolver::tab_uuid(tab_id)`. Monitors that
//! know where sessions run register directory resolvers with
//! `chau7_next_core::notifications::tab_resolver::register_cwd_resolver`,
//! and clear a permission tab style with [`routing::clear_persistent_style`].
//! The AI event log settings ("Monitor AI Events", path) are
//! `Settings::notifications.monitor_ai_events` / `ai_events_log_path`; the
//! monitor registers its restart with [`set_restart_monitor_hook`].

pub mod app_events;
pub mod banner;
pub mod executor;
pub mod flash;
pub mod hooks;
pub mod routing;

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use chau7_next_core::ai::event::{AiEvent, AiEventReliability, AiEventSource, now_iso8601};
use chau7_next_core::escape_sanitizer::{DEFAULT_LOG_MAX_LENGTH, sanitize_for_logging};
use chau7_next_core::notifications::action_requirements::partition_by_resolved_tab_requirement;
use chau7_next_core::notifications::action_support::ExecutionReport;
use chau7_next_core::notifications::adapters::{self, AcceptedEvent, IngressDecision};
use chau7_next_core::notifications::delivery::{
    self, Preparation, default_style_action, supplemental_style_action,
};
use chau7_next_core::notifications::history::NotificationHistory;
use chau7_next_core::notifications::observation::Observation;
use chau7_next_core::notifications::pipeline::{self, Decision, PipelineInput, RateLimiter};
use chau7_next_core::notifications::reconciler::{Decision as Reconciliation, Reconciler};
use chau7_next_core::notifications::repo_muting::{self, RepoMute};
use chau7_next_core::notifications::schedule::{
    DEFAULT_COALESCING_WINDOW, notification_coalescing_key, notification_rate_limit_key,
};
use chau7_next_core::notifications::suppression::{
    SuppressionCenter, Verdict as SuppressionVerdict,
};
use chrono::{DateTime, Utc};
use gpui::{App, BorrowAppContext, Global};

use crate::settings::Settings;

/// App-wide notification state (`NotificationManager.shared`).
#[derive(Default)]
pub struct NotificationCenter {
    pub history: NotificationHistory,
    pub banner: banner::BannerState,
    pub executor: executor::ExecutorState,
    pub app_events: app_events::AppEventState,
    limiter: RateLimiter,
    pending: HashMap<String, AiEvent>,
    pending_order: Vec<String>,
    flush_scheduled: bool,
    reconciler: Reconciler,
    suppression: SuppressionCenter,
    /// `AppModel.recentEvents`: accepted events, newest last.
    recent: VecDeque<AiEvent>,
    last_refresh: Option<Instant>,
    restart_monitor: Option<fn(&mut App)>,
}

impl Global for NotificationCenter {}

fn center(cx: &mut App) -> &mut NotificationCenter {
    cx.global_mut::<NotificationCenter>()
}

fn automatic_permission_request_allowed(isolated: bool) -> bool {
    !isolated
}

/// Start the engine: permission request (except in isolated test mode), the
/// platform event pump, Focus refresh and app event timers.
pub fn init(cx: &mut App) {
    let mut nc = NotificationCenter::default();
    nc.limiter.config = Settings::get(cx).notifications.rules.rate_limit_config;
    if automatic_permission_request_allowed(chau7_next_core::data_root::is_isolated_test_mode()) {
        banner::request_permission(&mut nc.banner);
    }
    cx.set_global(nc);
    hooks::init(cx);
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            cx.update(tick);
        }
    })
    .detach();
}

/// Every 250 ms: OS callbacks, the 30 s permission and Focus refresh,
/// settings changes.
fn tick(cx: &mut App) {
    let now = Instant::now();
    let resend = banner::handle_platform_events(&mut center(cx).banner);
    for (title, body) in resend {
        banner::fallback(&title, &body, cx);
    }
    let due = center(cx)
        .last_refresh
        .is_none_or(|t| now.duration_since(t) >= Duration::from_secs(30));
    if due {
        let nc = center(cx);
        nc.last_refresh = Some(now);
        banner::refresh(&mut nc.banner);
        prune_repo_mutes(cx);
    }
    let config = Settings::get(cx).notifications.rules.rate_limit_config;
    let nc = center(cx);
    if nc.limiter.config != config {
        nc.limiter = RateLimiter::new(config);
    }
    let permission = cx.global::<NotificationCenter>().banner.permission;
    banner::publish_status(permission, cx);
    app_events::sync_timers(cx);
}

/// Notify for an event (see the module docs).
pub fn ingest(event: AiEvent, cx: &mut App) {
    record_event(event, true, cx);
}

/// `AppModel.recordEvent`: clean, route, run the adapters, keep it in the
/// recent events and, when `notify`, deliver it.
pub fn record_event(event: AiEvent, notify: bool, cx: &mut App) {
    record(event, notify, true, cx);
}

/// An event from the AI event feed (`ai::events_out`), which already
/// logged it: same as [`record_event`] without a second log line.
pub fn record_feed_event(event: AiEvent, notify: bool, cx: &mut App) {
    record(event, notify, false, cx);
}

fn record(event: AiEvent, notify: bool, log_it: bool, cx: &mut App) {
    cx.defer(move |cx| {
        if !cx.has_global::<NotificationCenter>() {
            return;
        }
        let mut event = event;
        event.message = sanitize_for_logging(&event.message, DEFAULT_LOG_MAX_LENGTH);
        if event.tab_id.is_none() {
            event.tab_id = routing::resolve(&event.tab_target(), cx);
        }
        crate::seams::record_debug_event(&event, cx);
        let quiet = matches!(
            event.event_type.as_str(),
            "process_started" | "process_ended"
        );
        if log_it && quiet {
            log::trace!(
                "Recorded event: type={} tool={}",
                event.event_type,
                event.tool
            );
        } else if log_it {
            log::info!(
                "Recorded event: type={} tool={} message=\"{}\"",
                event.event_type,
                event.tool,
                event.message
            );
        }
        let observed_at = Utc::now();
        let raw_note = center(cx).reconciler.observe_raw(&event, observed_at);
        if raw_note.is_some() {
            center(cx).suppression.reopen(&event);
        }
        // Raw debug/spine evidence remains visible. This gate precedes every
        // accepted notification surface and the recent notification feed.
        if event_is_muted(&event, cx) {
            log::trace!(
                "Notification muted for repository: type={}",
                event.event_type
            );
            return;
        }
        match adapters::ingest(&event) {
            IngressDecision::Drop { reason } => log::trace!(
                "Notification ingress dropped unified event: {reason} id={} type={} source={}",
                event.id,
                event.event_type,
                event.source.raw_value()
            ),
            IngressDecision::Accept(accepted) => {
                let nc = center(cx);
                nc.recent.push_back(accepted.shared_event.clone());
                while nc.recent.len() > 25 {
                    nc.recent.pop_front();
                }
                // Accepted events still join the recent feed when delivery is
                // disabled or reconciled away, matching the canonical engine.
                let reconciliation = center(cx).reconciler.reconcile(&accepted, observed_at);
                if notify {
                    match reconciliation {
                        Reconciliation::Emit => {
                            if Observation::notification(
                                &accepted.shared_event,
                                accepted.canonical_event.kind,
                                observed_at,
                            )
                            .is_some_and(|o| o.state.interactive())
                            {
                                // Reconciler accepted a real transition/reopen;
                                // stale post-close/repeat maps cannot block it.
                                center(cx).suppression.reopen(&accepted.shared_event);
                            }
                            let id = accepted.shared_event.id;
                            deliver_accepted(accepted, cx);
                            if let Some(note) = raw_note {
                                center(cx).history.append_note(id, note);
                            }
                        }
                        Reconciliation::Drop { reason } => {
                            let nc = center(cx);
                            let canonical = &accepted.canonical_event;
                            nc.history.begin(
                                &accepted.shared_event,
                                Some(canonical.kind.raw_value()),
                                canonical.raw_type.as_deref(),
                                canonical.notification_type.as_deref(),
                            );
                            nc.history.mark_dropped(
                                accepted.shared_event.id,
                                None,
                                &format!("Session reconciliation: {reason}"),
                            );
                        }
                    }
                }
            }
        }
    });
}

/// An app event (`AppEventEmitter.emitEvent`).
pub fn record_app_event(event_type: &str, message: &str, cx: &mut App) {
    let event = AiEvent::new(
        AiEventSource::app(),
        event_type,
        "App",
        message,
        now_iso8601(),
    );
    ingest(event, cx);
}

/// Typing in a terminal (inactivity timer).
pub fn record_user_activity(cx: &mut App) {
    app_events::record_activity(cx);
}

/// The last accepted events, newest last (status bar and debug console).
#[allow(dead_code)]
pub fn recent_events(cx: &App) -> Vec<AiEvent> {
    cx.try_global::<NotificationCenter>()
        .map(|nc| nc.recent.iter().cloned().collect())
        .unwrap_or_default()
}

/// The AI event monitor registers how to restart itself ("Restart
/// Monitor" in Settings).
pub fn set_restart_monitor_hook(hook: fn(&mut App), cx: &mut App) {
    if cx.has_global::<NotificationCenter>() {
        center(cx).restart_monitor = Some(hook);
    }
}

/// "Restart Monitor": false when no monitor registered.
pub fn restart_monitor(cx: &mut App) -> bool {
    match cx
        .try_global::<NotificationCenter>()
        .and_then(|nc| nc.restart_monitor)
    {
        Some(hook) => {
            hook(cx);
            true
        }
        None => false,
    }
}

/// "Send Test" (`AppModel.sendTestNotification`).
pub fn send_test(cx: &mut App) {
    let mut event = AiEvent::new(
        AiEventSource::app(),
        "update_available",
        chau7_next_core::data_root::APP_NAME,
        format!(
            "This is a test notification from {}.",
            chau7_next_core::data_root::APP_NAME
        ),
        now_iso8601(),
    );
    event.producer = Some("app_model_test".into());
    event.reliability = AiEventReliability::Authoritative;
    ingest(event, cx);
}

/// "Request Permission".
pub fn request_permission(cx: &mut App) {
    if cx.has_global::<NotificationCenter>() {
        banner::request_permission(&mut center(cx).banner);
    }
}

/// Mute status is shared by Settings and repository context menus.
pub fn repo_is_muted(root: &str, cx: &App) -> bool {
    repo_muting::is_muted(
        Some(root),
        None,
        &Settings::get(cx).notifications.rules.muted_repos,
        Utc::now(),
    )
}

fn event_is_muted(event: &AiEvent, cx: &App) -> bool {
    repo_muting::is_muted(
        event.repo_path.as_deref(),
        event.directory.as_deref(),
        &Settings::get(cx).notifications.rules.muted_repos,
        Utc::now(),
    )
}

/// None is an indefinite mute; expiry is exclusive. Config persistence uses
/// Next's existing global-settings path and never edits repository config.
pub fn mute_repo(root: &str, until: Option<DateTime<Utc>>, cx: &mut App) {
    let Some(root) = repo_muting::normalized_root(root) else {
        return;
    };
    let key = root.to_string_lossy().into_owned();
    crate::settings_window::update(cx, |settings| {
        repo_muting::prune(&mut settings.notifications.rules.muted_repos, Utc::now());
        settings.notifications.rules.muted_repos.insert(
            key,
            RepoMute {
                snooze_until: until,
            },
        );
    });
    cx.refresh_windows();
}

pub fn unmute_repo(root: &str, cx: &mut App) {
    let target = repo_muting::normalized_root(root);
    crate::settings_window::update(cx, |settings| {
        settings
            .notifications
            .rules
            .muted_repos
            .retain(|key, _| repo_muting::normalized_root(key) != target);
    });
    cx.refresh_windows();
}

fn prune_repo_mutes(cx: &mut App) {
    let now = Utc::now();
    if Settings::get(cx)
        .notifications
        .rules
        .muted_repos
        .values()
        .any(|mute| !mute.is_active(now))
    {
        crate::settings_window::update(cx, |settings| {
            repo_muting::prune(&mut settings.notifications.rules.muted_repos, now);
        });
    }
}

// ----- delivery -------------------------------------------------------------

fn deliver_accepted(accepted: AcceptedEvent, cx: &mut App) {
    let event = accepted.shared_event;
    let canonical = accepted.canonical_event;
    log::info!(
        "Notification ingress accepted: id={} source={} type={} semantic={} reliability={} tabID={} sessionID={}",
        event.id,
        event.source.raw_value(),
        event.event_type,
        canonical.kind.raw_value(),
        event.reliability.raw_value(),
        event
            .tab_id
            .map(|t| t.to_string())
            .unwrap_or_else(|| "nil".into()),
        event.session_id.as_deref().unwrap_or("nil")
    );
    center(cx).history.begin(
        &event,
        Some(canonical.kind.raw_value()),
        canonical.raw_type.as_deref(),
        canonical.notification_type.as_deref(),
    );
    enqueue(event, cx);
}

/// Coalesce for 0.25 s (`enqueueEvent`).
fn enqueue(event: AiEvent, cx: &mut App) {
    let key = notification_coalescing_key(&event);
    let schedule = {
        let nc = center(cx);
        let id = event.id;
        let is_new = nc.pending.insert(key.clone(), event).is_none();
        if is_new {
            nc.pending_order.push(key.clone());
        } else {
            nc.history.mark_coalesced(id, &key);
        }
        let schedule = !nc.flush_scheduled;
        nc.flush_scheduled = true;
        schedule
    };
    if schedule {
        cx.spawn(async move |cx| {
            cx.background_executor()
                .timer(Duration::from_secs_f64(DEFAULT_COALESCING_WINDOW))
                .await;
            cx.update(flush);
        })
        .detach();
    }
}

fn flush(cx: &mut App) {
    let events: Vec<AiEvent> = {
        let nc = center(cx);
        nc.flush_scheduled = false;
        let order = std::mem::take(&mut nc.pending_order);
        order
            .into_iter()
            .filter_map(|k| nc.pending.remove(&k))
            .collect()
    };
    for event in events {
        process_event(event, cx);
    }
}

fn base_rate_limit_key(trigger_id: Option<&str>, event: &AiEvent) -> String {
    trigger_id.map(str::to_string).unwrap_or_else(|| {
        format!(
            "unmatched.{}.{}",
            event.source.raw_value(),
            event.tool.to_lowercase()
        )
    })
}

fn rate_limited(trigger_id: &str, event: &AiEvent, cx: &mut App) -> bool {
    let key = notification_rate_limit_key(trigger_id, event);
    let nc = center(cx);
    if nc.limiter.check_and_consume(&key, Instant::now()) {
        return false;
    }
    log::info!("Rate limited: {key} for tool={}", event.tool);
    nc.history.mark_rate_limited(event.id, trigger_id);
    nc.suppression.forget_retry(event.id);
    true
}

/// `processEvent`.
fn process_event(event: AiEvent, cx: &mut App) {
    // A repo may have been muted while this event was coalescing or retrying.
    if event_is_muted(&event, cx) {
        let nc = center(cx);
        nc.history
            .mark_dropped(event.id, None, "Repository notifications are muted");
        nc.suppression.forget_retry(event.id);
        return;
    }
    let now = Utc::now();
    if !center(cx).reconciler.is_relevant(&event, now) {
        let nc = center(cx);
        nc.history.mark_dropped(
            event.id,
            None,
            "Session state superseded this queued notification",
        );
        nc.suppression.forget_retry(event.id);
        return;
    }
    center(cx).suppression.prune(now);
    let rules = Settings::get(cx).notifications.rules.clone();
    let preparation = {
        let app: &App = cx;
        let mut resolver =
            |target: &chau7_next_core::tab_target::TabTarget| routing::resolve(target, app);
        delivery::prepare(&event, &rules.trigger_state, Some(&mut resolver))
    };
    let (event, method) = match preparation {
        Preparation::Drop { reason } => {
            log::trace!(
                "Notification dropped: {reason} (type={} tool={})",
                event.event_type,
                event.tool
            );
            center(cx).history.mark_dropped(event.id, None, &reason);
            return;
        }
        Preparation::Proceed(p) => (p.event, p.resolution_method),
    };
    log::info!(
        "Notification delivery prepared: id={} type={} tool={} resolution={method}",
        event.id,
        event.event_type,
        event.tool
    );
    center(cx).history.mark_prepared(&event, &method);

    let semantic = delivery::semantic_kind(&event);
    if delivery::should_clear_persistent_attention_style(&event, semantic)
        && let Some(tab) = event.tab_id
    {
        routing::clear_persistent_style(tab, cx);
    }
    center(cx).suppression.register_closed(&event, now);
    match center(cx).suppression.routing(&event, now) {
        SuppressionVerdict::Retry { delay, attempt } => {
            center(cx).history.mark_retry_scheduled(
                event.id,
                attempt,
                "authoritative event missing exact tab route",
            );
            schedule_retry(event, delay, cx);
            return;
        }
        SuppressionVerdict::Drop { reason } => {
            center(cx).history.mark_dropped(event.id, None, &reason);
            return;
        }
        SuppressionVerdict::Pass => {}
    }
    let verdicts = [
        center(cx).suppression.post_close(&event, now),
        center(cx).suppression.fallback_shadow(&event, now),
        center(cx).suppression.repeat(&event, now),
    ];
    for verdict in verdicts {
        if let SuppressionVerdict::Drop { reason } = verdict {
            center(cx).history.mark_dropped(event.id, None, &reason);
            center(cx).suppression.forget_retry(event.id);
            return;
        }
    }
    center(cx).suppression.register_authoritative(&event, now);

    let is_app_active = cx.active_window().is_some();
    let is_tool_tab_active = routing::is_selected_anywhere(&event.tab_target(), cx);
    let focus = cx.global::<NotificationCenter>().banner.focus_mode_active;
    let decision = pipeline::evaluate(&PipelineInput {
        event: &event,
        trigger_state: &rules.trigger_state,
        trigger_conditions: &rules.trigger_conditions,
        action_bindings: &rules.trigger_action_bindings,
        group_conditions: &rules.group_conditions,
        group_action_bindings: &rules.group_action_bindings,
        is_focus_mode_active: focus,
        is_app_active,
        is_tool_tab_active,
    });

    match decision {
        Decision::Drop { reason } => {
            log::trace!(
                "Notification dropped: {reason} (type={} tool={})",
                event.event_type,
                event.tool
            );
            let nc = center(cx);
            nc.history.mark_dropped(event.id, None, &reason);
            nc.suppression.forget_retry(event.id);
        }
        Decision::FireDefault { trigger_id } => {
            let base = base_rate_limit_key(trigger_id.as_deref(), &event);
            if rate_limited(&base, &event, cx) {
                return;
            }
            let banner = show_default_notification(&event, cx);
            let styled = apply_default_tab_style(&event, cx);
            let mut actions = vec!["showNotification".to_string()];
            if styled {
                actions.push("styleTab".into());
            }
            finish(&event, Some(&base), &actions, banner, styled, cx);
        }
        Decision::FireStyleOnly {
            trigger_id,
            actions,
        } => {
            let base = base_rate_limit_key(trigger_id.as_deref(), &event);
            if rate_limited(&base, &event, cx) {
                return;
            }
            if event.tab_id.is_none() {
                let reason = "Style-only notification delivery requires explicit tabID";
                let nc = center(cx);
                nc.history.mark_dropped(event.id, Some(&base), reason);
                nc.suppression.forget_retry(event.id);
                return;
            }
            let report = executor::execute(&actions, &event, cx);
            finish_report(&event, &base, report, cx);
        }
        Decision::FireActions {
            trigger_id,
            actions,
        } => {
            if rate_limited(&trigger_id, &event, cx) {
                return;
            }
            let (tab_scoped, other) = partition_by_resolved_tab_requirement(&actions);
            let mut report = ExecutionReport::default();
            if !other.is_empty() {
                report.append(executor::execute(&other, &event, cx));
            }
            if !tab_scoped.is_empty() {
                if event.tab_id.is_none() {
                    let skipped: Vec<&str> = tab_scoped
                        .iter()
                        .filter(|a| a.enabled)
                        .map(|a| a.action_type.raw_value())
                        .collect();
                    let reason = format!(
                        "Skipped tab-scoped notification actions without explicit tabID: {}",
                        skipped.join(", ")
                    );
                    log::warn!("{reason} id={}", event.id);
                    center(cx).history.append_note(event.id, reason);
                    let banner = report.did_dispatch_banner;
                    finish(
                        &event,
                        Some(&trigger_id),
                        &report.successful_actions,
                        banner,
                        false,
                        cx,
                    );
                    return;
                }
                report.append(executor::execute(&tab_scoped, &event, cx));
            }
            if let Some(style) = supplemental_style_action(&event, &actions) {
                if event.tab_id.is_some() {
                    report.append(executor::execute(&[style], &event, cx));
                } else {
                    center(cx).history.append_note(
                        event.id,
                        "Skipped supplemental style action without explicit tabID",
                    );
                }
            }
            finish_report(&event, &trigger_id, report, cx);
        }
    }
}

fn finish_report(event: &AiEvent, trigger_id: &str, report: ExecutionReport, cx: &mut App) {
    for note in &report.notes {
        center(cx).history.append_note(event.id, note.clone());
    }
    log::info!(
        "Notification delivery executed actions: id={} trigger={trigger_id} actions={} notes={}",
        event.id,
        report.successful_actions.join(", "),
        report.notes.join(" | ")
    );
    finish(
        event,
        Some(trigger_id),
        &report.successful_actions,
        report.did_dispatch_banner,
        report.did_style_tab,
        cx,
    );
}

fn finish(
    event: &AiEvent,
    trigger_id: Option<&str>,
    actions: &[String],
    banner: bool,
    styled: bool,
    cx: &mut App,
) {
    let nc = center(cx);
    nc.history
        .mark_actions_executed(event.id, trigger_id, actions, banner, styled);
    nc.history.mark_completed(event.id);
    nc.suppression.register_repeat(event, Utc::now());
    nc.suppression.forget_retry(event.id);
}

/// Retry a prepared canonical event without repeating ingress/reconciliation.
fn schedule_retry(event: AiEvent, delay: Duration, cx: &mut App) {
    cx.spawn(async move |cx| {
        cx.background_executor().timer(delay).await;
        cx.update(|cx| enqueue(event, cx));
    })
    .detach();
}

/// `showDefaultNotification`: title from the tab title and repo name.
fn show_default_notification(event: &AiEvent, cx: &mut App) -> bool {
    let target = event.tab_target();
    let tab_title = routing::tab_title(&target, cx);
    let repo = routing::repo_name(&target, cx);
    let title = event.notification_title_with(tab_title.as_deref(), repo.as_deref());
    let body = event.notification_body();
    cx.update_global(|nc: &mut NotificationCenter, cx| {
        banner::dispatch(&mut nc.banner, &title, &body, cx)
    })
}

/// `applyDefaultTabStyle`: the default style (cleared after 30 s).
fn apply_default_tab_style(event: &AiEvent, cx: &mut App) -> bool {
    let Some(action) = default_style_action(event) else {
        return false;
    };
    if event.tab_id.is_none() {
        center(cx)
            .history
            .append_note(event.id, "Skipped default tab style without explicit tabID");
        return false;
    }
    let report = executor::execute(&[action], event, cx);
    for note in &report.notes {
        center(cx).history.append_note(event.id, note.clone());
    }
    report.did_style_tab
}

#[cfg(test)]
mod startup_isolation_tests {
    #[test]
    fn isolation_automatic_permission_decision_preserves_normal_requests() {
        assert!(!super::automatic_permission_request_allowed(true));
        assert!(super::automatic_permission_request_allowed(false));
    }

    #[test]
    fn isolation_permission_guard_is_wired_only_to_automatic_startup() {
        let source = include_str!("mod.rs");
        let startup = source
            .split_once("pub fn init(cx: &mut App) {")
            .unwrap()
            .1
            .split_once("cx.set_global(nc);")
            .unwrap()
            .0;
        assert!(startup.contains("if automatic_permission_request_allowed("));
        assert!(startup.contains("chau7_next_core::data_root::is_isolated_test_mode()"));
        assert!(startup.contains("banner::request_permission(&mut nc.banner);"));
        let manual = source
            .split_once("pub fn request_permission(cx: &mut App) {")
            .unwrap()
            .1
            .split_once("/// Mute status")
            .unwrap()
            .0;
        assert!(manual.contains("banner::request_permission(&mut center(cx).banner);"));
        assert!(!manual.contains("automatic_permission_request_allowed"));
    }
}
