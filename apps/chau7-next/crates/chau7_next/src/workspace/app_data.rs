//! App-wide state shared by every window.

use std::time::Instant;

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::input::clipboard_history::ClipboardHistory;
use chau7_next_core::tabs_state::TabMeta;
use gpui::{AnyWindowHandle, App, Bounds, Entity, Global, Pixels, WeakEntity};

use super::Workspace;
use crate::pane::PaneTree;
use crate::settings::Settings;
use crate::tab_bar::TabId;

/// A window closed with Close Window. Chau7 Next removes the native window
/// but keeps its tabs and shells here until the Dock icon or a shortcut
/// brings them back in a new window.
#[derive(Clone)]
pub struct ParkedWindow {
    pub tabs: Vec<(TabMeta, Entity<PaneTree>)>,
    pub selected: usize,
    pub bounds: Bounds<Pixels>,
}

/// App-wide state: data paths, open windows, id counter.
pub struct AppData {
    pub root: DataRoot,
    pub workspaces: Vec<(AnyWindowHandle, WeakEntity<Workspace>)>,
    next_tab_id: TabId,
    pub started: Instant,
    /// Most recent first (`ClipboardHistoryManager` in Swift), saved to
    /// `DataRoot::clipboard_history_file`.
    pub clipboard: ClipboardHistory,
    /// Tab names currently listed in Window > Select Tab.
    pub menu_titles: Vec<String>,
    /// Windows closed but not ended, oldest first (APP-004).
    pub hidden: Vec<ParkedWindow>,
}

impl Global for AppData {}

impl AppData {
    pub fn new(root: DataRoot) -> Self {
        let clipboard = std::fs::read_to_string(root.clipboard_history_file())
            .map(|text| ClipboardHistory::from_json(&text))
            .unwrap_or_default();
        Self {
            root,
            workspaces: Vec::new(),
            next_tab_id: 1,
            started: Instant::now(),
            clipboard,
            menu_titles: Vec::new(),
            hidden: Vec::new(),
        }
    }

    pub fn next_tab_id(cx: &mut App) -> TabId {
        let data = cx.global_mut::<AppData>();
        let id = data.next_tab_id;
        data.next_tab_id += 1;
        id
    }

    /// Live workspaces in window order.
    pub fn live(cx: &App) -> Vec<(AnyWindowHandle, Entity<Workspace>)> {
        cx.global::<AppData>()
            .workspaces
            .iter()
            .filter_map(|(h, w)| w.upgrade().map(|w| (*h, w)))
            .collect()
    }

    /// Seconds since launch; the clock for idle-tab detection.
    pub fn now(cx: &App) -> f64 {
        cx.global::<AppData>().started.elapsed().as_secs_f64()
    }
}

/// Remember copied text for "Clipboard History".
pub fn record_clipboard(text: &str, cx: &mut App) {
    let settings = &Settings::get(cx).productivity;
    if !settings.clipboard_history_enabled || text.trim().is_empty() {
        return;
    }
    let max = settings.clipboard_history_max;
    if cx.global_mut::<AppData>().clipboard.add(text, max) {
        save_clipboard_history(cx);
    }
}

/// Change the clipboard history (pin, remove, clear, paste) and save it.
pub fn update_clipboard_history(cx: &mut App, change: impl FnOnce(&mut ClipboardHistory)) {
    change(&mut cx.global_mut::<AppData>().clipboard);
    save_clipboard_history(cx);
}

fn save_clipboard_history(cx: &App) {
    let data = cx.global::<AppData>();
    let path = data.root.clipboard_history_file();
    if let Err(err) = std::fs::write(&path, data.clipboard.to_json()) {
        log::warn!("save clipboard history: {err}");
    }
}

/// Watch the clipboard every second (Swift `AppConstants.Intervals.clipboardPoll`)
/// so copies made in other apps are recorded too. Off when the history is off.
pub fn start_clipboard_watch(cx: &mut App) {
    cx.spawn(async move |cx| {
        let mut watcher = crate::platform::pasteboard::ChangeWatcher::new();
        let mut last_text: Option<String> = None;
        loop {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(1))
                .await;
            cx.update(|cx| {
                if !Settings::get(cx).productivity.clipboard_history_enabled {
                    return;
                }
                // The change count is cheap; where it is not available, compare
                // the clipboard text with the last one seen.
                let changed = watcher.poll().ok();
                if changed == Some(false) {
                    return;
                }
                let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) else {
                    return;
                };
                if changed.is_none() && last_text.as_deref() == Some(text.as_str()) {
                    return;
                }
                last_text = Some(text.clone());
                record_clipboard(&text, cx);
            });
        }
    })
    .detach();
}
