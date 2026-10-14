//! Standalone windows (Views module): the launch splash, the welcome
//! screen, and the Help window (`Views/SplashView.swift`,
//! `Views/HelpWindowController.swift`).

mod help_window;
mod launch;

use gpui::{App, Global};

use crate::actions::*;

pub use help_window::open_help;

/// Set up the Help menu actions.
pub fn register(cx: &mut App) {
    if cx.try_global::<ViewsState>().is_some() {
        return;
    }
    cx.set_global(ViewsState::default());
    cx.on_action(|_: &ShowWelcome, cx| launch::show_welcome(cx));
    cx.on_action(|_: &ShowHelp, cx| open_help(None, cx));
    cx.on_action(|_: &ShowTechnologyLicenses, cx| {
        open_help(Some(chau7_next_core::help::TECHNOLOGY_LICENSES), cx)
    });
}

/// Windows of this module that are open.
#[derive(Default)]
pub(crate) struct ViewsState {
    pub help: Option<help_window::HelpHandle>,
    pub launch: Option<launch::LaunchHandle>,
    pub splash_pending: bool,
}
impl Global for ViewsState {}

/// Called from the main timer. Nothing to poll today: the splash fades on
/// its own task.
pub fn poll(_cx: &mut App) {}

/// Initialize immediately, with a delayed splash only if no terminal is painted.
pub fn prepare_launch(cx: &mut App, start: impl FnOnce(&mut App) + 'static) {
    launch::prepare_launch(cx, start);
}

/// Keep the first-launch welcome screen after workspace initialization.
pub fn finish_launch(cx: &mut App) {
    launch::finish_launch(cx);
}

/// Dismiss the conditional splash on the first displayed terminal frame.
pub fn terminal_displayed(cx: &mut App) {
    launch::terminal_displayed(cx);
}
