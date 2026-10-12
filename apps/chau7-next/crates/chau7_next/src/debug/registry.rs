//! What other modules can plug into the Debug Console. See the module doc
//! of [`crate::debug`] for how to use it.

// The registration API is for modules that land after this one; until they
// do, nothing calls it.
#![allow(dead_code)]

use std::collections::VecDeque;
use std::rc::Rc;

use chau7_next_core::bug_report::ClaudeSessionState;
use chau7_next_core::debug_console::{AnalyticsData, CtoPeriod, TokenOptimizerData, Tone};
use chrono::{DateTime, Utc};
use gpui::{AnyElement, App, Global, SharedString, Window};

/// Events kept for the Events tab and the bug reports.
pub const EVENT_CAPACITY: usize = 500;

/// Renders the body of a panel. Called every frame while the tab is shown.
pub type PanelRender = Rc<dyn Fn(&mut Window, &mut App) -> AnyElement>;

/// An extra tab of the Debug Console.
#[derive(Clone)]
pub struct Panel {
    /// Stable id (`"notifications"`); registering the same id again
    /// replaces the panel.
    pub id: &'static str,
    /// Text on the tab.
    pub title: SharedString,
    /// Body of the tab.
    pub render: PanelRender,
    /// The console redraws the tab every second while "Auto-refresh" is on.
    pub auto_refresh: bool,
}

impl Panel {
    pub fn new(
        id: &'static str,
        title: impl Into<SharedString>,
        render: impl Fn(&mut Window, &mut App) -> AnyElement + 'static,
    ) -> Self {
        Self {
            id,
            title: title.into(),
            render: Rc::new(render),
            auto_refresh: false,
        }
    }

    /// Redraw every second while auto-refresh is on.
    pub fn auto_refresh(mut self) -> Self {
        self.auto_refresh = true;
        self
    }
}

/// An AI event (`AIEvent`, `ClaudeCodeEvent`) for the Events tab.
#[derive(Debug, Clone)]
pub struct DebugEvent {
    pub timestamp: DateTime<Utc>,
    /// Event type: `finished`, `failed`, `permission`, `waiting_input`,
    /// `tool_use`...; drives the color.
    pub kind: String,
    pub tool: String,
    pub message: String,
    /// Where it came from (`terminal_session`, `api_proxy`, `hooks`...).
    pub source: String,
    /// Claude Code hook name; `Some` marks a Claude Code hook event.
    pub hook: Option<String>,
}

/// One line of a health section.
#[derive(Debug, Clone)]
pub struct HealthRow {
    pub label: String,
    pub value: String,
    pub tone: Option<Tone>,
}

impl HealthRow {
    pub fn new(label: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            value: value.into(),
            tone: None,
        }
    }

    pub fn tone(mut self, tone: Tone) -> Self {
        self.tone = Some(tone);
        self
    }
}

type TokenOptimizerFn = Rc<dyn Fn(CtoPeriod, &App) -> TokenOptimizerData>;
type AnalyticsFn = Rc<dyn Fn(&App) -> (Option<AnalyticsData>, Option<String>)>;
type ClaudeSessionsFn = Rc<dyn Fn(&App) -> Vec<ClaudeSessionState>>;
type HealthFn = Rc<dyn Fn(&App) -> Vec<HealthRow>>;
type ActionFn = Rc<dyn Fn(&mut App)>;

/// Token Optimizer data and the actions of its buttons.
#[derive(Clone)]
pub struct TokenOptimizerSource {
    /// Data of the chosen period.
    pub data: TokenOptimizerFn,
    /// "Refresh" in Advanced Telemetry (recalculate the runtime state).
    pub refresh: Option<ActionFn>,
    /// "Reset Monitor".
    pub reset: Option<ActionFn>,
}

/// Analytics data and the actions of its buttons.
#[derive(Clone)]
pub struct AnalyticsSource {
    pub data: AnalyticsFn,
    /// "Rebuild Transcript Metrics" (AI Runs).
    pub rebuild: Option<ActionFn>,
}

/// Everything registered, in one global.
#[derive(Default)]
pub struct Registry {
    pub(super) panels: Vec<Panel>,
    pub(super) events: VecDeque<DebugEvent>,
    pub(super) token_optimizer: Option<TokenOptimizerSource>,
    pub(super) analytics: Option<AnalyticsSource>,
    pub(super) claude_sessions: Option<ClaudeSessionsFn>,
    pub(super) health: Vec<(&'static str, SharedString, HealthFn)>,
}

impl Global for Registry {}

fn registry(cx: &mut App) -> &mut Registry {
    cx.default_global::<Registry>()
}

/// Add a tab to the Debug Console, after the built-in ones.
pub fn register_panel(cx: &mut App, panel: Panel) {
    let registry = registry(cx);
    match registry.panels.iter_mut().find(|p| p.id == panel.id) {
        Some(existing) => *existing = panel,
        None => registry.panels.push(panel),
    }
    cx.refresh_windows();
}

/// Remove a tab (a module that stops).
pub fn unregister_panel(cx: &mut App, id: &str) {
    registry(cx).panels.retain(|p| p.id != id);
    cx.refresh_windows();
}

/// Record an AI event. Shown newest first in the Events tab; the last 20
/// Claude Code hook events go into bug reports.
pub fn record_event(cx: &mut App, event: DebugEvent) {
    let events = &mut registry(cx).events;
    if events.len() >= EVENT_CAPACITY {
        events.pop_front();
    }
    events.push_back(event);
}

/// Forget all events (Report tab, "Clear Event History").
pub fn clear_events(cx: &mut App) {
    registry(cx).events.clear();
    cx.refresh_windows();
}

/// Where the Token Optimizer tab gets its data.
pub fn set_token_optimizer_source(cx: &mut App, source: TokenOptimizerSource) {
    registry(cx).token_optimizer = Some(source);
}

/// Where the Analytics tab gets its data.
pub fn set_analytics_source(cx: &mut App, source: AnalyticsSource) {
    registry(cx).analytics = Some(source);
}

/// Claude Code sessions, for the State tab count and bug reports.
pub fn set_claude_sessions_source(
    cx: &mut App,
    source: impl Fn(&App) -> Vec<ClaudeSessionState> + 'static,
) {
    registry(cx).claude_sessions = Some(Rc::new(source));
}

/// A titled block of rows in the Health tab (for example "Notifications").
/// Registering the same id again replaces the block.
pub fn register_health_section(
    cx: &mut App,
    id: &'static str,
    title: impl Into<SharedString>,
    rows: impl Fn(&App) -> Vec<HealthRow> + 'static,
) {
    let title = title.into();
    let registry = registry(cx);
    let section = (id, title, Rc::new(rows) as HealthFn);
    match registry.health.iter_mut().find(|(i, _, _)| *i == id) {
        Some(existing) => *existing = section,
        None => registry.health.push(section),
    }
}

// ----- reads, for the console ------------------------------------------------

impl Registry {
    pub(super) fn get(cx: &App) -> Option<&Registry> {
        cx.try_global::<Registry>()
    }
}

pub(super) fn panels(cx: &App) -> Vec<Panel> {
    Registry::get(cx)
        .map(|r| r.panels.clone())
        .unwrap_or_default()
}

/// Events, newest first.
pub(super) fn events(cx: &App) -> Vec<DebugEvent> {
    Registry::get(cx)
        .map(|r| r.events.iter().rev().cloned().collect())
        .unwrap_or_default()
}

pub(super) fn event_counts(cx: &App) -> (usize, usize) {
    Registry::get(cx).map_or((0, 0), |r| {
        (
            r.events.len(),
            r.events.iter().filter(|e| e.hook.is_some()).count(),
        )
    })
}

pub(super) fn token_optimizer(cx: &App) -> Option<TokenOptimizerSource> {
    Registry::get(cx).and_then(|r| r.token_optimizer.clone())
}

pub(super) fn analytics(cx: &App) -> Option<AnalyticsSource> {
    Registry::get(cx).and_then(|r| r.analytics.clone())
}

pub(super) fn claude_sessions(cx: &App) -> Vec<ClaudeSessionState> {
    Registry::get(cx)
        .and_then(|r| r.claude_sessions.clone())
        .map(|f| f(cx))
        .unwrap_or_default()
}

pub(super) fn health_sections(cx: &App) -> Vec<(SharedString, Vec<HealthRow>)> {
    Registry::get(cx)
        .map(|r| {
            r.health
                .iter()
                .map(|(_, title, rows)| (title.clone(), rows(cx)))
                .collect()
        })
        .unwrap_or_default()
}
