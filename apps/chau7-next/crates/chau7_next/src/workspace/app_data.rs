//! App-wide state shared by every window.

use std::time::Instant;

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::input::clipboard_history::ClipboardHistory;
use chau7_next_core::tabs_state::TabMeta;
use gpui::{AnyWindowHandle, App, Bounds, Entity, Global, Pixels, WeakEntity};

use super::Workspace;
use crate::pane::PaneTree;
use crate::settings::Settings;
use crate::tab_bar::{NotificationStyle, TabId};

/// A window that was closed with Close Window: the Swift app only hides it
/// (`orderOut`), so its shells keep running. Chau7 Next removes the native
/// window and keeps the tabs here until the Dock icon or a shortcut brings
/// them back in a new window.
pub struct ParkedWindow {
    pub tabs: Vec<MovedTab>,
    pub selected: usize,
    pub bounds: Bounds<Pixels>,
}

/// A tab taken out of a window (moved to another one, or parked with its
/// window): its metadata, panes and the window-side state that belongs to the
/// tab (notification style, bookmarks, last AI tool seen).
pub struct MovedTab {
    pub meta: TabMeta,
    pub panes: Entity<PaneTree>,
    pub(super) notification: Option<NotificationStyle>,
    pub(super) bookmarks: Vec<super::bookmarks::Bookmark>,
    pub(super) ai_app: Option<String>,
}

impl MovedTab {
    /// A tab with no window-side state yet.
    pub fn new(meta: TabMeta, panes: Entity<PaneTree>) -> Self {
        Self {
            meta,
            panes,
            notification: None,
            bookmarks: Vec::new(),
            ai_app: None,
        }
    }
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
        let native = cx.windows();
        cx.global::<AppData>()
            .workspaces
            .iter()
            .filter(|(h, _)| native.contains(h))
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

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::AppContext;

    #[gpui::test]
    fn native_close_excludes_a_workspace_retained_by_a_deferred_task(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(|cx| {
            cx.set_global(Settings::default());
            cx.set_global(AppData::new(DataRoot::with_home(
                std::env::temp_dir()
                    .join(format!("chau7-window-lifecycle-{}", uuid::Uuid::new_v4())),
                true,
            )));
        });
        // Keep the workspace alive independently of its native window, as an
        // asynchronous continuation can do during close/startup transitions.
        let mut retained = None;
        let handle = cx.add_window(|window, cx| {
            retained = Some(cx.new(|cx| Workspace::new_empty(window, cx)));
            gpui::EmptyView
        });
        let retained = retained.unwrap();
        cx.update(|cx| {
            cx.global_mut::<AppData>()
                .workspaces
                .push((handle.into(), retained.downgrade()));
            assert_eq!(AppData::live(cx).len(), 1);
        });
        handle
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        cx.update(|cx| {
            assert!(retained.downgrade().upgrade().is_some());
            assert!(AppData::live(cx).is_empty());
        });
    }
}
