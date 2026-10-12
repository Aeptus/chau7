//! One Chau7 Next window: tab bar in the titlebar, the selected tab's panes,
//! and the overlays (rename, search, snippets, command palette, hover card,
//! idle tabs). Behavior mirrors `Overlay/` in the Swift app; see
//! `spikes/gpui-tabbar/SPEC.md` for the requirement list.
//!
//! This file holds the `Workspace` struct, the tab lifecycle and `render`.
//! Each feature lives in its own file with its own `impl Workspace` block and
//! a `register_*_actions` function that `render` chains:
//!
//! | File | Feature |
//! |---|---|
//! | `app_data.rs` | app-wide state (`AppData`), clipboard history |
//! | `tab_bar_view.rs` | tab bar: tabs, groups, idle chip and popover, hover card |
//! | `drag.rs` | tab and group drag and drop, cross-window moves |
//! | `rename.rs` | rename sheet |
//! | `find.rs` | find bar |
//! | `pickers.rs` | snippets, command palette, clipboard, SSH and command history |
//! | `menus.rs` | tab and group context menus |
//! | `panes.rs` | split pane actions |
//! | `font.rs` | font size actions |
//! | `window.rs` | window actions and options |
//! | `window_actions.rs` | active directory, new tab running a command |
//! | `debug.rs` | demo tabs |
//! | `keys.rs` | use selection for find, export text, print, keyboard shortcuts |
//! | `mcp.rs` | what the MCP server reads and changes in a window |
//! | `widgets.rs` | shared `modal` and `button` |
//! | `remote_hooks.rs` | tabs and selection read by remote control |

mod ai;
mod app_data;
mod bookmarks;
mod command_center;
mod dashboard;
mod debug;
mod drag;
mod find;
mod font;
mod hover_card;
mod keys;
pub(crate) mod mcp;
mod menus;
#[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
mod native_accessibility_fixture;
#[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
mod native_restore_fixture;
mod notifications;
mod palette_window;
mod panel;
mod panes;
mod pickers;
mod provider_health;
mod remote_hooks;
mod rename;
#[cfg(all(test, unix))]
mod restore_fixture;
#[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
pub(crate) use native_accessibility_fixture::verify as verify_native_accessibility_fixture;
#[cfg(all(feature = "native-parity-fixture", target_os = "macos"))]
pub(crate) use native_restore_fixture::{
    dispose as dispose_native_fixture, verify as verify_native_restore_fixture,
    verify_keyboard as verify_native_keyboard_fixture,
};
mod restore_lifecycle;
mod shell_loading;
mod tab_bar_view;
mod tasks;
mod timeline;
pub(crate) mod widgets;
mod window;
mod window_actions;

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, Instant};

use chau7_next_core::tabs_state::{
    CloseOutcome, TabColor, TabMeta, TabsState, auto_color_for_command,
};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, Div, Entity, FocusHandle, Focusable, Pixels, Render,
    Stateful, Subscription, Task, Window, WindowBounds, div, prelude::*, px,
};
use gpui_kit::component::TitleBar;

use crate::actions::*;
use crate::pane::{PaneEvent, PaneTree};
use crate::session_store::{SavedTab, SavedWindow};
use crate::settings::Settings;
use crate::tab_bar::{NotificationStyle, TabAnimations, TabDrag, TabId};
use crate::theme::Chrome;

pub use app_data::{
    AppData, ParkedWindow, record_clipboard, start_clipboard_watch, update_clipboard_history,
};
pub use debug::TabDebugInfo;
pub use panel::reset_panel_positions;
pub use window::window_options;

use find::SearchState;
use hover_card::HoverState;
use pickers::PickerState;
use rename::RenameState;
use tab_bar_view::TabScroll;
use window::global_bounds;

#[derive(Clone, Debug, PartialEq, Eq)]
struct TabCloseFence {
    owner: uuid::Uuid,
    sessions: Vec<String>,
    busy_panes: usize,
    last_tab: bool,
}
impl TabCloseFence {
    fn admits(&self, current: &Self) -> bool {
        self.owner == current.owner
            && self.sessions == current.sessions
            && current.busy_panes <= self.busy_panes
            && self.last_tab == current.last_tab
    }
}

struct TabEntry {
    panes: Entity<PaneTree>,
    notification: Option<NotificationStyle>,
    /// Bookmarks of this tab (`BookmarkManager`), oldest first.
    bookmarks: Vec<bookmarks::Bookmark>,
    /// AI tool last seen in the tab, to color it once per change.
    ai_app: Option<String>,
    _subscription: Subscription,
}

/// Frames recorded during layout (window coordinates), used for hit tests
/// and cross-window drops without re-entering the view.
#[derive(Default)]
struct Frames {
    tabs: HashMap<TabId, Bounds<Pixels>>,
    groups: HashMap<String, Bounds<Pixels>>,
    bar: Option<Bounds<Pixels>>,
    idle_chip: Option<Bounds<Pixels>>,
}

pub struct Workspace {
    restore_lifecycle: restore_lifecycle::RestoreLifecycle,
    state: TabsState,
    entries: HashMap<TabId, TabEntry>,
    pub window_handle: Option<AnyWindowHandle>,
    frames: Rc<RefCell<Frames>>,
    /// Window bounds on screen, refreshed every frame.
    screen_bounds: Bounds<Pixels>,
    drag: Option<TabDrag>,
    anims: TabAnimations,
    /// Slide of the incoming terminal on tab switch (key 0).
    switch_anim: TabAnimations,
    scroll: TabScroll,
    hover: Option<HoverState>,
    idle_open: bool,
    rename: Option<RenameState>,
    search: Option<SearchState>,
    picker: Option<PickerState>,
    font_size: f32,
    focus_handle: FocusHandle,
    _ticker: Option<Task<()>>,
    shell_loading_tick: Option<Task<()>>,
    /// Broadcast mode: input typed in one tab goes to every included tab.
    broadcast: bool,
    broadcast_excluded: std::collections::HashSet<TabId>,
    last_bell: HashMap<TabId, Instant>,
    window_active: bool,
    /// Last title given to the native window, to skip redundant updates.
    window_title: String,
    /// The "This is the last tab" prompt is open.
    last_tab_prompt: bool,
    bookmarks_panel: Option<bookmarks::BookmarksPanel>,
    timeline_panel: Option<timeline::TimelinePanel>,
    /// API analytics task panel (PRX-014).
    task_ui: tasks::TaskUi,
    dashboard: dashboard::DashboardUi,
    next_bookmark_id: u64,
    /// Split layout, scrollback and AI sessions of the closed tabs, by tab
    /// UUID, for Reopen Closed Tab (`captureClosedTabSnapshot`).
    closed_snapshots: HashMap<uuid::Uuid, SavedTab>,
    /// (dev) Last overlay state written by `log_visual_state`.
    last_visual_state: Option<(usize, Option<TabId>, [bool; 5])>,
    /// A floating panel moved by its grab handle.
    panel_drag: Option<panel::PanelDrag>,
    /// Bumped when a panel opens, to replay its slide-in animation.
    panel_generation: usize,
    /// Recent identity roots cached for cwd fallback; refreshed with settings.
    known_repo_roots: Vec<String>,
}

impl Focusable for Workspace {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Workspace {
    /// A window with no tabs yet (tabs moved in from another window).
    pub fn new_empty(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let settings = Settings::get(cx).clone();
        let mut state = TabsState::new();
        state.new_tab_position = settings.tabs.new_tab_position;
        state.idle_threshold_secs = settings.tabs.idle_threshold_minutes as f64 * 60.0;
        state.group_idle_tabs = settings.tabs.group_idle_tabs;
        state.auto_repo_grouping = settings.tabs.auto_repo_grouping();
        // Refresh idle state and the window title once a second.
        Self::hide_on_close(window, cx);
        cx.observe_window_activation(window, |this, window, cx| {
            this.sync_restore_surfaces(window, cx);
            if window.is_window_active() {
                crate::permission_center::recheck(cx);
                this.queue_surface_reactivation(
                    chau7_next_core::session_restore::lifecycle::SurfaceEvents {
                        key: true,
                        main: true,
                        ..Default::default()
                    },
                    window,
                    cx,
                );
            }
        })
        .detach();
        cx.observe_window_visibility(window, |this, _, window, cx| {
            if !window.is_visible() {
                this.shell_loading_tick = None;
            }
            this.sync_restore_surfaces(window, cx);
            if window.is_visible() {
                this.queue_surface_reactivation(
                    chau7_next_core::session_restore::lifecycle::SurfaceEvents {
                        visible: true,
                        deminiaturized: true,
                        ..Default::default()
                    },
                    window,
                    cx,
                );
            }
            cx.notify();
        })
        .detach();
        let ticker = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        });
        Self {
            restore_lifecycle: restore_lifecycle::RestoreLifecycle::default(),
            state,
            entries: HashMap::new(),
            window_handle: None,
            frames: Rc::default(),
            screen_bounds: global_bounds(window, cx),
            drag: None,
            anims: TabAnimations::default(),
            switch_anim: TabAnimations::default(),
            scroll: TabScroll::default(),
            hover: None,
            idle_open: false,
            rename: None,
            search: None,
            picker: None,
            font_size: settings.appearance.zoomed_font_size(),
            focus_handle: cx.focus_handle(),
            _ticker: Some(ticker),
            shell_loading_tick: None,
            broadcast: false,
            broadcast_excluded: Default::default(),
            last_bell: HashMap::new(),
            window_active: true,
            window_title: String::new(),
            last_tab_prompt: false,
            bookmarks_panel: None,
            timeline_panel: None,
            task_ui: tasks::TaskUi::default(),
            dashboard: dashboard::DashboardUi::default(),
            next_bookmark_id: 1,
            closed_snapshots: HashMap::new(),
            last_visual_state: None,
            panel_drag: None,
            panel_generation: 0,
            known_repo_roots: chau7_next_core::repo_metadata::load_recent(
                &cx.global::<AppData>().root.recent_repos_file(),
            ),
        }
    }

    pub fn new(saved: Option<SavedWindow>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut this = Self::new_empty(window, cx);
        match saved {
            Some(saved) if !saved.tabs.is_empty() => {
                let selected_index = saved.selected.min(saved.tabs.len().saturating_sub(1));
                let mut selected_id = None;
                this.restore_lifecycle.startup = true;
                for (index, tab) in saved.tabs.iter().enumerate() {
                    let id = this.add_tab(Some(tab.clone()), false, window, cx);
                    if index == selected_index {
                        selected_id = Some(id);
                    }
                }
                this.restore_lifecycle.startup = false;
                // Seeding/coalescing groups can reorder tabs during hydration.
                // Select the restored identity, not its former array position.
                if let Some(id) = selected_id {
                    this.state.select(id);
                }
            }
            _ => {
                this.add_tab(None, true, window, cx);
            }
        }
        this.focus_selected(window, cx);
        this.start_deferred_identity_restore(cx);
        this
    }

    // ----- tabs ---------------------------------------------------------

    fn add_tab(
        &mut self,
        saved: Option<SavedTab>,
        select: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> TabId {
        let cwd = match &saved {
            Some(saved) => saved.cwd.clone(),
            None => self.inherited_start_directory(cx),
        };
        self.add_tab_with(saved, cwd, select, (false, true), window, cx)
    }

    /// The plus button opens at the configured default directory, without
    /// inheriting the selected tab's directory, group or insertion position.
    fn add_default_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) -> TabId {
        self.add_tab_with(None, None, true, (false, false), window, cx)
    }

    /// `newTab(at:selectNewTab:)`: a new tab started in `directory` (or the
    /// default directory); a background tab (`select` false) is not selected
    /// and does not take focus. Used by MCP (and scripting once ported).
    pub(super) fn new_tab_at(
        &mut self,
        directory: Option<PathBuf>,
        select: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> TabId {
        let at_directory = directory.is_some();
        let id = self.add_tab_with(None, directory, select, (at_directory, true), window, cx);
        if select {
            self.focus_selected(window, cx);
        }
        id
    }

    /// Check the profile auto-switch rules against tab `id`: its directory,
    /// and (read from the OS) what runs in it (PRO-005).
    fn evaluate_profile_rules(&self, id: TabId, cx: &mut Context<Self>) {
        let session = self
            .entries
            .get(&id)
            .and_then(|e| e.panes.read(cx).focused_session(cx));
        let (dir, shell_pid) = session
            .map(|s| {
                let s = s.read(cx);
                (
                    s.cwd.as_ref().map(|p| p.to_string_lossy().into_owned()),
                    Some(s.shell_pid() as u32),
                )
            })
            .unwrap_or_default();
        cx.defer(move |cx| crate::profiles::evaluate(dir, shell_pid, cx));
    }

    fn add_tab_with(
        &mut self,
        saved: Option<SavedTab>,
        cwd: Option<PathBuf>,
        select: bool,
        origin: (bool, bool),
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> TabId {
        let (at_directory, inherit_group) = origin;
        let id = AppData::next_tab_id(cx);
        let mut meta = TabMeta::new(id, self.state.next_color());
        if let Some(uuid) = saved.as_ref().and_then(|saved| saved.uuid) {
            meta.set_uuid(uuid);
        }
        let deferred = self.restore_lifecycle.startup && saved.is_some();
        let panes = cx.new(|cx| {
            if deferred {
                PaneTree::from_saved_deferred_with_owner(
                    saved.as_ref(),
                    cwd.clone(),
                    meta.uuid,
                    window,
                    cx,
                )
            } else {
                PaneTree::from_saved_with_owner(saved.as_ref(), cwd.clone(), meta.uuid, window, cx)
            }
        });
        if deferred {
            self.restore_lifecycle.pending_identity.push(id);
        }
        meta.last_activity = AppData::now(cx);
        meta.created_at = meta.last_activity;
        meta.git_root = panes
            .read(cx)
            .focused_session(cx)
            .and_then(|session| session.read(cx).git_root.clone())
            .or_else(|| {
                if deferred {
                    cwd.as_deref()
                        .and_then(|dir| {
                            chau7_next_core::tabs_state::known_repo_root(
                                dir,
                                saved.as_ref().and_then(|s| s.repo_group_id.as_deref()),
                                &self.known_repo_roots,
                            )
                        })
                        .map(PathBuf::from)
                } else {
                    cwd.as_deref().and_then(|dir| {
                        crate::repository::resolve(dir, cx)
                            .or_else(|| {
                                chau7_next_core::tabs_state::known_repo_root(
                                    dir,
                                    saved.as_ref().and_then(|s| s.repo_group_id.as_deref()),
                                    &self.known_repo_roots,
                                )
                            })
                            .map(PathBuf::from)
                    })
                }
            })
            .map(|p| p.to_string_lossy().to_string());
        if let Some(saved) = &saved {
            if let Some(uuid) = saved.uuid {
                meta.set_uuid(uuid);
            }
            meta.custom_title = saved.custom_title.clone();
            if let Some(color) = saved.color.as_deref().and_then(TabColor::from_name) {
                meta.color = color;
            }
            meta.repo_group_id = saved.repo_group_id.clone();
            if let Some(o) = saved.token_opt_override {
                meta.token_opt_override = o;
            }
            meta.manual_color_override = saved.manual_color;
            if let Some(created) = saved.created_at {
                meta.created_at = meta.last_activity - (unix_now() - created).max(0.0);
            }
        }
        panes.update(cx, |tree, cx| tree.set_owner_tab(meta.uuid, window, cx));
        self.insert_entry(id, panes.clone(), cx);
        let restored_override = meta.token_opt_override;
        if saved.is_some() || !inherit_group {
            self.state.push(meta, select);
        } else {
            let directory = panes
                .read(cx)
                .focused_session(cx)
                .and_then(|session| session.read(cx).cwd.clone())
                .or_else(|| cwd.clone());
            if let Some(directory) = directory {
                self.state.add_in_directory(meta, &directory, select);
            } else {
                self.state.push(meta, select);
            }
        }
        if let Some(root) = self.state.get(id).and_then(|tab| tab.git_root.clone())
            && !self.known_repo_roots.contains(&root)
        {
            crate::settings_window::record_recent_repo(&root, cx);
            self.known_repo_roots.push(root);
        }
        let directory = panes
            .read(cx)
            .focused_session(cx)
            .and_then(|session| session.read(cx).cwd.clone())
            .or_else(|| cwd.clone());
        self.state
            .setup_repo_group_in_directory(id, directory.as_deref(), &self.known_repo_roots);
        // A saved token optimizer override goes to the tab's shells (the
        // flag is created at their first prompt).
        if restored_override != chau7_next_core::token_optimization::TabTokenOptOverride::Default {
            self.sync_token_opt_override(id, false, cx);
        }
        if select {
            self.scroll_to_selected();
        }
        if saved.is_none() {
            let total = self.state.len();
            let directory = cwd
                .as_ref()
                .filter(|_| at_directory)
                .map(|d| d.to_string_lossy().into_owned());
            cx.defer(move |cx| {
                crate::notifications::app_events::tab_opened(total, directory.as_deref(), cx)
            });
        }
        cx.notify();
        id
    }

    fn insert_entry(&mut self, id: TabId, panes: Entity<PaneTree>, cx: &mut Context<Self>) {
        let subscription = cx.subscribe(&panes, move |this, panes, event, cx| match event {
            PaneEvent::Empty => {
                let handle = this.window_handle;
                cx.defer(move |cx| {
                    if let Some(handle) = handle {
                        let _ = handle.update(cx, |_, window, cx| {
                            if let Some((_, ws)) =
                                AppData::live(cx).into_iter().find(|(h, _)| *h == handle)
                            {
                                ws.update(cx, |ws, cx| ws.close_tab(id, true, window, cx));
                            }
                        });
                    }
                });
                let _ = panes;
            }
            PaneEvent::Activity => {
                let now = AppData::now(cx);
                this.state.touch(id, now);
                if this.state.selected() != Some(id) {
                    cx.notify();
                }
            }
            PaneEvent::MetadataChanged => {
                let session = panes.read(cx).focused_session(cx);
                let root = session
                    .as_ref()
                    .and_then(|s| s.read(cx).git_root.clone())
                    .map(|p| p.to_string_lossy().to_string());
                // `recordRecentRepo`: a tab entered a repository.
                if let Some(root) = &root
                    && this.state.get(id).and_then(|t| t.git_root.as_ref()) != Some(root)
                {
                    crate::settings_window::record_recent_repo(root, cx);
                    if !this.known_repo_roots.contains(root) {
                        this.known_repo_roots.push(root.clone());
                    }
                }
                let directory = session
                    .as_ref()
                    .and_then(|session| session.read(cx).cwd.clone());

                this.state.set_git_root_in_directory(
                    id,
                    root,
                    directory.as_deref(),
                    &this.known_repo_roots,
                );
                // `updateAutoColor`: color the tab after the AI tool it runs.
                let app = session.and_then(|s| s.read(cx).ai_app.clone());
                if let Some(entry) = this.entries.get_mut(&id)
                    && entry.ai_app != app
                {
                    entry.ai_app = app.clone();
                    if let Some(app) = app
                        && Settings::get(cx).tabs.auto_tab_theme
                        && let Some(color) = auto_color_for_command(
                            &app.to_lowercase(),
                            &Settings::get(cx).ai.color_rules(),
                        )
                        && let Some(meta) = this.state.get_mut(id)
                    {
                        meta.auto_color = Some(color);
                    }
                }
                // Profile auto-switch rules look at the tab in use.
                if this.state.selected() == Some(id) {
                    this.evaluate_profile_rules(id, cx);
                }
                cx.notify();
            }
            PaneEvent::Bell => {
                // `bellRateLimitSeconds` (0.1 s) in Swift.
                let now = Instant::now();
                if this
                    .last_bell
                    .get(&id)
                    .is_some_and(|t| now.duration_since(*t) < Duration::from_millis(100))
                {
                    return;
                }
                this.last_bell.insert(id, now);
                if this.state.selected() != Some(id)
                    && Settings::get(cx).terminal.bell_enabled
                    && let Some(entry) = this.entries.get_mut(&id)
                {
                    entry.notification = Some(NotificationStyle::attention());
                    cx.notify();
                }
            }
            PaneEvent::Input(bytes) => {
                crate::notifications::record_user_activity(cx);
                if this.broadcast && !this.broadcast_excluded.contains(&id) {
                    let targets: Vec<_> = this
                        .entries
                        .iter()
                        .filter(|(tab, _)| **tab != id && !this.broadcast_excluded.contains(tab))
                        .map(|(_, e)| e.panes.clone())
                        .collect();
                    for panes in targets {
                        PaneTree::send_input(&panes, bytes, cx);
                    }
                }
            }
            PaneEvent::Ai { .. } | PaneEvent::ChangedFiles(_) | PaneEvent::PermissionResolved => {
                this.handle_ai_pane_event(id, event, cx);
            }
            PaneEvent::CommandStarted(command) => {
                // A program started (`ssh host`, a tool): check the rules once
                // it is running.
                if this.state.selected() == Some(id) {
                    cx.spawn(async move |this, cx| {
                        cx.background_executor()
                            .timer(Duration::from_millis(500))
                            .await;
                        let _ = this.update(cx, |this, cx| {
                            if this.state.selected() == Some(id) {
                                this.evaluate_profile_rules(id, cx);
                            }
                        });
                    })
                    .detach();
                }
                // `commandStarted` / `updateAutoColor`: the command line picks
                // the tab color (AI tool registry, then custom detection rules).
                let settings = Settings::get(cx);
                if settings.tabs.auto_tab_theme
                    && let Some(color) = auto_color_for_command(command, &settings.ai.color_rules())
                    && let Some(meta) = this.state.get_mut(id)
                {
                    meta.auto_color = Some(color);
                    cx.notify();
                }
            }
            PaneEvent::CommandFinished(code) => {
                this.offer_explain(id, *code, cx);
                // Shell events (`ShellEventDetector`) come from the session's
                // monitor as `PaneEvent::Ai` and reach the notification engine
                // through `ai::events_out`.
                // Background tabs show how their last command ended until selected.
                if this.state.selected() != Some(id)
                    && let Some(entry) = this.entries.get_mut(&id)
                {
                    entry.notification = Some(if *code == 0 {
                        NotificationStyle::success()
                    } else {
                        NotificationStyle::error()
                    });
                    cx.notify();
                }
            }
        });
        self.entries.insert(
            id,
            TabEntry {
                panes,
                notification: None,
                bookmarks: Vec::new(),
                ai_app: None,
                _subscription: subscription,
            },
        );
    }

    /// Take every tab out of this window so its shells keep running while the
    /// window is closed (Close Window only hides the window in Swift).
    pub fn park_tabs(&mut self, window: &Window) -> Option<ParkedWindow> {
        if self.state.is_empty() {
            return None;
        }
        let bounds = match window.window_bounds() {
            WindowBounds::Windowed(b)
            | WindowBounds::Maximized(b)
            | WindowBounds::Fullscreen(b) => b,
        };
        let selected = self
            .state
            .selected()
            .and_then(|id| self.state.index_of(id))
            .unwrap_or(0);
        let ids: Vec<TabId> = self.state.tabs().iter().map(|t| t.id).collect();
        let mut tabs = Vec::new();
        for id in ids {
            if let (Some(entry), Some(meta)) = (self.entries.remove(&id), self.state.take(id)) {
                tabs.push((meta, entry.panes));
            }
        }
        Some(ParkedWindow {
            tabs,
            selected,
            bounds,
        })
    }

    /// Keep Window > Select Tab in step with this window's tabs.
    fn sync_window_menu(&self, cx: &mut Context<Self>) {
        let titles: Vec<String> = self
            .state
            .tabs()
            .iter()
            .map(|t| self.tab_title(t.id, cx))
            .collect();
        if cx.global::<AppData>().menu_titles == titles {
            return;
        }
        cx.global_mut::<AppData>().menu_titles = titles.clone();
        cx.defer(move |cx| cx.set_menus(crate::actions::app_menus(&titles)));
    }

    /// Names of the processes running in any tab of this window.
    pub fn running_process_names(&self, cx: &App) -> Vec<String> {
        self.entries
            .values()
            .flat_map(|e| e.panes.read(cx).running_process_names(cx))
            .collect()
    }

    /// AppKit editors must never cover GPUI overlays or modal interactions.
    #[cfg(target_os = "macos")]
    pub(crate) fn native_editor_allowed(&self, cx: &App) -> bool {
        self.hover.is_none()
            && !self.idle_open
            && self.rename.is_none()
            && self.search.is_none()
            && self.picker.is_none()
            && !self.last_tab_prompt
            && self.bookmarks_panel.is_none()
            && self.timeline_panel.is_none()
            && !self.dashboard.is_open()
            && self.state.selected().is_none_or(|id| {
                self.selected_panes()
                    .and_then(|p| p.read(cx).focused_session(cx))
                    .map(|s| s.read(cx).tab_identifier.clone())
                    .is_none_or(|tab| {
                        crate::proxy::candidate_for(&tab, cx).is_none()
                            && crate::proxy::task_for(&tab, cx).is_none()
                    })
                    && cx
                        .try_global::<crate::ai::explain::ExplainPanels>()
                        .is_none_or(|p| !p.0.contains_key(&id))
            })
    }

    pub(crate) fn selected_panes(&self) -> Option<Entity<PaneTree>> {
        self.state
            .selected()
            .and_then(|id| self.entries.get(&id))
            .map(|e| e.panes.clone())
    }

    fn selected_cwd(&self, cx: &App) -> Option<PathBuf> {
        self.selected_panes().and_then(|p| p.read(cx).cwd(cx))
    }

    fn focus_selected(&mut self, window: &mut Window, cx: &mut App) {
        self.record_restore_selection(cx);
        self.sync_restore_surfaces(window, cx);
        if let Some(panes) = self.selected_panes() {
            if let Some(meta) = self.state.selected().and_then(|id| self.state.get(id)) {
                panes.update(cx, |tree, _| {
                    tree.set_restore_override(meta.token_opt_override)
                });
            }

            let deferred = panes.read(cx).is_deferred();
            PaneTree::focus_entity(&panes, window, cx);
            // Parked tabs had no shells when overrides were first restored.
            if deferred && let Some(meta) = self.state.selected().and_then(|id| self.state.get(id))
            {
                for view in panes.read(cx).views() {
                    let session = view.read(cx).session.clone();
                    session.update(cx, |session, _| {
                        session.set_token_opt_override(meta.token_opt_override, false)
                    });
                }
            }
        }
        self.reveal_selected_surface(
            chau7_next_core::session_restore::lifecycle::RevealTrigger::Selection,
            window,
            cx,
        );
    }

    pub fn select_tab(&mut self, id: TabId, window: &mut Window, cx: &mut Context<Self>) {
        self.dashboard.dismiss();
        cx.notify();
        let previous = self.state.selected().and_then(|p| self.state.index_of(p));
        if self.state.select(id) {
            // The incoming terminal slides 30 pt in from the side of travel
            // (spring 0.2 s, damping 0.9), unless Reduce Motion is on.
            if let (Some(from), Some(to)) = (previous, self.state.index_of(id))
                && from != to
                && !crate::platform::system::reduce_motion()
            {
                let direction = if to > from { 1.0 } else { -1.0 };
                self.switch_anim.start(0, 30.0 * direction, 0.2, 0.9);
            }
            // The user saw it: clear the style unless it is persistent
            // (permission requests stay until answered).
            if let Some(entry) = self.entries.get_mut(&id)
                && !entry.notification.as_ref().is_some_and(|n| n.persistent)
            {
                entry.notification = None;
            }
            if self.rename.as_ref().is_some_and(|r| r.tab != id) {
                self.rename = None;
            }
            self.hover = None;
            self.idle_open = false;
            self.scroll_to_selected();
            self.refresh_search(cx);
            self.focus_selected(window, cx);
            cx.notify();
        }
    }

    /// Close a tab from the UI (Cmd+W, close button, menus), asking first
    /// like `closeTab(id:)`: the last tab asks "Close Window" or "New Tab";
    /// other tabs ask when they run processes (`warnOnCloseWithRunningProcess`)
    /// or always (`alwaysWarnOnTabClose`, `[general] confirm_close`).
    fn request_close_tab(&mut self, id: TabId, window: &mut Window, cx: &mut Context<Self>) {
        self.close_with_confirmation(id, window, cx).detach();
    }

    fn tab_close_fence(&self, id: TabId, cx: &App) -> Option<TabCloseFence> {
        let meta = self.state.get(id)?;
        let panes = self.entries.get(&id)?.panes.read(cx);
        Some(TabCloseFence {
            owner: meta.uuid,
            sessions: panes
                .pane_sessions(cx)
                .iter()
                .map(|(_, session)| session.read(cx).tab_identifier.clone())
                .collect(),
            busy_panes: panes.running_process_count(cx),
            last_tab: self.state.len() == 1,
        })
    }

    /// Like [`Self::request_close_tab`]; the task ends once the tab is
    /// closed or the user answered (closing a group asks tab by tab).
    fn close_with_confirmation(
        &mut self,
        id: TabId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Task<()> {
        if self.last_tab_prompt || self.state.get(id).is_none() {
            return Task::ready(());
        }
        if self.state.len() == 1 {
            return self.confirm_close_last_tab(id, window, cx);
        }
        let tabs = &Settings::get(cx).tabs;
        let (warn_running, warn_always) = (tabs.warn_on_close_running, tabs.confirm_close);
        let running = self
            .entries
            .get(&id)
            .map(|e| e.panes.read(cx).running_process_count(cx))
            .unwrap_or(0);
        let warn_for_process = warn_running && running > 0;
        if !warn_for_process && !warn_always {
            self.close_tab(id, false, window, cx);
            return Task::ready(());
        }
        let shown = if warn_for_process { running } else { 0 };
        let (message, detail) = close_tab_prompt_text(shown);
        // GPUI prompts have no suppression checkbox: "Don't ask again" is a
        // third button (Swift shows it only in "always warn" mode when no
        // process runs).
        let suppressible = warn_always && !warn_for_process;
        let buttons: &[&str] = if suppressible {
            &["Close Tab", "Cancel", "Close Tab and Don't Ask Again"]
        } else {
            &["Close Tab", "Cancel"]
        };
        let Some(fence) = self.tab_close_fence(id, cx) else {
            return Task::ready(());
        };
        self.last_tab_prompt = true;
        let answer = crate::l10n::prompt(
            window,
            gpui::PromptLevel::Warning,
            &message,
            Some(&detail),
            buttons,
            cx,
        );
        cx.spawn_in(window, async move |this, cx| {
            let answer = answer.await.ok();
            let _ = this.update_in(cx, |this, window, cx| {
                this.last_tab_prompt = false;
                if !matches!(answer, Some(0) | Some(2))
                    || !this
                        .tab_close_fence(id, cx)
                        .is_some_and(|current| fence.admits(&current))
                {
                    return;
                }
                if answer == Some(2) {
                    crate::settings_window::update(cx, |s| s.tabs.confirm_close = false);
                }
                this.close_tab(id, false, window, cx);
            });
        })
    }

    /// `confirmCloseLastTab`: "Close Window" closes the window, "New Tab"
    /// replaces the tab with a fresh one in the same directory.
    fn confirm_close_last_tab(
        &mut self,
        id: TabId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Task<()> {
        if self.last_tab_prompt {
            return Task::ready(());
        }
        let Some(fence) = self.tab_close_fence(id, cx) else {
            return Task::ready(());
        };
        self.last_tab_prompt = true;
        self.hover = None;
        let answer = crate::l10n::prompt(
            window,
            gpui::PromptLevel::Info,
            "This is the last tab",
            Some("Do you want to close the window, or keep it open with a new tab?"),
            &["Close Window", "New Tab"],
            cx,
        );
        cx.spawn_in(window, async move |this, cx| {
            let answer = answer.await.ok();
            let _ = this.update_in(cx, |this, window, cx| {
                this.last_tab_prompt = false;
                if !matches!(answer, Some(0) | Some(1))
                    || !this
                        .tab_close_fence(id, cx)
                        .is_some_and(|current| fence.admits(&current))
                {
                    return;
                }
                if answer == Some(0) {
                    log::info!("closeTab: last tab - user chose to close window");
                    this.entries.remove(&id);
                    window.remove_window();
                } else {
                    log::info!("closeTab: last tab - replacing with fresh tab");
                    this.replace_with_fresh_tab(id, window, cx);
                }
            });
        })
    }

    /// `makeFreshTab`: first palette color, no title, started in the
    /// closed tab's directory when new tabs use the current directory.
    /// Close several tabs one after the other, each through the normal
    /// confirmations (Close Group, Close All Idle).
    pub(super) fn close_tabs_confirming(
        &mut self,
        ids: Vec<TabId>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.spawn_in(window, async move |this, cx| {
            for id in ids {
                let Ok(task) = this.update_in(cx, |this, window, cx| {
                    this.close_with_confirmation(id, window, cx)
                }) else {
                    return;
                };
                task.await;
            }
        })
        .detach();
    }

    fn replace_with_fresh_tab(&mut self, id: TabId, window: &mut Window, cx: &mut Context<Self>) {
        if self.state.get(id).is_none() {
            return;
        }
        let cwd = self.inherited_start_directory(cx);
        let new_id = AppData::next_tab_id(cx);
        let mut meta = TabMeta::new(new_id, TabColor::ALL[0]);
        let panes = cx.new(|cx| PaneTree::new_with_owner(cwd.clone(), meta.uuid, window, cx));
        meta.last_activity = AppData::now(cx);
        meta.git_root = cwd.as_deref().and_then(|dir| {
            crate::repository::resolve(dir, cx).or_else(|| {
                chau7_next_core::tabs_state::known_repo_root(dir, None, &self.known_repo_roots)
            })
        });
        panes.update(cx, |tree, cx| tree.set_owner_tab(meta.uuid, window, cx));
        self.entries.remove(&id);
        self.insert_entry(new_id, panes, cx);
        self.state.replace(id, meta);
        if self.rename.as_ref().is_some_and(|r| r.tab == id) {
            self.rename = None;
        }
        self.focus_selected(window, cx);
        cx.notify();
    }

    /// `inheritedStartDirectory`: the selected tab's directory when
    /// `newTabsUseCurrentDirectory` is on and it still exists.
    fn inherited_start_directory(&self, cx: &App) -> Option<PathBuf> {
        if !Settings::get(cx).tabs.new_tabs_use_current_directory {
            return None;
        }
        self.selected_cwd(cx).filter(|p| p.is_dir())
    }

    /// Close a tab without asking (already confirmed, or its shell exited).
    /// The window's last tab still asks "Close Window" or "New Tab".
    pub fn close_tab(
        &mut self,
        id: TabId,
        from_exit: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.hover = None;
        if self.state.len() == 1 && self.state.get(id).is_some() {
            log::info!("closeTab: last tab (from_exit={from_exit})");
            self.confirm_close_last_tab(id, window, cx).detach();
            return;
        }
        if self.rename.as_ref().is_some_and(|r| r.tab == id) {
            self.rename = None;
        }
        let cwd = self.entries.get(&id).and_then(|e| e.panes.read(cx).cwd(cx));
        let snapshot = self.closed_tab_snapshot(id, cwd.clone(), cx);
        let closed_uuid = self.state.get(id).map(|meta| meta.uuid);
        match self
            .state
            .close(id, cwd.map(|p| p.to_string_lossy().to_string()))
        {
            CloseOutcome::NotFound => {}
            CloseOutcome::Closed => {
                if let Some(uuid) = closed_uuid {
                    crate::mcp::control::forget_closed_tab(&uuid.to_string());
                }
                if let Some((uuid, snapshot)) = snapshot {
                    self.closed_snapshots.insert(uuid, snapshot);
                    let kept: std::collections::HashSet<uuid::Uuid> = self
                        .state
                        .closed_tabs()
                        .iter()
                        .map(|c| c.meta.uuid)
                        .collect();
                    self.closed_snapshots.retain(|uuid, _| kept.contains(uuid));
                }
                self.entries.remove(&id);
                self.focus_selected(window, cx);
                let remaining = self.state.len();
                cx.defer(move |cx| crate::notifications::app_events::tab_closed(remaining, cx));
                cx.notify();
            }
            CloseOutcome::CloseWindow => self.confirm_close_last_tab(id, window, cx).detach(),
        }
    }

    /// `closeOtherTabs`: one confirmation for all the other tabs (running
    /// processes, or "always warn"), then close them.
    fn close_other_tabs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.last_tab_prompt {
            return;
        }
        let Some(current) = self.state.selected() else {
            return;
        };
        let others: Vec<TabId> = self
            .state
            .tabs()
            .iter()
            .map(|t| t.id)
            .filter(|id| *id != current)
            .collect();
        if others.is_empty() {
            return;
        }
        let counts: Vec<usize> = others
            .iter()
            .filter_map(|id| self.entries.get(id))
            .map(|e| e.panes.read(cx).running_process_count(cx))
            .collect();
        let processes: usize = counts.iter().sum();
        let tabs_with = counts.iter().filter(|c| **c > 0).count();
        let tabs = &Settings::get(cx).tabs;
        let warn_for_process = tabs.warn_on_close_running && processes > 0;
        let warn_always = tabs.confirm_close;
        let target_fences = others
            .iter()
            .filter_map(|id| self.tab_close_fence(*id, cx).map(|fence| (*id, fence)))
            .collect::<HashMap<_, _>>();
        let close_all = move |this: &mut Self, window: &mut Window, cx: &mut Context<Self>| {
            // Rightmost first, so the remaining indexes stay valid.
            for id in others.iter().rev() {
                if *id != current {
                    this.close_tab(*id, false, window, cx);
                }
            }
        };
        if !warn_for_process && !warn_always {
            close_all(self, window, cx);
            return;
        }
        let (message, detail) = close_other_tabs_prompt_text(counts.len(), processes, tabs_with);
        let suppressible = warn_always && processes == 0;
        let buttons: &[&str] = if suppressible {
            &["Close Tabs", "Cancel", "Close Tabs and Don't Ask Again"]
        } else {
            &["Close Tabs", "Cancel"]
        };
        self.last_tab_prompt = true;
        let answer = crate::l10n::prompt(
            window,
            gpui::PromptLevel::Warning,
            &message,
            Some(&detail),
            buttons,
            cx,
        );
        cx.spawn_in(window, async move |this, cx| {
            let answer = answer.await.ok();
            let _ = this.update_in(cx, |this, window, cx| {
                this.last_tab_prompt = false;
                let remaining = target_fences
                    .iter()
                    .filter(|(id, _)| this.state.get(**id).is_some())
                    .collect::<Vec<_>>();
                if !matches!(answer, Some(0) | Some(2))
                    || this.state.selected() != Some(current)
                    || this.state.get(current).is_none()
                    || remaining.is_empty()
                    || !remaining.iter().all(|(id, fence)| {
                        this.tab_close_fence(**id, cx)
                            .is_some_and(|current| fence.admits(&current))
                    })
                {
                    return;
                }
                if answer == Some(2) {
                    crate::settings_window::update(cx, |s| s.tabs.confirm_close = false);
                }
                close_all(this, window, cx);
            });
        })
        .detach();
    }

    /// `reopenClosedTab`: the last closed tab comes back at its position
    /// with its title, color, directory, split layout, scrollback and AI
    /// session resume, under the same tab UUID.
    fn reopen_closed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let new_id = AppData::next_tab_id(cx);
        let Some(entry) = self.state.reopen_closed(new_id) else {
            return;
        };
        if let Some(meta) = self.state.get_mut(new_id) {
            let uuid = meta.uuid;
            meta.set_uuid(uuid);
        }
        let snapshot = self.closed_snapshots.remove(&entry.meta.uuid);
        let cwd = entry.directory.map(PathBuf::from);
        let panes = cx.new(|cx| {
            PaneTree::from_saved_with_owner(snapshot.as_ref(), cwd, entry.meta.uuid, window, cx)
        });
        if let Some(meta) = self.state.get(new_id) {
            panes.update(cx, |tree, cx| tree.set_owner_tab(meta.uuid, window, cx));
        }
        self.insert_entry(new_id, panes, cx);
        self.focus_selected(window, cx);
        cx.notify();
    }

    /// What Reopen Closed Tab needs of a tab about to close: its split
    /// layout and each pane's scrollback (saved to the scrollback folder) and
    /// AI session (`captureClosedTabSnapshot`).
    fn closed_tab_snapshot(
        &self,
        id: TabId,
        cwd: Option<PathBuf>,
        cx: &App,
    ) -> Option<(uuid::Uuid, SavedTab)> {
        let meta = self.state.get(id)?;
        let entry = self.entries.get(&id)?;
        let capture =
            crate::restore::capture_tab(&entry.panes, &mut std::collections::HashSet::new(), cx);
        Some((
            meta.uuid,
            SavedTab {
                uuid: Some(meta.uuid),
                cwd,
                custom_title: meta.custom_title.clone(),
                color: Some(meta.color.name().to_string()),
                repo_group_id: meta.repo_group_id.clone(),
                token_opt_override: None,
                created_at: None,
                manual_color: meta.manual_color_override,
                layout: capture.layout,
                focused_pane: capture.focused,
                panes: capture.panes,
            },
        ))
    }

    /// Panes of the closed tabs whose scrollback file must be kept.
    pub fn closed_scrollback_panes(&self) -> Vec<crate::pane::PaneId> {
        self.closed_snapshots
            .values()
            .flat_map(|t| &t.panes)
            .filter(|p| p.scrollback)
            .map(|p| p.id)
            .collect()
    }

    /// Remove a tab and hand back its panes (cross-window move).
    /// Take a tab out for another window (`extractTabForWindowTransfer`).
    /// The window emptied this way is put away, like a hidden Swift window:
    /// the next Dock click or Show Chau7 brings it back at the same place
    /// with a fresh tab (`ensureFreshTabIfNeeded`).
    fn take_tab(
        &mut self,
        id: TabId,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<(TabMeta, Entity<PaneTree>)> {
        let entry = self.entries.remove(&id)?;
        let meta = self.state.take(id)?;
        if self.state.is_empty() {
            let bounds = match window.window_bounds() {
                WindowBounds::Windowed(b)
                | WindowBounds::Maximized(b)
                | WindowBounds::Fullscreen(b) => b,
            };
            cx.global_mut::<AppData>().hidden.push(ParkedWindow {
                tabs: Vec::new(),
                selected: 0,
                bounds,
            });
            window.remove_window();
        }
        Some((meta, entry.panes))
    }

    fn adopt_tab(
        &mut self,
        mut meta: TabMeta,
        panes: Entity<PaneTree>,
        select: bool,
        cx: &mut Context<Self>,
    ) {
        // Keep ids unique app-wide: the tab gets a fresh id in its new window,
        // and keeps its stable UUID (MCP, events, remote control).
        let id = AppData::next_tab_id(cx);
        meta.id = id;
        let uuid = meta.uuid;
        meta.set_uuid(uuid);
        self.insert_entry(id, panes, cx);
        self.state.push(meta, select);
        cx.notify();
    }

    pub fn adopt_tab_public(
        &mut self,
        meta: TabMeta,
        panes: Entity<PaneTree>,
        select: bool,
        cx: &mut Context<Self>,
    ) {
        self.adopt_tab(meta, panes, select, cx);
    }

    pub fn focus_selected_public(&mut self, window: &mut Window, cx: &mut App) {
        self.focus_selected(window, cx);
    }

    /// Current TabTitleFormatter: custom, AI, Vite, localized fallback.
    pub fn tab_title(&self, id: TabId, cx: &App) -> String {
        let Some(meta) = self.state.get(id) else {
            return String::new();
        };
        let panes = self.entries.get(&id).map(|entry| entry.panes.read(cx));
        let session = panes.and_then(|p| p.focused_session(cx));
        let ai = session
            .as_ref()
            .and_then(|s| s.read(cx).ai_display_app_name())
            .or_else(|| {
                panes
                    .and_then(|tree| tree.deferred_saved())
                    .and_then(|saved| saved.focused_terminal())
                    .and_then(|pane| {
                        chau7_next_core::shell_session::display_name_from_provider(
                            pane.ai_provider.as_deref(),
                        )
                    })
            });
        let dev_server = session
            .as_ref()
            .and_then(|s| s.read(cx).dev_server().map(|d| d.name.clone()));
        let fallback = crate::l10n::tr(if panes.is_some_and(|p| !p.has_terminal()) {
            "Editor"
        } else {
            "Shell"
        });
        chau7_next_core::tab_bar_text::resolved_title(
            meta.custom_title.as_deref(),
            ai.as_deref(),
            dev_server.as_deref(),
            &fallback,
        )
    }

    // ----- notification styles -----------------------------------------

    /// `applyNotificationStyle(to:stylePreset:config:)`: style a tab from a
    /// notification action (preset or custom, "clear" removes it). Returns
    /// whether the tab exists.
    pub fn apply_notification_style(
        &mut self,
        id: TabId,
        preset: &str,
        config: &HashMap<String, String>,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(entry) = self.entries.get_mut(&id) else {
            return false;
        };
        let style = chau7_next_core::tab_style::build_notification_style(preset, config);
        if entry.notification != style {
            log::info!("Tab notification style for tab {id}: {preset}");
            entry.notification = style;
            cx.notify();
        }
        true
    }

    /// `clearPersistentStyle(for:)`: the permission was answered.
    pub fn clear_persistent_style(&mut self, id: TabId, cx: &mut Context<Self>) -> bool {
        let Some(entry) = self.entries.get_mut(&id) else {
            return false;
        };
        if entry.notification.as_ref().is_some_and(|n| n.persistent) {
            entry.notification = None;
            cx.notify();
            return true;
        }
        false
    }

    /// `setBadge` action: badge text and color on the tab's style (shown in
    /// the hover card summary; Swift does not draw it on the chip).
    pub fn set_tab_badge(
        &mut self,
        id: TabId,
        text: Option<String>,
        color: Option<crate::tab_bar::StyleColor>,
        cx: &mut Context<Self>,
    ) {
        if let Some(entry) = self.entries.get_mut(&id) {
            let style = entry.notification.get_or_insert_with(Default::default);
            style.badge_text = text;
            style.badge_color = color;
            cx.notify();
        }
    }

    // ----- persistence --------------------------------------------------

    pub fn snapshot(&self, window: &Window, cx: &App) -> SavedWindow {
        // AI session ids already given to a pane of this window.
        let mut claimed = std::collections::HashSet::new();
        let tabs = self
            .state
            .tabs()
            .iter()
            .map(|meta| {
                let capture = self
                    .entries
                    .get(&meta.id)
                    .map(|e| crate::restore::capture_tab(&e.panes, &mut claimed, cx));
                SavedTab {
                    uuid: Some(meta.uuid),
                    cwd: self
                        .entries
                        .get(&meta.id)
                        .and_then(|e| e.panes.read(cx).cwd(cx)),
                    custom_title: meta.custom_title.clone(),
                    color: Some(meta.color.name().to_string()),
                    repo_group_id: meta.repo_group_id.clone(),
                    token_opt_override: (meta.token_opt_override
                        != chau7_next_core::token_optimization::TabTokenOptOverride::Default)
                        .then_some(meta.token_opt_override),
                    created_at: Some(unix_now() - (AppData::now(cx) - meta.created_at).max(0.0)),
                    manual_color: meta.manual_color_override,
                    layout: capture.as_ref().and_then(|c| c.layout.clone()),
                    focused_pane: capture.as_ref().and_then(|c| c.focused),
                    panes: capture.map(|c| c.panes).unwrap_or_default(),
                }
            })
            .collect();
        let selected = self
            .state
            .selected()
            .and_then(|id| self.state.index_of(id))
            .unwrap_or(0);
        let bounds = match window.window_bounds() {
            WindowBounds::Windowed(b)
            | WindowBounds::Maximized(b)
            | WindowBounds::Fullscreen(b) => b,
        };
        SavedWindow {
            tabs,
            selected,
            x: f32::from(bounds.origin.x),
            y: f32::from(bounds.origin.y),
            width: f32::from(bounds.size.width),
            height: f32::from(bounds.size.height),
        }
    }

    pub fn reload_settings(&mut self, cx: &mut Context<Self>) {
        let settings = Settings::get(cx).clone();
        self.state.new_tab_position = settings.tabs.new_tab_position;
        self.state.idle_threshold_secs = settings.tabs.idle_threshold_minutes as f64 * 60.0;
        self.state.group_idle_tabs = settings.tabs.group_idle_tabs;
        let directories = self
            .entries
            .iter()
            .filter_map(|(id, entry)| {
                entry
                    .panes
                    .read(cx)
                    .focused_session(cx)
                    .and_then(|session| session.read(cx).cwd.clone())
                    .map(|directory| (*id, directory))
            })
            .collect::<Vec<_>>();
        self.known_repo_roots = chau7_next_core::repo_metadata::load_recent(
            &cx.global::<AppData>().root.recent_repos_file(),
        );
        self.state.set_auto_repo_grouping_in_directories(
            settings.tabs.auto_repo_grouping(),
            &directories,
            &self.known_repo_roots,
        );
        self.font_size = settings.appearance.zoomed_font_size();
        for entry in self.entries.values() {
            entry.panes.update(cx, |p, cx| p.reload_settings(cx));
        }
        cx.notify();
    }
}

/// Tab lifecycle and selection actions, and broadcast input.
fn register_tab_actions(div: Stateful<Div>, cx: &mut Context<Workspace>) -> Stateful<Div> {
    div.on_action(cx.listener(|this, _: &NewTab, window, cx| {
        this.add_tab(None, true, window, cx);
        this.focus_selected(window, cx);
    }))
    .on_action(cx.listener(|this, _: &CloseTab, window, cx| {
        if let Some(id) = this.state.selected() {
            this.request_close_tab(id, window, cx);
        }
    }))
    .on_action(cx.listener(|this, _: &ToggleBroadcast, _, cx| {
        this.broadcast = !this.broadcast;
        log::info!("broadcast mode: {}", this.broadcast);
        cx.notify();
    }))
    .on_action(cx.listener(|this, _: &ReopenClosedTab, window, cx| this.reopen_closed(window, cx)))
    .on_action(
        cx.listener(|this, _: &CloseOtherTabs, window, cx| this.close_other_tabs(window, cx)),
    )
    .on_action(cx.listener(|this, _: &MoveTabLeft, _, cx| {
        if this.state.move_selected(-1) {
            this.scroll_to_selected();
            cx.notify();
        }
    }))
    .on_action(cx.listener(|this, _: &MoveTabRight, _, cx| {
        if this.state.move_selected(1) {
            this.scroll_to_selected();
            cx.notify();
        }
    }))
    .on_action(cx.listener(|this, _: &NextTab, window, cx| {
        this.state.select_next();
        if let Some(id) = this.state.selected() {
            this.select_tab(id, window, cx);
        }
    }))
    .on_action(cx.listener(|this, _: &PreviousTab, window, cx| {
        this.state.select_previous();
        if let Some(id) = this.state.selected() {
            this.select_tab(id, window, cx);
        }
    }))
    .on_action(cx.listener(|this, action: &SelectTabNumber, window, cx| {
        this.state.select_number(action.0);
        if let Some(id) = this.state.selected() {
            this.select_tab(id, window, cx);
        }
    }))
}

impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.screen_bounds = global_bounds(window, cx);
        self.sync_restore_surfaces(window, cx);
        self.window_active = window.is_window_active();
        // (dev) A trace line whenever the tabs or the open panel change.
        let picker = self.picker.as_ref().map(|p| p.kind);
        let visual = (
            self.state.len(),
            self.state.selected(),
            [
                self.search.is_some(),
                self.rename.is_some(),
                self.bookmarks_panel.is_some(),
                self.timeline_panel.is_some(),
                picker.is_some(),
            ],
        );
        if self.last_visual_state != Some(visual) {
            let reason = if self.last_visual_state.is_none() {
                "init"
            } else {
                "changed"
            };
            self.last_visual_state = Some(visual);
            self.log_visual_state(reason, cx);
        }
        window::apply_window_style(window, cx);
        if self.window_active {
            self.sync_window_menu(cx);
        }
        if self.anims.tick() | self.switch_anim.tick() | self.tick_scroll() {
            window.request_animation_frame();
        }
        let chrome = Chrome::get(cx);
        if let Some(id) = self.state.selected() {
            let title = self.tab_title(id, cx);
            let title = format!("{title} - Chau7 Next");
            if title != self.window_title {
                window.set_window_title(&title);
                self.window_title = title;
            }
        }
        // APR-011: the tab bar and title bar are a dark HUD whatever the
        // color scheme (on macOS; see `tab_bar_uses_hud`).
        let bar_chrome = Chrome::tab_bar(cx);
        let tab_bar = self
            .tab_bar_visible(cx)
            .then(|| self.render_tab_bar(bar_chrome, cx));
        let content = self.selected_panes();
        let switch_offset = self.switch_anim.offset(0);
        let loading = self.render_shell_loading(chrome, cx);
        self.update_shell_loading_timer(window, cx);
        let hover_card = self.render_hover_card(chrome, cx);
        let explain = self.render_explain(chrome, cx);
        let idle_popover = self.render_idle_popover(chrome, cx);
        let rename = self.render_rename(chrome, cx);
        let search = self.render_search(chrome, cx);
        let bookmarks = self.render_bookmarks(chrome, cx);
        let timeline = self.render_timeline(chrome, cx);
        let tasks = self.render_tasks(chrome, window, cx);
        let dashboard = self.render_dashboard(chrome, window, cx);
        let picker = self.render_picker(chrome, cx);
        let shortcut_hint = self.render_shortcut_hint(chrome, cx);
        let drag_listener = self.drag_listener(cx);
        let provider_health_border = self.provider_health_border(cx);

        div()
            .id("workspace")
            .key_context("Workspace")
            .track_focus(&self.focus_handle)
            .size_full()
            .flex()
            .flex_col()
            // On macOS the tab bar shows the window's blur through its HUD
            // tint (OVL-002), so only the terminal area is painted opaque.
            .when(!cfg!(target_os = "macos"), |d| d.bg(chrome.terminal_bg))
            .text_color(chrome.text)
            // One line per feature; each function lives next to the code it calls.
            .map(|d| register_tab_actions(d, cx))
            .map(|d| rename::register_rename_actions(d, cx))
            .map(|d| panes::register_pane_actions(d, cx))
            .map(|d| find::register_find_actions(d, cx))
            .map(|d| pickers::register_picker_actions(d, cx))
            .map(|d| font::register_font_actions(d, cx))
            .map(|d| window::register_window_actions(d, cx))
            .map(|d| menus::register_menu_actions(d, cx))
            .map(|d| bookmarks::register_bookmark_actions(d, cx))
            .map(|d| timeline::register_timeline_actions(d, cx))
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                this.rename_color_keys(event, window, cx)
            }))
            .on_action(cx.listener(|_, _: &ToggleMinimalMode, _, cx| {
                crate::settings_window::update(cx, |s| {
                    s.minimal_mode.enabled = !s.minimal_mode.enabled
                });
            }))
            .on_action(cx.listener(|this, _: &ShowTabColorPicker, window, cx| {
                if let Some(id) = this.state.selected() {
                    this.begin_rename_with(id, true, window, cx);
                }
            }))
            .map(|d| debug::register_debug_actions(d, cx))
            .map(|d| keys::register_key_actions(d, cx))
            .when(self.title_bar_visible(cx), |d| {
                d.child(
                    TitleBar::new()
                        .bg(crate::theme::hud_titlebar_background(&bar_chrome))
                        .border_color(bar_chrome.border)
                        .children(tab_bar),
                )
            })
            .child(
                div()
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .bg(chrome.terminal_bg)
                    .when_some(content, |d, panes| {
                        d.child(
                            div()
                                .size_full()
                                .relative()
                                .left(px(switch_offset))
                                .child(panes),
                        )
                    })
                    .children(loading)
                    .children(shortcut_hint)
                    .children(search)
                    .children(rename)
                    .children(bookmarks)
                    .children(explain)
                    .children(tasks)
                    .children(timeline)
                    .children(dashboard)
                    .children(provider_health_border),
            )
            .children(hover_card)
            .children(idle_popover)
            .children(picker)
            .child(drag_listener)
    }
}

/// Seconds since the Unix epoch (saved tab creation dates).
fn unix_now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or_default()
}

/// `closeOtherTabs` alert text: (title, message).
fn close_other_tabs_prompt_text(
    total: usize,
    processes: usize,
    tabs_with: usize,
) -> (String, String) {
    let title = format!("Close {total} tabs?");
    let message = if processes == 0 {
        "Are you sure you want to close all other tabs?".to_string()
    } else if processes == 1 {
        "1 running process will be terminated.".to_string()
    } else if tabs_with == 1 {
        format!("{processes} running processes in 1 tab will be terminated.")
    } else {
        format!("{processes} running processes across {tabs_with} tabs will be terminated.")
    };
    (title, message)
}

/// Title and message of the close confirmation (`confirmTabClose`) for a
/// tab that is not the window's last; `running` is 0 in "always warn" mode.
fn close_tab_prompt_text(running: usize) -> (String, String) {
    match running {
        0 => (
            "Close this tab?".into(),
            "Are you sure you want to close this tab?".into(),
        ),
        1 => (
            "Close tab with running process?".into(),
            "This tab has a running process. Closing it will terminate the process.".into(),
        ),
        n => (
            format!("Close tab with {n} running processes?"),
            format!("This tab has {n} running processes. Closing it will terminate all processes."),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::{close_other_tabs_prompt_text, close_tab_prompt_text};

    #[test]
    fn close_other_tabs_wording() {
        assert_eq!(
            close_other_tabs_prompt_text(3, 0, 0),
            (
                "Close 3 tabs?".to_string(),
                "Are you sure you want to close all other tabs?".to_string()
            )
        );
        assert_eq!(
            close_other_tabs_prompt_text(3, 1, 1).1,
            "1 running process will be terminated."
        );
        assert_eq!(
            close_other_tabs_prompt_text(3, 4, 1).1,
            "4 running processes in 1 tab will be terminated."
        );
        assert_eq!(
            close_other_tabs_prompt_text(3, 4, 2).1,
            "4 running processes across 2 tabs will be terminated."
        );
    }

    #[test]
    fn close_prompt_wording_follows_swift() {
        assert_eq!(close_tab_prompt_text(0).0, "Close this tab?");
        assert_eq!(
            close_tab_prompt_text(1).0,
            "Close tab with running process?"
        );
        assert_eq!(
            close_tab_prompt_text(3).0,
            "Close tab with 3 running processes?"
        );
    }
}

#[cfg(test)]
mod close_confirmation_tests {
    use super::TabCloseFence;
    fn captured() -> TabCloseFence {
        TabCloseFence {
            owner: uuid::Uuid::from_u128(10),
            sessions: vec!["pane-a".into()],
            busy_panes: 1,
            last_tab: false,
        }
    }
    #[test]
    fn confirmed_identity_allows_completed_work_but_rejects_new_busy_panes() {
        let before = captured();
        assert!(before.admits(&before));
        let mut after = before.clone();
        after.busy_panes = 0;
        assert!(before.admits(&after));
        after.busy_panes = 2;
        assert!(!before.admits(&after));
    }
    #[test]
    fn confirmation_cannot_target_replaced_sessions_tabs_or_last_tab_state() {
        let before = captured();
        let mut after = before.clone();
        after.sessions = vec!["replacement".into()];
        assert!(!before.admits(&after));
        after = before.clone();
        after.owner = uuid::Uuid::from_u128(11);
        assert!(!before.admits(&after));
        after = before.clone();
        after.last_tab = true;
        assert!(!before.admits(&after));
    }
}
