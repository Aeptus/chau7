//! The Debug Console (Cmd+Opt+L), the "Report an Issue" window (Cmd+Opt+I)
//! and the Changed Files panel (Cmd+Opt+G). Ports of `DebugConsoleView`,
//! `BugReportDialogView` and `ChangedFilesView`. The pure logic lives in
//! `chau7_next_core::{debug_console, bug_report, issue_privacy}`.
//!
//! # Adding to the console from another module
//!
//! The console shows what the base has: state, token optimizer, events, lag,
//! perf, logs, report, analytics and health. Modules that arrive later
//! plug into it through the functions below, all re-exported here and all
//! taking `&mut App`. Nothing needs to change in `debug/` itself.
//!
//! * [`register_panel`]`(cx, `[`Panel::new`]`("id", "Title", |window, cx| element))`
//!   adds a whole tab after Health. The render closure runs every frame while
//!   the tab is shown; [`Panel::auto_refresh`] makes the console redraw it
//!   every second. Registering an id again replaces the panel;
//!   [`unregister_panel`] removes it. Use the controls of [`ui`] so the tab
//!   looks like the others.
//! * [`record_event`]`(cx, `[`DebugEvent`]`{..})` feeds the Events tab and the
//!   "Recent events" of bug reports (500 events kept). [`clear_events`] empties it.
//! * [`set_token_optimizer_source`], [`set_analytics_source`] and
//!   [`set_claude_sessions_source`] give the Token Optimizer, Analytics and
//!   State tabs their data; until set they show an empty note.
//! * [`register_health_section`]`(cx, "Title", |cx| vec![HealthRow::new(..)])`
//!   adds a box of rows to the Health tab (relay status, MCP server...).
//! * [`open_console`]`(Some(Tab::Custom("id")), cx)` shows a given tab.

#[path = "tabs/memory.rs"]
mod memory;

pub mod changed_files;
pub mod console;
pub mod registry;
pub mod report_window;
pub mod snapshot;
pub mod tabs;
pub mod ui;
#[path = "tabs/usage.rs"]
pub mod usage;

use gpui::App;

use crate::actions::{ReportIssue, ShowChangedFiles, ShowFeatureProfiler, ToggleDebugConsole};

#[allow(unused_imports)]
pub use console::{AnalyticsMode, Tab, open as open_console};
#[allow(unused_imports)]
pub use registry::{
    AnalyticsSource, DebugEvent, HealthRow, Panel, TokenOptimizerSource, clear_events,
    record_event, register_health_section, register_panel, set_analytics_source,
    set_claude_sessions_source, set_token_optimizer_source, unregister_panel,
};

/// Bind the actions of the three windows.
pub fn init(cx: &mut App) {
    memory::register(cx);
    cx.on_action(|_: &ToggleDebugConsole, cx| console::toggle(cx));
    cx.on_action(|_: &ReportIssue, cx| report_window::open(cx));
    cx.on_action(|_: &ShowChangedFiles, cx| changed_files::open(cx));
    // The Feature Profiler of Swift is the Perf tab here.
    cx.on_action(|_: &ShowFeatureProfiler, cx| console::open(Some(Tab::Perf), cx));
}
