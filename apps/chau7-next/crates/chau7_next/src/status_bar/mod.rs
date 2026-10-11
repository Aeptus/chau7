//! The menu bar item and its command center (StatusBar module): a bell in
//! the macOS menu bar for the life of the app. Clicking it opens a 380 pt
//! popover under the icon ([`popover`]) with the sessions that need
//! attention, the live AI sessions, the activity feed, the pinned snippets,
//! the Monitoring switch and Quit.
//!
//! Ports `StatusBar/StatusBarController.swift` (`StatusBarController`). The
//! content and the icon rules are in `chau7_next_core::command_center`
//! (tested without a menu bar); the item itself is `platform::status_item`.
//! On systems without a menu bar item nothing here runs.

pub mod popover;

use std::time::{Duration, Instant};

use chau7_next_core::command_center::{
    self as cc, BadgeCounts, PanelCommand, PanelModel, QuickCommand, Rect, SessionSummary,
    StatusIcon,
};
use gpui::{AnyWindowHandle, App, ClipboardItem, Global};

use crate::platform::status_item::{self, ScreenRect, StatusItem, StatusItemEvent};
use crate::settings::Settings;
use crate::workspace::AppData;

/// Calls of [`poll`] (every 150 ms) between two refreshes of the session
/// count: about one second (`Timer.publish(every: 1.0)`).
const REFRESH_EVERY: u32 = 7;
/// A click on the item within this long after the popover closed itself
/// (because it lost the focus) does not open it again: the same click closed
/// it.
const REOPEN_GUARD: Duration = Duration::from_millis(250);

/// An alert flash in progress (`flashAlert`).
struct Alert {
    started: Instant,
    duration_secs: u64,
    animate: bool,
}

pub struct StatusBar {
    item: Option<Box<dyn StatusItem>>,
    item_id: u32,
    alert: Option<Alert>,
    counts: BadgeCounts,
    shown: Option<StatusIcon>,
    shown_description: Option<String>,
    active_description: String,
    popover: Option<AnyWindowHandle>,
    closed_by_blur: Option<Instant>,
    ticks: u32,
}

impl Global for StatusBar {}

/// Add the bell to the menu bar (`StatusBarController.setup`). Called once at
/// launch, on the main thread.
pub fn init(cx: &mut App) {
    let item = match status_item::create() {
        Ok(item) => Some(item),
        Err(err) => {
            log::info!("menu bar item: {err}");
            None
        }
    };
    let item_id = item.as_ref().map(|i| i.id()).unwrap_or(0);
    if let Some(item) = &item {
        let _ = item.set_symbol(cc::ICON_OFF, cc::ITEM_NAME);
        item.set_tooltip(Some(cc::ITEM_NAME));
        // No menu: a click arrives as an event and opens the popover.
        item.set_menu(None);
    }
    cx.set_global(StatusBar {
        item,
        item_id,
        alert: None,
        counts: BadgeCounts::default(),
        shown: None,
        shown_description: None,
        active_description: String::new(),
        popover: None,
        closed_by_blur: None,
        ticks: 0,
    });
    refresh(cx);
}

/// Whether the monitoring switch is on (`model.isMonitoring`).
pub fn monitoring(cx: &App) -> bool {
    Settings::get(cx).notifications.monitor_ai_events
}

/// The AI sessions of all windows, most recent activity first.
pub fn live_sessions(cx: &App) -> Vec<SessionSummary> {
    let mut candidates = Vec::new();
    for (_, workspace) in AppData::live(cx) {
        candidates.extend(workspace.read(cx).command_center_candidates(cx));
    }
    cc::collect_live_sessions(&candidates)
}

/// Pinned snippets of the active window's repo, in list order.
fn pinned_snippets(cx: &App) -> Vec<QuickCommand> {
    let root = cx.global::<AppData>().root.clone();
    let settings = Settings::get(cx).productivity.clone();
    let git_root = crate::app_actions::active_workspace(cx)
        .and_then(|(_, ws)| ws.read(cx).active_git_root(cx));
    crate::snippets::load_entries(&root, &settings, git_root.as_deref())
        .into_iter()
        .filter(|e| e.snippet.is_pinned)
        .map(|e| QuickCommand {
            id: e.snippet.id.clone(),
            title: e.snippet.title.clone(),
            body: e.snippet.body.clone(),
        })
        .collect()
}

/// App version for the footer (`CFBundleShortVersionString`, else "dev").
fn bundle_version() -> String {
    crate::platform::system::bundle_string("CFBundleShortVersionString")
        .unwrap_or_else(|| "dev".to_string())
}

/// Everything the popover shows right now.
pub fn panel_model(cx: &App) -> PanelModel {
    let sessions = live_sessions(cx);
    let history = cx
        .try_global::<crate::notifications::NotificationCenter>()
        .map(|nc| nc.history.recent(8))
        .unwrap_or_default();
    let events = crate::notifications::recent_events(cx);
    cc::build_panel_localized(
        cc::PanelInputs {
            sessions,
            history: &history,
            recent_events: &events,
            pinned: pinned_snippets(cx),
            monitoring: monitoring(cx),
            version: &bundle_version(),
            now: chrono::Utc::now(),
        },
        chau7_next_core::l10n::current(),
    )
}

/// Recount the sessions and redraw the icon (`refreshSessions`).
fn refresh(cx: &mut App) {
    let sessions = live_sessions(cx);
    let counts = cc::badge_counts(&sessions);
    let description = cc::menu_status_description(&sessions, chau7_next_core::l10n::current());
    let bar = cx.global_mut::<StatusBar>();
    bar.counts = counts;
    bar.active_description = description;
    update_icon(cx);
}

/// `updateBadgeAndIcon`: the bell for the monitoring state, the number of
/// sessions waiting for input, the alert flash on top.
fn update_icon(cx: &mut App) {
    let monitoring = monitoring(cx);
    let bar = cx.global_mut::<StatusBar>();
    let phase = match &bar.alert {
        Some(alert) => {
            let elapsed = alert.started.elapsed().as_millis() as u64;
            let phase = cc::flash_phase(alert.duration_secs, alert.animate, elapsed);
            if phase.is_none() {
                bar.alert = None;
            }
            phase
        }
        None => None,
    };
    let icon = cc::status_icon(monitoring, bar.counts, phase);
    let description = if monitoring {
        bar.active_description.clone()
    } else {
        chau7_next_core::l10n::l("statusBar.icon.monitoringPaused", "monitoring paused")
    };
    if bar.shown.as_ref() == Some(&icon) && bar.shown_description.as_ref() == Some(&description) {
        return;
    }
    if let Some(item) = &bar.item {
        if (bar.shown.as_ref().map(|s| s.symbol) != Some(icon.symbol)
            || bar.shown_description.as_ref() != Some(&description))
            && let Err(err) =
                item.set_symbol(icon.symbol, &format!("{}, {description}", cc::ITEM_NAME))
        {
            log::warn!("menu bar item: {err}");
        }
        item.set_title(&icon.title);
        item.set_accessibility_label(&format!("{}, {description}", cc::ITEM_NAME));
        item.set_tooltip(Some(&format!("{}: {description}", cc::ITEM_NAME)));
    }
    bar.shown = Some(icon);
    bar.shown_description = Some(description);
}

/// "Menu bar alert" action (`flashAlert`): show the alert bell for
/// `duration_secs`, pulsing every half second when `animate`. False when
/// there is no menu bar item.
pub fn flash_alert(duration_secs: u64, animate: bool, cx: &mut App) -> bool {
    if !cx.has_global::<StatusBar>() || cx.global::<StatusBar>().item.is_none() {
        return false;
    }
    cx.global_mut::<StatusBar>().alert = Some(Alert {
        started: Instant::now(),
        duration_secs,
        animate,
    });
    update_icon(cx);
    log::info!("StatusBarController: Menu bar alert for {duration_secs}s (animate={animate})");
    true
}

/// Every 150 ms from the app timer: the icon and the item's clicks.
pub fn poll(cx: &mut App) {
    if cx.try_global::<StatusBar>().is_none() {
        return;
    }
    let (due, item_id) = {
        let bar = cx.global_mut::<StatusBar>();
        bar.ticks = bar.ticks.wrapping_add(1);
        (bar.ticks.is_multiple_of(REFRESH_EVERY), bar.item_id)
    };
    if due {
        refresh(cx);
    } else if cx.global::<StatusBar>().alert.is_some() {
        update_icon(cx);
    }
    // The popover closes with its window; forget a closed one.
    if let Some(handle) = cx.global::<StatusBar>().popover
        && cx.windows().iter().all(|w| *w != handle)
    {
        cx.global_mut::<StatusBar>().popover = None;
    }
    let _ = item_id;
}

/// A click on the item (`togglePopover`).
pub fn on_click(item: u32, frame: Option<ScreenRect>, cx: &mut App) {
    let Some(bar) = cx.try_global::<StatusBar>() else {
        return;
    };
    if bar.item_id != item {
        return;
    }
    if bar.popover.is_some() {
        close_popover(cx);
        return;
    }
    if bar
        .closed_by_blur
        .is_some_and(|at| at.elapsed() < REOPEN_GUARD)
    {
        return;
    }
    open_popover(frame, cx);
}

/// Handle an event of the platform item.
pub fn handle_event(event: StatusItemEvent, cx: &mut App) {
    if let StatusItemEvent::Clicked { item, frame } = event {
        on_click(item, frame, cx);
    }
}

fn open_popover(frame: Option<ScreenRect>, cx: &mut App) {
    let main_height = cx
        .primary_display()
        .map(|d| f32::from(d.bounds().size.height) as f64)
        .unwrap_or(900.0);
    let item = frame.map(|f| Rect {
        x: f.x,
        y: f.y,
        width: f.width,
        height: f.height,
    });
    // The screen the item is on (its center), else the main one.
    let center = item.map(|i| i.x + i.width / 2.0);
    let screen_x = cx
        .displays()
        .into_iter()
        .map(|d| {
            let b = d.bounds();
            (
                f32::from(b.origin.x) as f64,
                f32::from(b.origin.x + b.size.width) as f64,
            )
        })
        .find(|(min, max)| center.is_some_and(|c| c >= *min && c < *max))
        .or_else(|| {
            cx.primary_display().map(|d| {
                let b = d.bounds();
                (
                    f32::from(b.origin.x) as f64,
                    f32::from(b.origin.x + b.size.width) as f64,
                )
            })
        })
        .unwrap_or((0.0, 1440.0));
    let (x, y) = cc::popover_origin(item, main_height, screen_x);
    let model = panel_model(cx);
    if let Some(handle) = popover::open(x as f32, y as f32, model, cx) {
        cx.global_mut::<StatusBar>().popover = Some(handle);
    }
}

/// Close the popover, if it is open (`closePopover`).
pub fn close_popover(cx: &mut App) {
    if !cx.has_global::<StatusBar>() {
        return;
    }
    let Some(handle) = cx.global_mut::<StatusBar>().popover.take() else {
        return;
    };
    let _ = handle.update(cx, |_, window, _| window.remove_window());
}

/// The popover lost the focus: a click elsewhere closed it.
pub(crate) fn popover_blurred(cx: &mut App) {
    if cx.has_global::<StatusBar>() && cx.global::<StatusBar>().popover.is_some() {
        cx.global_mut::<StatusBar>().closed_by_blur = Some(Instant::now());
    }
    close_popover(cx);
}

/// Run what a control of the panel asks for.
pub fn run(command: PanelCommand, cx: &mut App) {
    match command {
        PanelCommand::FocusSession { tab_id } => {
            focus_tab(tab_id, cx);
            close_popover(cx);
        }
        PanelCommand::RunSnippet(id) => {
            if run_snippet(&id, cx) == SnippetOutcome::Inserted {
                close_popover(cx);
            }
        }
        PanelCommand::SetMonitoring(on) => {
            crate::settings_window::update(cx, |s| s.notifications.monitor_ai_events = on);
            update_icon(cx);
        }
        PanelCommand::OpenSettings => {
            crate::settings_window::open_at(
                Some(chau7_next_core::settings_search::SettingsSection::StartHere),
                None,
                cx,
            );
            close_popover(cx);
        }
        PanelCommand::OpenMonitoringSettings => {
            crate::settings_window::open_at(
                Some(chau7_next_core::settings_search::SettingsSection::Notifications),
                Some("eventMonitoring"),
                cx,
            );
            close_popover(cx);
        }
        PanelCommand::OpenSnippetSettings => {
            crate::settings_window::open_at(
                Some(chau7_next_core::settings_search::SettingsSection::SnippetsTools),
                Some("snippets"),
                cx,
            );
            close_popover(cx);
        }
        PanelCommand::Quit => {
            close_popover(cx);
            crate::app_actions::request_quit(cx);
        }
    }
}

/// `focusSession`: show the window and select the session's tab.
fn focus_tab(tab: u64, cx: &mut App) {
    let target = AppData::live(cx)
        .into_iter()
        .find(|(_, ws)| ws.read(cx).has_tab(tab));
    crate::app_actions::show_overlay(cx);
    if let Some((handle, workspace)) = target {
        let _ = handle.update(cx, |_, window, cx| {
            window.activate_window();
            workspace.update(cx, |ws, cx| {
                ws.command_center_focus_tab(tab, window, cx);
            });
        });
    }
    cx.activate(true);
}

/// `executeSnippet`: insert a pinned snippet in the selected tab; with no
/// window, copy its text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SnippetOutcome {
    Inserted,
    Copied,
    Unavailable,
}

fn run_snippet(id: &str, cx: &mut App) -> SnippetOutcome {
    let Some(command) = pinned_snippets(cx).into_iter().find(|c| c.id == id) else {
        return SnippetOutcome::Unavailable;
    };
    if let Some((handle, workspace)) = crate::app_actions::active_workspace(cx)
        && handle
            .update(cx, |_, _, cx| {
                workspace.update(cx, |ws, cx| ws.command_center_insert(&command.body, cx))
            })
            .is_ok_and(|inserted| inserted)
    {
        return SnippetOutcome::Inserted;
    }
    cx.write_to_clipboard(ClipboardItem::new_string(command.body));
    SnippetOutcome::Copied
}
