//! Split panes inside a tab (mirrors `SplitPanes/SplitPaneController.swift`):
//! a tree of panes split horizontally or vertically, with one focused pane,
//! resizable dividers, and focus cycling. A pane is a terminal, a text
//! editor, a file preview or a diff viewer ([`PaneItem`]; the side panes
//! live in `crate::panes`).

use std::cell::Cell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;

use chau7_next_core::editor::diff::DiffMode;
use chau7_next_core::session_restore::{SavedAxis, SavedSplitNode};
use gpui::{
    AnyElement, App, Axis, Context, DragMoveEvent, Entity, EntityId, EventEmitter, FocusHandle,
    Focusable, Render, Subscription, Window, div, prelude::*, px,
};

use crate::actions::{ScrollToBottom, ScrollToTop};
use crate::panes::{
    DashboardPane, DiffPane, EditorPane, PreviewPane, RepositoryPane, SidePaneEvent,
};
use crate::session_store::{SavedPane, SavedTab};
use crate::settings::Settings;
use crate::terminal::session::{SessionEvent, TerminalSession};
use crate::terminal::view::{TerminalView, TerminalViewEvent};
use crate::theme::Chrome;
use crate::workspace::AppData;

/// Identifies a pane across launches (`SplitPaneController` pane UUIDs).
/// Random, so it can also name a terminal pane's scrollback file.
pub type PaneId = u64;

/// Authoritative cached directory, maintained by OSC7 and the off-UI
/// process-directory fallback. Saved-state capture never probes a process.
pub fn live_cwd(session: &TerminalSession) -> Option<PathBuf> {
    session.cwd.clone()
}

fn preferred_available_id<T: Copy + Eq>(
    available: &[T],
    preferred: Option<T>,
    fallback: Option<T>,
) -> Option<T> {
    preferred
        .filter(|id| available.contains(id))
        .or_else(|| fallback.filter(|id| available.contains(id)))
}

fn session_metadata_updates_tab(
    changed: EntityId,
    focused: Option<EntityId>,
    primary: Option<EntityId>,
    presentation: Option<EntityId>,
) -> bool {
    focused == Some(changed) || primary == Some(changed) || presentation == Some(changed)
}

fn restored_primary_cwd(saved: &SavedTab, deferred_cwd: Option<&PathBuf>) -> Option<PathBuf> {
    let terminal_count = saved
        .layout
        .as_ref()
        .map(|layout| layout.terminal_ids().len())
        .unwrap_or(saved.panes.len());
    // An explicit non-terminal layout has no primary shell. Its tab cwd may
    // belong to a displayed secondary pane, so it cannot seed auto grouping.
    if saved.layout.is_some() && terminal_count == 0 {
        return None;
    }
    let primary_directory = saved
        .primary_terminal()
        .and_then(|pane| pane.directory.as_deref())
        .map(PathBuf::from);
    if primary_directory.is_some() {
        return primary_directory;
    }
    if terminal_count > 1 {
        return None;
    }
    deferred_cwd.cloned().or_else(|| saved.cwd.clone())
}

fn new_pane_id() -> PaneId {
    (uuid::Uuid::new_v4().as_u128() as u64 & 0x0000_ffff_ffff_ffff) | 1
}

/// Pane events for the workspace.
/// Size a terminal starts at before the layout gives it its own.
const DEFAULT_SIZE: (u16, u16) = (80, 24);
const SPLIT_DIVIDER_HITBOX: f32 = 7.0;
const SPLIT_DIVIDER_RULE: f32 = 1.0;

#[derive(Debug, Clone)]
pub enum PaneEvent {
    /// Every pane closed: the tab should close.
    Empty,
    /// Output arrived in some pane.
    Activity,
    /// Focused, primary-terminal, or displayed-terminal metadata changed.
    MetadataChanged,
    Bell,
    /// A command started in some pane (its text).
    CommandStarted(String),
    /// A command finished in some pane.
    CommandFinished(i32),
    /// The user typed or pasted in the focused pane (broadcast mode).
    Input(Vec<u8>),
    /// An event for the AI event feed, from some pane (see `SessionEvent::Ai`).
    Ai {
        event: Box<chau7_next_core::ai::event::AiEvent>,
        notify: bool,
        tab_name_as_tool: bool,
    },
    /// A command of some pane changed these files. The block identity and
    /// finish order preserve command order when Git scans finish late.
    ChangedFiles {
        block_id: uuid::Uuid,
        end_time: f64,
        finish_order: u64,
        files: Vec<String>,
    },
    /// The user answered a prompt in some pane: clear a permission border.
    PermissionResolved,
}

/// What a leaf of the tree shows (`SplitNode` cases).
#[derive(Clone)]
pub enum PaneItem {
    Terminal(Entity<TerminalView>),
    Editor(Entity<EditorPane>),
    Preview(Entity<PreviewPane>),
    Diff(Entity<DiffPane>),
    Repository(Entity<RepositoryPane>),
    Dashboard(Entity<DashboardPane>),
}

impl PaneItem {
    pub fn entity_id(&self) -> EntityId {
        match self {
            PaneItem::Terminal(e) => e.entity_id(),
            PaneItem::Editor(e) => e.entity_id(),
            PaneItem::Preview(e) => e.entity_id(),
            PaneItem::Diff(e) => e.entity_id(),
            PaneItem::Repository(e) => e.entity_id(),
            PaneItem::Dashboard(e) => e.entity_id(),
        }
    }

    pub fn focus_handle(&self, cx: &App) -> FocusHandle {
        match self {
            PaneItem::Terminal(e) => e.read(cx).focus_handle(cx),
            PaneItem::Editor(e) => e.read(cx).focus_handle(cx),
            PaneItem::Preview(e) => e.read(cx).focus_handle(cx),
            PaneItem::Diff(e) => e.read(cx).focus_handle(cx),
            PaneItem::Repository(e) => e.read(cx).focus_handle(cx),
            PaneItem::Dashboard(e) => e.read(cx).focus_handle(cx),
        }
    }

    fn element(&self) -> AnyElement {
        match self {
            PaneItem::Terminal(e) => e.clone().into_any_element(),
            PaneItem::Editor(e) => e.clone().into_any_element(),
            PaneItem::Preview(e) => e.clone().into_any_element(),
            PaneItem::Diff(e) => e.clone().into_any_element(),
            PaneItem::Repository(e) => e.clone().into_any_element(),
            PaneItem::Dashboard(e) => e.clone().into_any_element(),
        }
    }

    fn terminal(&self) -> Option<&Entity<TerminalView>> {
        match self {
            PaneItem::Terminal(view) => Some(view),
            _ => None,
        }
    }
}

/// A leaf the tree functions can identify.
trait LeafKey {
    fn key(&self) -> EntityId;
}

impl LeafKey for PaneItem {
    fn key(&self) -> EntityId {
        self.entity_id()
    }
}

enum Node<L> {
    Leaf(L),
    Split {
        axis: Axis,
        children: Vec<Node<L>>,
        /// Fractions summing to 1.
        ratios: Vec<f32>,
        id: u64,
    },
}

/// Data carried while dragging a divider.
#[derive(Clone)]
struct DividerDrag {
    split_id: u64,
    index: usize,
    grab_offset: Rc<Cell<f32>>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct HiddenPaneEdges {
    top: bool,
    right: bool,
    bottom: bool,
    left: bool,
}

impl HiddenPaneEdges {
    fn child(self, axis: Axis, index: usize, count: usize) -> Self {
        let last = index + 1 == count;
        match axis {
            Axis::Horizontal => Self {
                top: self.top,
                right: (self.right && last) || !last,
                bottom: self.bottom,
                left: (self.left && index == 0) || index > 0,
            },
            Axis::Vertical => Self {
                top: (self.top && index == 0) || index > 0,
                right: self.right,
                bottom: (self.bottom && last) || !last,
                left: self.left,
            },
        }
    }
}

struct DividerGhost;
impl Render for DividerGhost {
    fn render(&mut self, _w: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
    }
}

pub struct PaneTree {
    /// Complete saved payload parked until this tab is actually selected.
    deferred_saved: Option<SavedTab>,
    /// Inert Swift tab context carried through activation and future saves.
    archived_context: Option<chau7_next_core::session_restore::models::ArchivedTabContext>,
    deferred_cwd: Option<PathBuf>,
    restore_selected: Cell<bool>,
    /// Saved resume commands are prepared in background tabs during startup.
    restore_prefill_in_background: bool,
    restore_prepared: Option<crate::restore::preparation::PreparedTab>,
    restore_activation: Option<gpui::Task<()>>,
    identity_hydration: Option<gpui::Task<()>>,
    identity_generation: u64,
    restore_override: chau7_next_core::token_optimization::TabTokenOptOverride,
    restore_release_registered: bool,
    restored_metadata: HashMap<PaneId, SavedPane>,
    root: Option<Node<PaneItem>>,
    focused: Option<EntityId>,
    next_split_id: u64,
    subscriptions: Vec<(EntityId, Vec<Subscription>)>,
    pane_ids: HashMap<EntityId, PaneId>,
    /// Panes restored from a saved session whose scrollback has not been
    /// replayed yet. Until then the saved state is what gets saved again.
    pending_restore: HashMap<PaneId, SavedPane>,
    owner_tab: Option<uuid::Uuid>,
    presentation_terminal: Option<EntityId>,
    note_binding: Option<(PathBuf, uuid::Uuid)>,
    note_task: Option<gpui::Task<()>>,
    note_generation: u64,
}

impl EventEmitter<PaneEvent> for PaneTree {}

impl PaneTree {
    #[cfg(test)]
    pub(crate) fn empty_for_test() -> Self {
        Self::empty()
    }

    /// Panes split side by side, each a headless terminal with the
    /// production event wiring (no shell process). The last one is focused.
    #[cfg(all(test, unix))]
    pub(crate) fn headless_for_test(
        count: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut tree = Self::empty();
        let mut leaves = Vec::new();
        for _ in 0..count.max(1) {
            let terminal = chau7_terminal::Chau7Terminal::new_headless(80, 24).unwrap();
            let session =
                cx.new(|cx| TerminalSession::from_terminal_manually_driven(terminal, None, cx));
            let view = tree.wire_terminal(session, new_pane_id(), window, cx);
            leaves.push(Node::Leaf(PaneItem::Terminal(view)));
        }
        let last = match leaves.last() {
            Some(Node::Leaf(item)) => item.entity_id(),
            _ => unreachable!(),
        };
        tree.root = Some(if leaves.len() == 1 {
            leaves.remove(0)
        } else {
            let ratios = vec![1.0 / leaves.len() as f32; leaves.len()];
            Node::Split {
                axis: Axis::Horizontal,
                children: leaves,
                ratios,
                id: 0,
            }
        });
        tree.focused = Some(last);
        tree.presentation_terminal = Some(last);
        tree
    }

    fn empty() -> Self {
        Self {
            deferred_saved: None,
            archived_context: None,
            deferred_cwd: None,
            restore_selected: Cell::new(false),
            restore_prefill_in_background: false,
            restore_prepared: None,
            restore_activation: None,
            identity_hydration: None,
            identity_generation: 0,
            restore_override: chau7_next_core::token_optimization::TabTokenOptOverride::Default,
            restore_release_registered: false,
            restored_metadata: HashMap::new(),
            root: None,
            focused: None,
            next_split_id: 1,
            subscriptions: Vec::new(),
            pane_ids: HashMap::new(),
            pending_restore: HashMap::new(),
            owner_tab: None,
            presentation_terminal: None,
            note_binding: None,
            note_task: None,
            note_generation: 0,
        }
    }

    pub fn new_with_owner(
        cwd: Option<PathBuf>,
        owner: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut this = Self::empty();
        this.owner_tab = Some(owner);
        let view = this.create_terminal(cwd, new_pane_id(), DEFAULT_SIZE, window, cx);
        this.focused = Some(view.entity_id());
        this.presentation_terminal = this.focused;
        this.root = Some(Node::Leaf(PaneItem::Terminal(view)));
        this
    }

    fn park_saved(saved: SavedTab, cwd: Option<PathBuf>) -> Self {
        let mut this = Self::empty();
        this.retain_archived_context(&saved);
        this.deferred_saved = Some(saved);
        this.deferred_cwd = cwd;
        this
    }

    fn retain_archived_context(&mut self, saved: &SavedTab) {
        self.archived_context = saved.archived_context.clone();
    }

    /// Startup placeholders retain the complete payload without a hidden shell.
    pub fn from_saved_deferred_with_owner(
        saved: Option<&SavedTab>,
        cwd: Option<PathBuf>,
        owner: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        match saved {
            Some(saved) => {
                let mut this = Self::park_saved(saved.clone(), cwd);
                this.owner_tab = Some(owner);
                this
            }
            None => Self::new_with_owner(cwd, owner, window, cx),
        }
    }
    pub fn deferred_saved(&self) -> Option<&SavedTab> {
        self.deferred_saved.as_ref()
    }
    pub(crate) fn archived_context(
        &self,
    ) -> Option<&chau7_next_core::session_restore::models::ArchivedTabContext> {
        self.archived_context.as_ref()
    }
    pub fn is_deferred(&self) -> bool {
        self.deferred_saved.is_some()
    }

    /// BackgroundIdentityOnly validates metadata without creating a PTY/view,
    /// loading scrollback or delivering a resume. Selection performs a fresh
    /// full preparation; a weak late result cannot overwrite that activation.
    pub(crate) fn hydrate_deferred_identity(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<futures::channel::oneshot::Receiver<bool>> {
        if self.restore_selected.get() || self.restore_activation.is_some() {
            return None;
        }
        let mut saved = self.deferred_saved.clone()?;
        let owner = self.owner_tab?;
        saved.uuid = Some(owner);
        self.identity_generation = self.identity_generation.wrapping_add(1);
        let generation = self.identity_generation;
        let root = cx.global::<AppData>().root.clone();
        let hint_generation = crate::restore::preparation::identity_hint_generation(&root);
        let cwd = self.deferred_cwd.clone();
        let task = cx.background_spawn(async move {
            use chau7_next_core::work_profiler::{self, Key, Queue};
            let mut work = work_profiler::begin(Key::work(
                "restore_identity",
                "metadata",
                "parked",
                "deferred_restore",
                Queue::Background,
            ));
            work.items(saved.panes.len());
            crate::restore::preparation::prepare_identity(&root, saved, cwd)
        });
        let (tx, rx) = futures::channel::oneshot::channel();
        self.identity_hydration = Some(cx.spawn(async move |this, cx| {
            let mut prepared = task.await;
            let admitted = this
                .update(cx, |this, cx| {
                    if !this.apply_deferred_identity(
                        owner,
                        generation,
                        hint_generation,
                        &cx.global::<AppData>().root,
                        &mut prepared,
                    ) {
                        return false;
                    }
                    this.identity_hydration = None;
                    cx.emit(PaneEvent::MetadataChanged);
                    cx.notify();
                    true
                })
                .unwrap_or(false);
            let _ = tx.send(admitted);
        }));
        Some(rx)
    }

    fn apply_deferred_identity(
        &mut self,
        owner: uuid::Uuid,
        generation: u64,
        hint_generation: u64,
        root: &chau7_next_core::data_root::DataRoot,
        prepared: &mut crate::restore::preparation::PreparedTab,
    ) -> bool {
        if self.deferred_saved.is_none()
            || self.restore_selected.get()
            || self.restore_activation.is_some()
            || self.owner_tab != Some(owner)
            || self.identity_generation != generation
        {
            return false;
        }
        if !crate::restore::preparation::admit_identity_metadata(
            root,
            owner,
            hint_generation,
            prepared,
        ) {
            return false;
        }
        self.deferred_cwd = prepared
            .saved
            .cwd
            .clone()
            .or_else(|| self.deferred_cwd.clone());
        self.restored_metadata = prepared
            .saved
            .panes
            .iter()
            .map(|p| (p.id, p.clone()))
            .collect();
        self.retain_archived_context(&prepared.saved);
        self.deferred_saved = Some(prepared.saved.clone());
        true
    }

    pub(crate) fn set_restore_surface(&self, selected: bool, visible: bool, cx: &App) {
        self.restore_selected.set(selected);
        for (_, session) in self.pane_sessions(cx) {
            session.read(cx).set_restore_selected(selected);
            session.read(cx).mark_restore_surface(visible);
        }
    }
    pub(crate) fn set_restore_override(
        &mut self,
        value: chau7_next_core::token_optimization::TabTokenOptOverride,
    ) {
        self.restore_override = value;
    }
    /// Restore saved prompt input for every command-bearing tab without
    /// selecting it. The shell still validates its own prompt before receiving
    /// bytes, and the command is written without a line terminator.
    pub(crate) fn begin_background_resume_restore(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let has_saved_resume_command = self.deferred_saved.as_ref().is_some_and(|saved| {
            saved.panes.iter().any(|pane| {
                pane.ai_resume_command
                    .as_deref()
                    .is_some_and(|command| !command.trim().is_empty())
            })
        });
        if !has_saved_resume_command {
            return;
        }
        self.restore_prefill_in_background = true;
        self.activate_deferred(window, cx);
    }

    fn activate_deferred(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(saved) = self.deferred_saved.clone() else {
            return;
        };
        self.identity_generation = self.identity_generation.wrapping_add(1);
        self.identity_hydration = None;
        if let Some(mut prepared) = self.restore_prepared.take() {
            let selected = self.restore_selected.get();
            if (!selected || !window.is_visible()) && !self.restore_prefill_in_background {
                self.restore_prepared = Some(prepared);
                return;
            }
            let prefill_in_background = self.restore_prefill_in_background;
            let owner = self.owner_tab;
            if let Some(owner) = owner {
                crate::restore::preparation::claim(
                    &cx.global::<AppData>().root,
                    owner,
                    &mut prepared,
                );
            }

            let token_override = self.restore_override;
            let cwd = self.deferred_cwd.clone().or_else(|| saved.cwd.clone());
            let mut active =
                Self::from_saved_prepared(Some(&prepared.saved), cwd, owner, window, cx);
            active.restore_selected.set(selected);
            active.restore_prefill_in_background = prefill_in_background;
            active.restore_release_registered = self.restore_release_registered;
            active.restored_metadata = prepared
                .saved
                .panes
                .iter()
                .map(|pane| (pane.id, pane.clone()))
                .collect();
            active.retain_archived_context(&prepared.saved);
            active.restore_override = token_override;
            if let Some(owner) = owner {
                active.set_owner_tab(owner, window, cx);
            }
            for (pane, session) in active.pane_sessions(cx) {
                session.update(cx, |session, cx| {
                    session.set_token_opt_override(token_override, false);
                    session.set_restore_selected(selected);
                    session.mark_restore_surface(window.is_visible());
                    if let Some(prepared) = prepared.panes.get(&pane) {
                        if let Some(context) = &prepared.context {
                            session.replay_restored_context(context, cx);
                        }
                        if let Some(identity) = &prepared.identity {
                            session.restore_ai_metadata(
                                Some(&identity.provider),
                                Some(&identity.session_id),
                                cx,
                            );
                            if let Some(command) = &prepared.command {
                                session.queue_restored_resume(
                                    command.clone(),
                                    prepared.directory.clone(),
                                    identity.clone(),
                                    cx,
                                );
                            }
                        } else if let Some(provider) = active
                            .restored_metadata
                            .get(&pane)
                            .and_then(|pane| pane.ai_provider.as_deref())
                        {
                            session.restore_ai_metadata(Some(provider), None, cx);
                        }
                    }
                });
            }
            for pane in prepared.panes.keys() {
                active.pending_restore.remove(pane);
            }
            *self = active;
            if selected && window.is_visible() {
                self.focus_own(window, cx);
            }
            cx.emit(PaneEvent::MetadataChanged);
            cx.notify();
            return;
        }
        if self.restore_activation.is_some() {
            return;
        }
        let root = cx.global::<AppData>().root.clone();
        let cwd = self.deferred_cwd.clone();
        let contexts = crate::restore::writer::contexts_for(
            &saved.panes.iter().map(|pane| pane.id).collect::<Vec<_>>(),
            cx,
        );
        let task = cx.background_spawn(async move {
            crate::restore::preparation::prepare_with_contexts(&root, saved, cwd, contexts)
        });
        self.restore_activation = Some(cx.spawn_in(window, async move |this, cx| {
            let prepared = task.await;
            // Keep prepared data even if the original window disappeared during
            // a move. The receiving window activates it when actually selected.
            let _ = this.update(cx, |this, cx| {
                this.restore_prepared = Some(prepared);
                this.restore_activation = None;
                cx.notify();
            });
            let _ = this.update_in(cx, |this, window, cx| this.activate_deferred(window, cx));
        }));
    }

    /// The panes of a tab: restored from its saved split layout when it has
    /// one (`buildRestorableController`), else one shell in `cwd`.
    pub fn from_saved_with_owner(
        saved: Option<&SavedTab>,
        cwd: Option<PathBuf>,
        owner: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        match saved {
            Some(saved) => {
                let mut this = Self::park_saved(saved.clone(), cwd);
                this.owner_tab = Some(owner);
                this
            }
            None => Self::new_with_owner(cwd, owner, window, cx),
        }
    }

    fn from_saved_prepared(
        saved: Option<&SavedTab>,
        cwd: Option<PathBuf>,
        owner: Option<uuid::Uuid>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let layout = saved
            .and_then(|s| {
                s.layout.clone().or_else(|| {
                    s.panes.first().map(|p| SavedSplitNode::Terminal {
                        id: p.id,
                        directory: p.directory.clone(),
                    })
                })
            })
            .and_then(SavedSplitNode::normalized);
        let (Some(saved), Some(layout)) = (saved, layout) else {
            let mut this =
                Self::new_with_owner(cwd, owner.unwrap_or_else(uuid::Uuid::new_v4), window, cx);
            if let Some(saved) = saved {
                this.retain_archived_context(saved);
            }
            return this;
        };
        let mut this = Self::empty();
        this.owner_tab = owner;
        this.deferred_cwd = cwd;
        this.retain_archived_context(saved);
        let states: HashMap<PaneId, &SavedPane> = saved.panes.iter().map(|p| (p.id, p)).collect();
        let root = this.build_node(&layout, &states, window, cx);
        this.root = Some(root);
        let wanted = saved.focused_pane.and_then(|id| {
            this.pane_ids
                .iter()
                .find(|(_, pane)| **pane == id)
                .map(|(view, _)| *view)
        });
        // The saved focus, else the first terminal, else the first pane.
        this.focused = wanted
            .or_else(|| this.views().first().map(|v| v.entity_id()))
            .or_else(|| this.leaves().first().map(PaneItem::entity_id));
        for pane in this.pane_ids.values() {
            if let Some(state) = states.get(pane) {
                this.pending_restore.insert(*pane, (*state).clone());
            }
        }
        this.deferred_cwd = None;
        this
    }

    fn build_node(
        &mut self,
        saved: &SavedSplitNode,
        states: &HashMap<PaneId, &SavedPane>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Node<PaneItem> {
        let non_empty = |s: &Option<String>| s.clone().filter(|p| !p.trim().is_empty());
        match saved {
            SavedSplitNode::Terminal { id, directory } => {
                let dir = states
                    .get(id)
                    .and_then(|p| p.directory.clone())
                    .or_else(|| directory.clone())
                    .filter(|d| !d.is_empty())
                    .map(PathBuf::from)
                    .or_else(|| self.deferred_cwd.clone());
                let view = self.create_terminal(dir, *id, DEFAULT_SIZE, window, cx);
                if let Some(state) = states.get(id) {
                    let session = view.read(cx).session.clone();
                    session.update(cx, |session, _| {
                        session.input_history = state.input_history.clone();
                    });
                }
                Node::Leaf(PaneItem::Terminal(view))
            }
            SavedSplitNode::Editor { id, path } => {
                let editor = self.create_editor(*id, window, cx);
                if let Some(path) = non_empty(path) {
                    editor.update(cx, |e, cx| e.load_file(path.into(), None, window, cx));
                }
                Node::Leaf(PaneItem::Editor(editor))
            }
            SavedSplitNode::Preview { id, path } => {
                let preview = self.create_preview(*id, window, cx);
                if let Some(path) = non_empty(path) {
                    preview.update(cx, |p, cx| p.load_file(path.into(), None, window, cx));
                }
                Node::Leaf(PaneItem::Preview(preview))
            }
            SavedSplitNode::Diff {
                id,
                file,
                directory,
                mode,
            } => {
                let diff = self.create_diff(*id, window, cx);
                if let (Some(file), Some(directory)) = (non_empty(file), directory.clone()) {
                    let mode = mode
                        .as_deref()
                        .and_then(DiffMode::from_raw)
                        .unwrap_or_default();
                    diff.update(cx, |d, cx| d.load_diff(file, directory, mode, window, cx));
                }
                Node::Leaf(PaneItem::Diff(diff))
            }
            SavedSplitNode::Dashboard { id, directory } => Node::Leaf(PaneItem::Dashboard(
                self.create_dashboard(*id, directory.clone().unwrap_or_default(), window, cx),
            )),
            SavedSplitNode::Repository { id, directory } => {
                let repository = self.create_repository(*id, window, cx);
                if let Some(directory) = non_empty(directory) {
                    repository.update(cx, |r, cx| r.load(directory.into(), window, cx));
                }
                Node::Leaf(PaneItem::Repository(repository))
            }
            SavedSplitNode::Split {
                axis,
                ratios,
                children,
                ..
            } => {
                let mut nodes = Vec::new();
                for child in children {
                    nodes.push(self.build_node(child, states, window, cx));
                }
                let id = self.next_split_id;
                self.next_split_id += 1;
                Node::Split {
                    axis: match axis {
                        SavedAxis::Horizontal => Axis::Horizontal,
                        SavedAxis::Vertical => Axis::Vertical,
                    },
                    children: nodes,
                    ratios: ratios.clone(),
                    id,
                }
            }
        }
    }

    fn create_terminal(
        &mut self,
        cwd: Option<PathBuf>,
        pane_id: PaneId,
        (cols, rows): (u16, u16),
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<TerminalView> {
        let settings = Settings::get(cx).clone();
        let root = cx.global::<AppData>().root.clone();
        let session = cx.new(|cx| {
            match TerminalSession::spawn_with_owner(
                cols,
                rows,
                cwd.clone(),
                &settings,
                &root,
                self.owner_tab.unwrap_or_else(uuid::Uuid::new_v4),
                cx,
            ) {
                Ok(session) => session,
                Err(err) => {
                    log::error!("{err}");
                    let headless = chau7_terminal::Chau7Terminal::new_headless(80, 24)
                        .expect("headless terminal");
                    headless.inject_output(
                        format!(
                            "{} could not start a shell: {err}\r\n",
                            chau7_next_core::data_root::APP_NAME
                        )
                        .as_bytes(),
                    );
                    let mut session = TerminalSession::from_terminal(headless, cwd, cx);
                    // This error surface is final, unlike a restore placeholder.
                    session.exited = Some(None);
                    session
                }
            }
        });
        self.wire_terminal(session, pane_id, window, cx)
    }

    /// A view for `session`, with the subscriptions that turn its events into
    /// pane events.
    fn wire_terminal(
        &mut self,
        session: Entity<TerminalSession>,
        pane_id: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<TerminalView> {
        let view = cx.new(|cx| TerminalView::new(session.clone(), window, cx));
        let view_id = view.entity_id();
        self.pane_ids.insert(view_id, pane_id);
        let subs = vec![
            cx.subscribe_in(
                &session,
                window,
                move |this, _, event, window, cx| match event {
                    SessionEvent::Output => cx.emit(PaneEvent::Activity),
                    SessionEvent::MetadataChanged => {
                        this.attach_session_notes(window, cx);
                        let primary = this.views().first().map(|view| view.entity_id());
                        if session_metadata_updates_tab(
                            view_id,
                            this.focused,
                            primary,
                            this.presentation_terminal,
                        ) {
                            cx.emit(PaneEvent::MetadataChanged);
                        }
                        // Shell loading overlay.
                        cx.notify();
                    }
                    SessionEvent::Bell => {
                        cx.emit(PaneEvent::Bell);
                        cx.notify();
                    }
                    SessionEvent::Exited(_) => {
                        if Settings::get(cx).tabs.close_on_exit {
                            // Like closing the pane by hand: when it had the
                            // keyboard, the pane that takes its place gets it.
                            let had_focus = this
                                .leaves()
                                .iter()
                                .find(|leaf| leaf.entity_id() == view_id)
                                .is_some_and(|leaf| {
                                    leaf.focus_handle(cx).contains_focused(window, cx)
                                });
                            this.remove(view_id, cx);
                            if had_focus {
                                this.focus_own(window, cx);
                            }
                        } else {
                            cx.notify();
                        }
                    }
                    SessionEvent::CommandFinished(code) => {
                        cx.emit(PaneEvent::CommandFinished(*code))
                    }
                    SessionEvent::CommandStarted(command) => {
                        cx.emit(PaneEvent::CommandStarted(command.clone()))
                    }
                    SessionEvent::Ai {
                        event,
                        notify,
                        tab_name_as_tool,
                    } => cx.emit(PaneEvent::Ai {
                        event: event.clone(),
                        notify: *notify,
                        tab_name_as_tool: *tab_name_as_tool,
                    }),
                    SessionEvent::ChangedFiles {
                        block_id,
                        end_time,
                        finish_order,
                        files,
                    } => cx.emit(PaneEvent::ChangedFiles {
                        block_id: *block_id,
                        end_time: *end_time,
                        finish_order: *finish_order,
                        files: files.clone(),
                    }),
                    SessionEvent::PermissionResolved => cx.emit(PaneEvent::PermissionResolved),
                    SessionEvent::ClipboardStore(_)
                    | SessionEvent::ClipboardLoad
                    | SessionEvent::DirectoryChanged(_)
                    | SessionEvent::WaitingInput { .. } => {}
                },
            ),
            cx.subscribe_in(
                &view,
                window,
                move |this, _, event, window, cx| match event {
                    TerminalViewEvent::Focused => this.set_focused(view_id, cx),
                    TerminalViewEvent::Input(bytes) => cx.emit(PaneEvent::Input(bytes.clone())),
                    TerminalViewEvent::OpenInEditor { path, line } => {
                        this.open_file_in_editor(path.clone(), *line, window, cx)
                    }
                },
            ),
        ];
        self.subscriptions.push((view_id, subs));
        view
    }

    fn set_focused(&mut self, id: EntityId, cx: &mut Context<Self>) {
        if self.views().iter().any(|v| v.entity_id() == id) {
            self.presentation_terminal = Some(id);
        }
        if self.focused != Some(id) {
            self.focused = Some(id);
            cx.emit(PaneEvent::MetadataChanged);
            cx.notify();
        }
    }

    /// What every side pane asks of the tree.
    fn on_side_event(
        &mut self,
        id: EntityId,
        event: &SidePaneEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event {
            SidePaneEvent::Focused => {
                // A click on a header or the runbook also takes the keyboard.
                if self.focused != Some(id) {
                    self.set_focused(id, cx);
                    // GPUI has already focused a clicked child input before
                    // this bubbled pane event arrives. Keep that deeper
                    // target when it belongs to the pane we just selected.
                    let focus_is_within_selected_pane = self
                        .focused_item()
                        .is_some_and(|item| item.focus_handle(cx).contains_focused(window, cx));
                    if !focus_is_within_selected_pane {
                        self.focus_own(window, cx);
                    }
                }
            }
            // `closePane(id:)`: the last pane of a tab stays.
            SidePaneEvent::Close => {
                if self.pane_count() > 1 {
                    self.remove(id, cx);
                    self.focus_own(window, cx);
                }
            }
            SidePaneEvent::RunCommand(text) => self.send_command_to_terminal(text, cx),
            SidePaneEvent::OpenDiff {
                file,
                directory,
                staged,
            } => self.open_diff_viewer(
                file.clone(),
                directory.to_string_lossy().into_owned(),
                if *staged {
                    DiffMode::Staged
                } else {
                    DiffMode::WorkingTree
                },
                window,
                cx,
            ),
            SidePaneEvent::PreviewFile(path) => {
                self.open_file_preview(Some(path.clone()), None, window, cx)
            }
            SidePaneEvent::OpenDashboard(root) => self.open_dashboard(root.clone(), window, cx),
            SidePaneEvent::OpenEditor(path) => {
                self.open_file_in_editor(path.clone(), None, window, cx);
            }
            SidePaneEvent::Changed => cx.notify(),
        }
    }

    fn create_editor(
        &mut self,
        pane_id: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<EditorPane> {
        let editor = cx.new(|cx| EditorPane::new(window, cx));
        let tree = cx.entity().downgrade();
        editor.update(cx, |editor, _| {
            editor.set_terminal_provider(move |cx| {
                let tree = tree.upgrade()?;
                let terminal = tree.read(cx).views().into_iter().next()?;
                Some(terminal.read(cx).session.clone())
            })
        });
        let id = editor.entity_id();
        self.pane_ids.insert(id, pane_id);
        let sub = cx.subscribe_in(&editor, window, move |this, _, event, window, cx| {
            this.on_side_event(id, event, window, cx)
        });
        self.subscriptions.push((id, vec![sub]));
        editor
    }

    fn create_preview(
        &mut self,
        pane_id: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<PreviewPane> {
        let preview = cx.new(|cx| PreviewPane::new(window, cx));
        let id = preview.entity_id();
        self.pane_ids.insert(id, pane_id);
        let sub = cx.subscribe_in(&preview, window, move |this, _, event, window, cx| {
            this.on_side_event(id, event, window, cx)
        });
        self.subscriptions.push((id, vec![sub]));
        preview
    }

    fn create_diff(
        &mut self,
        pane_id: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<DiffPane> {
        let diff = cx.new(|cx| DiffPane::new(window, cx));
        let id = diff.entity_id();
        self.pane_ids.insert(id, pane_id);
        let sub = cx.subscribe_in(&diff, window, move |this, _, event, window, cx| {
            this.on_side_event(id, event, window, cx)
        });
        self.subscriptions.push((id, vec![sub]));
        diff
    }

    fn create_dashboard(
        &mut self,
        pane_id: PaneId,
        root: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<DashboardPane> {
        let dashboard = cx.new(|cx| DashboardPane::new(root, true, window, cx));
        let id = dashboard.entity_id();
        self.pane_ids.insert(id, pane_id);
        let subs = vec![
            cx.subscribe_in(&dashboard, window, move |this, _, event, window, cx| {
                this.on_side_event(id, event, window, cx)
            }),
            self.side_pane_focus_subscription(id, dashboard.read(cx).focus_handle(cx), window, cx),
        ];
        self.subscriptions.push((id, subs));
        dashboard
    }

    fn side_pane_focus_subscription(
        &mut self,
        id: EntityId,
        handle: FocusHandle,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Subscription {
        cx.on_focus_in(&handle, window, move |this, window, cx| {
            this.on_side_event(id, &SidePaneEvent::Focused, window, cx)
        })
    }

    /// Reuse the actual repository dashboard when already present in this split tree.
    pub fn open_dashboard(&mut self, root: String, window: &mut Window, cx: &mut Context<Self>) {
        let existing = self.leaves().into_iter().find_map(|item| {
            if let PaneItem::Dashboard(view) = item {
                (view.read(cx).repository_root() == root).then_some(view)
            } else {
                None
            }
        });
        let dashboard = existing.unwrap_or_else(|| {
            let view = self.create_dashboard(new_pane_id(), root, window, cx);
            self.insert_leaf(
                PaneItem::Dashboard(view.clone()),
                Axis::Horizontal,
                window,
                cx,
            );
            view
        });
        self.set_focused(dashboard.entity_id(), cx);
        self.focus_own(window, cx);
    }
    fn create_repository(
        &mut self,
        pane_id: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<RepositoryPane> {
        let repository = cx.new(|cx| RepositoryPane::new(window, cx));
        let tree = cx.entity().downgrade();
        repository.update(cx, |r, _| {
            r.set_session_provider(move |cx| {
                let Some(tree) = tree.upgrade() else {
                    return (None, Vec::new(), None);
                };
                let tree = tree.read(cx);
                let session = tree.owner_tab.and_then(|tab| {
                    crate::runtime::manager()
                        .all_sessions(true)
                        .into_iter()
                        .filter(|s| s.tab_id.eq_ignore_ascii_case(&tab.to_string()))
                        .max_by(|a, b| (a.created_at, &a.id).cmp(&(b.created_at, &b.id)))
                });
                let blocks = tree
                    .pane_sessions(cx)
                    .iter()
                    .flat_map(|(_, s)| s.read(cx).blocks().blocks().to_vec())
                    .collect();
                (session, blocks, tree.note_repository(cx))
            })
        });
        let id = repository.entity_id();
        self.pane_ids.insert(id, pane_id);
        let subs = vec![
            cx.subscribe_in(&repository, window, move |this, _, event, window, cx| {
                this.on_side_event(id, event, window, cx)
            }),
            self.side_pane_focus_subscription(id, repository.read(cx).focus_handle(cx), window, cx),
        ];
        self.subscriptions.push((id, subs));
        repository
    }
    pub fn open_repository(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let directory = self.note_repository(cx);
        let existing = self.leaves().into_iter().find_map(|item| {
            if let PaneItem::Repository(r) = item {
                Some(r)
            } else {
                None
            }
        });
        let repository = existing.unwrap_or_else(|| {
            let r = self.create_repository(new_pane_id(), window, cx);
            self.insert_leaf(
                PaneItem::Repository(r.clone()),
                Axis::Horizontal,
                window,
                cx,
            );
            r
        });
        if let Some(directory) = directory {
            repository.update(cx, |r, cx| r.load(directory, window, cx));
        }
        self.set_focused(repository.entity_id(), cx);
        self.focus_own(window, cx);
    }

    /// Every pane, in visual order.
    pub fn leaves(&self) -> Vec<PaneItem> {
        let mut out = Vec::new();
        if let Some(root) = &self.root {
            collect_leaves(root, &mut out);
        }
        out
    }

    /// All terminal views, in visual order.
    pub fn views(&self) -> Vec<Entity<TerminalView>> {
        self.leaves()
            .iter()
            .filter_map(|l| l.terminal().cloned())
            .collect()
    }

    /// Whether the tab has a terminal (a tab of editors only is "Editor").
    pub fn has_terminal(&self) -> bool {
        if let Some(saved) = &self.deferred_saved {
            return saved
                .layout
                .as_ref()
                .is_none_or(|layout| !layout.terminal_ids().is_empty());
        }
        !self.views().is_empty()
    }

    /// The focused pane, whatever its kind.
    pub fn focused_item(&self) -> Option<PaneItem> {
        let leaves = self.leaves();
        self.focused
            .and_then(|id| leaves.iter().find(|l| l.entity_id() == id).cloned())
            .or_else(|| leaves.first().cloned())
    }

    /// The focused terminal, or the first terminal when another kind of pane
    /// has focus (`focusedTerminalSessionID`).
    pub fn focused_view(&self) -> Option<Entity<TerminalView>> {
        let views = self.views();
        self.focused
            .and_then(|id| views.iter().find(|v| v.entity_id() == id).cloned())
            .or_else(|| views.first().cloned())
    }

    pub fn focused_session(&self, cx: &App) -> Option<Entity<TerminalSession>> {
        self.focused_view().map(|v| v.read(cx).session.clone())
    }

    /// First terminal in visual split order; automatic grouping follows it.
    pub fn primary_session(&self, cx: &App) -> Option<Entity<TerminalSession>> {
        self.views()
            .first()
            .map(|view| view.read(cx).session.clone())
    }

    /// Terminal currently represented by the tab; manual grouping follows it.
    pub fn presentation_session(&self, cx: &App) -> Option<Entity<TerminalSession>> {
        let views = self.views();
        let available = views
            .iter()
            .map(|view| view.entity_id())
            .collect::<Vec<_>>();
        let fallback = self.focused_view().map(|view| view.entity_id());
        let id = preferred_available_id(&available, self.presentation_terminal, fallback)?;
        views
            .iter()
            .find(|view| view.entity_id() == id)
            .map(|view| view.read(cx).session.clone())
    }

    /// Primary terminal directory; parked restores read the saved first
    /// terminal without constructing a PTY.
    pub fn primary_cwd(&self, cx: &App) -> Option<PathBuf> {
        if let Some(saved) = &self.deferred_saved {
            return restored_primary_cwd(saved, self.deferred_cwd.as_ref());
        }
        self.primary_session(cx)
            .and_then(|session| session.read(cx).cwd.clone())
    }

    /// Panes of every kind (`allPaneIDs.count`).
    pub fn pane_count(&self) -> usize {
        fn count(layout: &SavedSplitNode) -> usize {
            match layout {
                SavedSplitNode::Split { children, .. } => children.iter().map(count).sum(),
                _ => 1,
            }
        }
        self.deferred_saved.as_ref().map_or_else(
            || self.leaves().len(),
            |saved| {
                saved
                    .layout
                    .as_ref()
                    .map(count)
                    .unwrap_or(saved.panes.len().max(1))
            },
        )
    }

    /// Focus the focused pane of `panes`.
    pub fn focus_entity(panes: &Entity<PaneTree>, window: &mut Window, cx: &mut App) {
        panes.update(cx, |tree, cx| {
            tree.restore_selected.set(true);
            tree.activate_deferred(window, cx);
        });
        let handle = panes
            .read(cx)
            .focused_item()
            .map(|item| item.focus_handle(cx));
        if let Some(handle) = handle {
            window.focus(&handle, cx);
        }
    }

    fn focus_own(&self, window: &mut Window, cx: &mut App) {
        if let Some(item) = self.focused_item() {
            let handle = item.focus_handle(cx);
            window.focus(&handle, cx);
        }
    }

    /// Put `item` next to the focused pane (half of its space) and focus it
    /// (`splitNode`).
    fn insert_leaf(
        &mut self,
        item: PaneItem,
        axis: Axis,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let new_id = item.entity_id();
        let split_id = self.next_split_id;
        self.next_split_id += 1;
        let target = self.focused_item().map(|f| f.entity_id());
        self.root = match (self.root.take(), target) {
            (Some(root), Some(target)) => Some(insert_split(root, target, axis, item, split_id)),
            (Some(root), None) => Some(root),
            (None, _) => Some(Node::Leaf(item)),
        };
        if self.views().iter().any(|v| v.entity_id() == new_id) {
            self.presentation_terminal = Some(new_id);
        }
        self.focused = Some(new_id);
        self.focus_own(window, cx);
        // A new side pane's editor exists only once drawn: focus it again then.
        cx.on_next_frame(window, |this, window, cx| this.focus_own(window, cx));
        cx.emit(PaneEvent::MetadataChanged);
        cx.notify();
    }

    /// Directory for a new terminal: the focused (or first) terminal's.
    fn terminal_cwd(&self, cx: &App) -> Option<PathBuf> {
        self.focused_view()
            .and_then(|v| v.read(cx).session.read(cx).cwd.clone())
    }

    pub fn split(&mut self, axis: Axis, window: &mut Window, cx: &mut Context<Self>) {
        // "Enable Split Panes" off blocks new terminal splits (`splitWithTerminal`).
        if !Settings::get(cx).terminal.split_panes_enabled {
            return;
        }
        let cwd = self.terminal_cwd(cx);
        // Start at about the size the split will give (the layout resizes it
        // right after), so the tip box above the first prompt fits the pane.
        let size = self
            .focused_session(cx)
            .map(|s| {
                let grid = &s.read(cx).grid;
                match axis {
                    Axis::Horizontal => ((grid.cols / 2).max(2), grid.rows),
                    Axis::Vertical => (grid.cols, (grid.rows / 2).max(1)),
                }
            })
            .unwrap_or(DEFAULT_SIZE);
        let view = self.create_terminal(cwd, new_pane_id(), size, window, cx);
        self.insert_leaf(PaneItem::Terminal(view), axis, window, cx);
    }

    // ----- side panes ---------------------------------------------------

    /// Workspace passes its persistent tab UUID after new/restore/reopen construction.
    #[allow(dead_code)] // Coordinator wires the shared workspace constructor seam.
    pub fn set_owner_tab(&mut self, tab: uuid::Uuid, window: &mut Window, cx: &mut Context<Self>) {
        if !self.restore_release_registered {
            self.restore_release_registered = true;
            let root = cx.global::<AppData>().root.clone();
            cx.on_release(move |this, _| {
                if let Some(owner) = this.owner_tab {
                    crate::restore::preparation::release_owner(&root, owner);
                }
            })
            .detach();
        }
        if self.owner_tab != Some(tab) {
            self.owner_tab = Some(tab);
            self.note_binding = None;
        }
        if let Some(saved) = &self.deferred_saved {
            crate::restore::preparation::register_owner_identity_hints(
                &cx.global::<AppData>().root,
                tab,
                saved,
            );
        }
        self.attach_session_notes(window, cx);
    }
    fn note_repository(&self, cx: &App) -> Option<PathBuf> {
        let views = self.views();
        let root_for = |id: Option<EntityId>| {
            id.and_then(|id| views.iter().find(|v| v.entity_id() == id))
                .and_then(|v| v.read(cx).session.read(cx).git_root.clone())
        };
        let candidates = [
            root_for(self.focused),
            root_for(self.presentation_terminal),
            views
                .first()
                .and_then(|v| v.read(cx).session.read(cx).git_root.clone()),
        ];
        chau7_next_core::editor::session_note::selected_repository(&candidates)
    }
    fn attach_session_notes(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(tab), Some(repo)) = (self.owner_tab, self.note_repository(cx)) else {
            return;
        };
        let editors: Vec<_> = self
            .leaves()
            .into_iter()
            .filter_map(|p| {
                if let PaneItem::Editor(e) = p {
                    Some(e)
                } else {
                    None
                }
            })
            .collect();
        let untitled = editors
            .iter()
            .any(|e| e.read(cx).path().is_none() && !e.read(cx).is_loading());
        let binding = (repo.clone(), tab);
        if self.note_binding.as_ref() == Some(&binding) && (self.note_task.is_some() || !untitled) {
            return;
        }
        self.note_binding = Some(binding.clone());
        self.note_generation += 1;
        let generation = self.note_generation;
        let root = cx.global::<AppData>().root.clone();
        let task = cx.background_spawn(async move {
            if crate::protected_paths::should_skip(&repo) {
                return None;
            }
            if untitled {
                chau7_next_core::editor::session_note::prepare(&root, &repo, tab)
            } else {
                chau7_next_core::editor::session_note::existing(&root, &repo, tab)
            }
        });
        self.note_task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.note_generation != generation {
                    return;
                }
                this.note_task = None;
                let Some(path) = result else {
                    return;
                };
                let current: Vec<_> = this
                    .leaves()
                    .into_iter()
                    .filter_map(|p| {
                        if let PaneItem::Editor(e) = p {
                            Some(e)
                        } else {
                            None
                        }
                    })
                    .collect();
                if current.is_empty() {
                    let focus = this.focused;
                    this.open_text_editor(Some(path), None, window, cx);
                    this.focused = focus;
                    this.focus_own(window, cx);
                } else {
                    for editor in current {
                        if editor.read(cx).path().is_none() {
                            editor.update(cx, |e, cx| {
                                e.attach_session_note(path.clone(), window, cx)
                            });
                        }
                    }
                }
            });
        }));
    }

    /// `splitWithTextEditor(.horizontal)`: works with split panes off too.
    pub fn open_text_editor(
        &mut self,
        path: Option<PathBuf>,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<EditorPane> {
        let editor = self.create_editor(new_pane_id(), window, cx);
        if let Some(path) = path {
            editor.update(cx, |e, cx| e.load_file(path, line, window, cx));
        }
        self.insert_leaf(
            PaneItem::Editor(editor.clone()),
            Axis::Horizontal,
            window,
            cx,
        );
        self.attach_session_notes(window, cx);
        editor
    }

    fn first_editor(&self) -> Option<Entity<EditorPane>> {
        self.leaves().into_iter().find_map(|l| match l {
            PaneItem::Editor(e) => Some(e),
            _ => None,
        })
    }

    /// `openFileInEditor`: the first editor of the tab loads the file, else a
    /// new editor opens beside the focused pane.
    pub fn open_file_in_editor(
        &mut self,
        path: PathBuf,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match self.first_editor() {
            Some(editor) => editor.update(cx, |e, cx| e.load_file(path, line, window, cx)),
            None => {
                self.open_text_editor(Some(path), line, window, cx);
            }
        }
        cx.notify();
    }

    /// Open File Preview: with a file, the first preview pane shows it (or a
    /// new one opens); without, an empty preview opens (`openFilePreview`).
    pub fn open_file_preview(
        &mut self,
        path: Option<PathBuf>,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let existing = self.leaves().into_iter().find_map(|l| match l {
            PaneItem::Preview(p) => Some(p),
            _ => None,
        });
        match (path, existing) {
            (Some(path), Some(preview)) => {
                preview.update(cx, |p, cx| p.load_file(path, line, window, cx))
            }
            (path, _) => {
                let preview = self.create_preview(new_pane_id(), window, cx);
                if let Some(path) = path {
                    preview.update(cx, |p, cx| p.load_file(path, line, window, cx));
                }
                self.insert_leaf(PaneItem::Preview(preview), Axis::Horizontal, window, cx);
            }
        }
        cx.notify();
    }

    /// `openDiffViewer`: the first diff pane shows the file, else a new one
    /// opens beside the focused pane.
    pub fn open_diff_viewer(
        &mut self,
        file: String,
        directory: String,
        mode: DiffMode,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let existing = self.leaves().into_iter().find_map(|l| match l {
            PaneItem::Diff(d) => Some(d),
            _ => None,
        });
        match existing {
            Some(diff) => diff.update(cx, |d, cx| d.load_diff(file, directory, mode, window, cx)),
            None => {
                let diff = self.create_diff(new_pane_id(), window, cx);
                diff.update(cx, |d, cx| d.load_diff(file, directory, mode, window, cx));
                self.insert_leaf(PaneItem::Diff(diff), Axis::Horizontal, window, cx);
            }
        }
        cx.notify();
    }

    /// Selection append opens an editor on demand; pending note attachment merges typed text.
    pub fn append_to_editor(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let editor = self
            .first_editor()
            .unwrap_or_else(|| self.open_text_editor(None, None, window, cx));
        editor.update(cx, |e, cx| e.append_text(text, window, cx));
    }

    /// Selected text of the focused (or first) terminal.
    pub fn terminal_selection(&self, cx: &App) -> Option<String> {
        self.focused_session(cx)
            .and_then(|s| s.read(cx).selection_text())
            .filter(|t| !t.is_empty())
    }

    /// Runbook Run: type the text into the tab's first terminal
    /// (`sendCommandToTerminal`).
    fn send_command_to_terminal(&mut self, text: &str, cx: &mut Context<Self>) {
        if let Some(view) = self.views().first() {
            let bytes = text.as_bytes().to_vec();
            view.update(cx, |v, cx| v.write_without_broadcast(&bytes, cx));
        }
    }

    // ----- closing and focus --------------------------------------------

    /// Close the focused pane (`closeFocusedPane`). The last pane of a tab
    /// cannot be closed this way; the tab is closed instead. An editor with
    /// unsaved text asks first, like its close button.
    pub fn close_focused(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pane_count() <= 1 {
            return;
        }
        let Some(item) = self.focused_item() else {
            return;
        };
        let id = item.entity_id();
        if let PaneItem::Editor(editor) = item {
            let confirm = editor.update(cx, |e, cx| e.confirm_close(window, cx));
            cx.spawn_in(window, async move |this, cx| {
                if confirm.await {
                    let _ = this.update_in(cx, |this, window, cx| {
                        // The tree may have changed while the editor asked:
                        // never close a pane that left, or the last one.
                        if this.can_close_pane(id) {
                            this.remove(id, cx);
                            this.focus_own(window, cx);
                        }
                    });
                }
            })
            .detach();
            return;
        }
        self.remove(id, cx);
        self.focus_own(window, cx);
    }

    /// `id` is still a pane of this tree, and not its last one.
    fn can_close_pane(&self, id: EntityId) -> bool {
        self.pane_count() > 1 && self.leaves().iter().any(|leaf| leaf.entity_id() == id)
    }

    fn remove(&mut self, id: EntityId, cx: &mut Context<Self>) {
        let sibling = self.root.as_ref().and_then(|root| sibling_focus(root, id));
        if let Some(root) = self.root.take() {
            self.root = remove_leaf(root, id);
        }
        self.subscriptions.retain(|(view, _)| *view != id);
        if let Some(pane) = self.pane_ids.remove(&id) {
            self.pending_restore.remove(&pane);
        }
        let remaining = self.leaves();
        if remaining.is_empty() {
            cx.emit(PaneEvent::Empty);
            cx.notify();
            return;
        }
        if self.focused == Some(id) || self.focused.is_none() {
            // Focus moves to the first pane of the sibling subtree.
            self.focused = sibling.or_else(|| remaining.first().map(PaneItem::entity_id));
        }
        cx.emit(PaneEvent::MetadataChanged);
        cx.notify();
    }

    pub fn focus_step(&mut self, delta: isize, window: &mut Window, cx: &mut Context<Self>) {
        let leaves = self.leaves();
        if leaves.len() < 2 {
            return;
        }
        let current = self
            .focused
            .and_then(|id| leaves.iter().position(|v| v.entity_id() == id))
            .unwrap_or(0);
        let next = (current as isize + delta).rem_euclid(leaves.len() as isize) as usize;
        if matches!(leaves[next], PaneItem::Terminal(_)) {
            self.presentation_terminal = Some(leaves[next].entity_id());
        }
        self.focused = Some(leaves[next].entity_id());
        let handle = leaves[next].focus_handle(cx);
        window.focus(&handle, cx);
        cx.emit(PaneEvent::MetadataChanged);
        cx.notify();
    }

    /// Terminal panes with their ids, in visual order.
    pub fn pane_sessions(&self, cx: &App) -> Vec<(PaneId, Entity<TerminalSession>)> {
        self.views()
            .into_iter()
            .filter_map(|v| {
                let id = *self.pane_ids.get(&v.entity_id())?;
                Some((id, v.read(cx).session.clone()))
            })
            .collect()
    }

    /// Only already constructed live sessions prewarm. Parked restores retain
    /// their full saved payload without creating invisible PTYs on hover.
    pub(crate) fn prewarm_surface(&mut self, hovered: bool, cx: &mut Context<Self>) {
        for (_, session) in self.pane_sessions(cx) {
            session.update(cx, |session, cx| session.prewarm_surface(hovered, cx));
        }
    }

    /// Id of the focused pane, whatever its kind (`focusedPaneID`).
    pub fn focused_pane_id(&self) -> Option<PaneId> {
        if let Some(saved) = &self.deferred_saved {
            return saved
                .focused_pane
                .or_else(|| saved.panes.first().map(|p| p.id));
        }
        self.focused_item()
            .and_then(|item| self.pane_ids.get(&item.entity_id()).copied())
    }

    /// The split layout, for saving (`exportLayout`).
    pub fn export_layout(&self, cx: &App) -> Option<SavedSplitNode> {
        if let Some(saved) = &self.deferred_saved {
            return saved.layout.clone();
        }
        fn path_string(path: Option<&std::path::Path>) -> Option<String> {
            path.map(|p| p.to_string_lossy().into_owned())
        }
        fn walk(tree: &PaneTree, node: &Node<PaneItem>, cx: &App) -> Option<SavedSplitNode> {
            match node {
                Node::Leaf(item) => {
                    let id = *tree.pane_ids.get(&item.entity_id())?;
                    Some(match item {
                        PaneItem::Terminal(view) => SavedSplitNode::Terminal {
                            id,
                            directory: live_cwd(view.read(cx).session.read(cx))
                                .map(|p| p.to_string_lossy().to_string()),
                        },
                        PaneItem::Editor(editor) => SavedSplitNode::Editor {
                            id,
                            path: path_string(editor.read(cx).path()),
                        },
                        PaneItem::Preview(preview) => SavedSplitNode::Preview {
                            id,
                            path: path_string(preview.read(cx).path()),
                        },
                        PaneItem::Dashboard(d) => SavedSplitNode::Dashboard {
                            id,
                            directory: Some(d.read(cx).repository_root().to_owned()),
                        },
                        PaneItem::Repository(r) => SavedSplitNode::Repository {
                            id,
                            directory: r
                                .read(cx)
                                .directory()
                                .map(|p| p.to_string_lossy().into_owned()),
                        },
                        PaneItem::Diff(diff) => {
                            let diff = diff.read(cx);
                            SavedSplitNode::Diff {
                                id,
                                file: diff.file().map(str::to_string),
                                directory: diff.directory().map(str::to_string),
                                mode: Some(diff.mode().raw().to_string()),
                            }
                        }
                    })
                }
                Node::Split {
                    axis,
                    children,
                    ratios,
                    id,
                } => Some(SavedSplitNode::Split {
                    id: *id,
                    axis: match axis {
                        Axis::Horizontal => SavedAxis::Horizontal,
                        Axis::Vertical => SavedAxis::Vertical,
                    },
                    ratios: ratios.clone(),
                    children: children.iter().filter_map(|c| walk(tree, c, cx)).collect(),
                }),
            }
        }
        walk(self, self.root.as_ref()?, cx)
    }

    /// What was saved for a pane that has not been restored yet.
    pub fn pending_restore(&self, pane: PaneId) -> Option<&SavedPane> {
        self.pending_restore.get(&pane)
    }

    pub(crate) fn restored_metadata(&self, pane: PaneId) -> Option<&SavedPane> {
        self.restored_metadata.get(&pane)
    }

    // ----- restore ------------------------------------------------------

    /// Directory of the focused pane (for new tabs, restore).
    pub fn cwd(&self, cx: &App) -> Option<PathBuf> {
        if let Some(saved) = &self.deferred_saved {
            return self
                .deferred_cwd
                .clone()
                .or_else(|| saved.cwd.clone())
                .or_else(|| {
                    saved
                        .panes
                        .iter()
                        .find(|p| Some(p.id) == saved.focused_pane)
                        .or_else(|| saved.panes.first())
                        .and_then(|p| p.directory.as_ref().map(PathBuf::from))
                });
        }
        self.focused_session(cx)
            .and_then(|s| s.read(cx).cwd.clone())
    }

    /// Count panes that own running work, including agents between turns
    /// and commands without shell integration. Reuse the shared background
    /// process snapshot so close confirmation never scans on the UI thread.
    pub fn running_process_count(&self, cx: &App) -> usize {
        self.views()
            .iter()
            .map(|v| {
                let session = v.read(cx).session.read(cx);
                if session.exited.is_some() {
                    return 0;
                }
                let has_children = !crate::monitoring::process_tree::observed_names(
                    session.shell_pid() as u32,
                    cx,
                )
                .is_empty();
                usize::from(session.shell().requires_process_close_warning(has_children))
            })
            .sum()
    }

    /// Names of the processes running under the shells of this tab, for the
    /// quit confirmation.
    pub fn running_process_names(&self, cx: &App) -> Vec<String> {
        let mut names = Vec::new();
        for view in self.views() {
            let session = view.read(cx).session.read(cx);
            if session.exited.is_some() {
                continue;
            }
            names.extend(crate::monitoring::process_tree::observed_names(
                session.shell_pid() as u32,
                cx,
            ));
        }
        names
    }

    /// Send input to the focused pane of `panes` without re-broadcasting it.
    pub fn send_input(panes: &Entity<PaneTree>, bytes: &[u8], cx: &mut App) -> bool {
        panes
            .read(cx)
            .focused_view()
            .is_some_and(|view| view.update(cx, |v, cx| v.write_without_broadcast(bytes, cx)))
    }

    /// Why the focused terminal is not accepting input, if it is not.
    pub fn input_hold(panes: &Entity<PaneTree>, cx: &App) -> Option<String> {
        panes.read(cx).focused_view()?.read(cx).input_hold(cx)
    }

    /// A synthesized key press (MCP `tab_press_key`, KBD-017) to the focused
    /// pane, encoded with its current cursor mode (`sendKeyPress`). `false`
    /// when there is no terminal or the key cannot be encoded.
    pub fn send_key_press(
        panes: &Entity<PaneTree>,
        press: &chau7_next_core::terminal_key_press::TerminalKeyPress,
        cx: &mut App,
    ) -> bool {
        let Some(view) = panes.read(cx).focused_view() else {
            return false;
        };
        let app_cursor = view.read(cx).session.read(cx).is_app_cursor();
        let Ok(encoded) = press.encode(app_cursor) else {
            return false;
        };
        view.update(cx, |v, cx| v.write_without_broadcast(&encoded.bytes, cx))
    }

    pub fn set_font_size(&mut self, size: f32, cx: &mut Context<Self>) {
        for view in self.views() {
            view.update(cx, |v, cx| v.set_font_size(size, cx));
        }
    }

    pub fn reload_settings(&mut self, reset_terminal_font_size: bool, cx: &mut Context<Self>) {
        let settings = Settings::get(cx).clone();
        for item in self.leaves() {
            match item {
                PaneItem::Terminal(view) => view.update(cx, |v, cx| {
                    v.session
                        .update(cx, |session, _| session.apply_settings(&settings));
                    if reset_terminal_font_size {
                        v.set_font_size(settings.appearance.zoomed_font_size(), cx);
                    }
                    // Settings such as family and line height still affect the
                    // terminal's cached metrics even when its per-tab zoom stays.
                    cx.notify();
                }),
                PaneItem::Editor(editor) => editor.update(cx, |e, cx| e.settings_changed(cx)),
                PaneItem::Preview(preview) => preview.update(cx, |p, cx| p.apply_settings(cx)),
                PaneItem::Diff(diff) => diff.update(cx, |d, cx| d.apply_settings(cx)),
                PaneItem::Repository(_) | PaneItem::Dashboard(_) => {}
            }
        }
    }

    fn set_ratio(&mut self, split_id: u64, index: usize, fraction: f32) {
        if let Some(root) = self.root.as_mut() {
            set_ratio(root, split_id, index, fraction);
        }
    }

    fn render_node(
        &self,
        node: &Node<PaneItem>,
        show_focus: bool,
        chrome: Chrome,
        hidden_edges: HiddenPaneEdges,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        match node {
            Node::Leaf(item) => {
                let focused = self.focused == Some(item.entity_id());
                let (loading, flash) = match item {
                    PaneItem::Terminal(view) => {
                        let session = view.read(cx).session.read(cx);
                        (
                            crate::terminal::loading_overlay::overlay(session, session.id, chrome),
                            session.bell_flash_alpha(),
                        )
                    }
                    _ => (None, 0.0),
                };
                let mut pane = div().size_full().relative();
                if show_focus {
                    pane = pane.border_1().border_color(if focused {
                        chrome.accent.opacity(0.6)
                    } else {
                        chrome.border.opacity(0.0)
                    });
                    if hidden_edges.top {
                        pane = pane.border_t_0();
                    }
                    if hidden_edges.right {
                        pane = pane.border_r_0();
                    }
                    if hidden_edges.bottom {
                        pane = pane.border_b_0();
                    }
                    if hidden_edges.left {
                        pane = pane.border_l_0();
                    }
                }
                pane.child(item.element())
                    .children(loading)
                    // Visual bell (`flashBell`: white at 15%).
                    .when(flash > 0.0, |d| {
                        d.child(
                            div()
                                .absolute()
                                .inset_0()
                                .bg(gpui::white().opacity(0.15 * flash)),
                        )
                    })
                    .into_any_element()
            }
            Node::Split {
                axis,
                children,
                ratios,
                id,
            } => {
                let split_id = *id;
                let mut container = div().size_full().flex().id(("split", split_id as usize));
                container = match axis {
                    Axis::Horizontal => container.flex_row(),
                    Axis::Vertical => container.flex_col(),
                };
                let axis = *axis;
                container = container.on_drag_move(cx.listener(
                    move |this, event: &DragMoveEvent<DividerDrag>, _window, cx| {
                        let drag = event.drag(cx).clone();
                        if drag.split_id != split_id {
                            return;
                        }
                        let bounds = event.bounds;
                        let divider_count = this
                            .root
                            .as_ref()
                            .and_then(|root| split_child_count(root, split_id))
                            .unwrap_or(drag.index + 2);
                        let (position, origin, extent) = match axis {
                            Axis::Horizontal => (
                                f32::from(event.event.position.x),
                                f32::from(bounds.left()),
                                f32::from(bounds.size.width),
                            ),
                            Axis::Vertical => (
                                f32::from(event.event.position.y),
                                f32::from(bounds.top()),
                                f32::from(bounds.size.height),
                            ),
                        };
                        let fraction = split_resize_fraction(
                            position,
                            origin,
                            extent,
                            divider_count,
                            drag.index,
                            drag.grab_offset.get(),
                        )
                        .unwrap_or(0.5);
                        this.set_ratio(split_id, drag.index, fraction);
                        cx.notify();
                    },
                ));
                for (index, child) in children.iter().enumerate() {
                    let ratio = ratios.get(index).copied().unwrap_or(1.0);
                    let child_edges = hidden_edges.child(axis, index, children.len());
                    let element = self.render_node(child, show_focus, chrome, child_edges, cx);
                    let mut cell = div()
                        .flex_shrink_0()
                        .flex_basis(px(0.))
                        .flex_grow(ratio)
                        .overflow_hidden();
                    cell = match axis {
                        Axis::Horizontal => cell.h_full().min_w_0(),
                        Axis::Vertical => cell.w_full().min_h_0(),
                    };
                    container = container.child(cell.child(element));
                    if index + 1 < children.len() {
                        let drag = DividerDrag {
                            split_id,
                            index,
                            grab_offset: Rc::new(Cell::new(0.0)),
                        };
                        let divider = div()
                            .id(("divider", (split_id as usize) << 8 | index))
                            .relative()
                            .flex_shrink_0()
                            .on_drag(drag, move |drag, offset, _, cx| {
                                drag.grab_offset.set(match axis {
                                    Axis::Horizontal => f32::from(offset.x),
                                    Axis::Vertical => f32::from(offset.y),
                                });
                                cx.new(|_| DividerGhost)
                            });
                        let divider = match axis {
                            Axis::Horizontal => divider
                                .w(px(SPLIT_DIVIDER_HITBOX))
                                .h_full()
                                .cursor_col_resize()
                                .child(div().absolute().inset_0().flex().justify_center().child(
                                    div().w(px(SPLIT_DIVIDER_RULE)).h_full().bg(chrome.border),
                                )),
                            Axis::Vertical => divider
                                .h(px(SPLIT_DIVIDER_HITBOX))
                                .w_full()
                                .cursor_row_resize()
                                .child(div().absolute().inset_0().flex().items_center().child(
                                    div().h(px(SPLIT_DIVIDER_RULE)).w_full().bg(chrome.border),
                                )),
                        };
                        container = container.child(divider);
                    }
                }
                container.into_any_element()
            }
        }
    }
}

// ----- tree functions (generic so they can be tested without entities) ----

fn collect_leaves<L: Clone>(node: &Node<L>, out: &mut Vec<L>) {
    match node {
        Node::Leaf(l) => out.push(l.clone()),
        Node::Split { children, .. } => children.iter().for_each(|c| collect_leaves(c, out)),
    }
}

fn set_ratio<L>(node: &mut Node<L>, split_id: u64, index: usize, fraction: f32) -> bool {
    match node {
        Node::Leaf(_) => false,
        Node::Split {
            id,
            ratios,
            children,
            ..
        } => {
            if *id == split_id && index + 1 < ratios.len() {
                let before: f32 = ratios[..index].iter().sum();
                let pair = ratios[index] + ratios[index + 1];
                let min = 0.1_f32.min(pair / 2.0);
                let left = (fraction - before).clamp(min, pair - min);
                ratios[index] = left;
                ratios[index + 1] = pair - left;
                return true;
            }
            children
                .iter_mut()
                .any(|c| set_ratio(c, split_id, index, fraction))
        }
    }
}

fn split_child_count<L>(node: &Node<L>, split_id: u64) -> Option<usize> {
    match node {
        Node::Leaf(_) => None,
        Node::Split { id, children, .. } => {
            if *id == split_id {
                Some(children.len())
            } else {
                children
                    .iter()
                    .find_map(|child| split_child_count(child, split_id))
            }
        }
    }
}

fn split_resize_fraction(
    position: f32,
    origin: f32,
    extent: f32,
    child_count: usize,
    divider_index: usize,
    grab_offset: f32,
) -> Option<f32> {
    if child_count < 2 || divider_index + 1 >= child_count {
        return None;
    }
    let divider_count = (child_count - 1) as f32;
    let available = extent - divider_count * SPLIT_DIVIDER_HITBOX;
    if available <= 0.0 {
        return None;
    }
    let preceding_track_width = divider_index as f32 * SPLIT_DIVIDER_HITBOX;
    Some((position - origin - preceding_track_width - grab_offset) / available)
}

fn first_leaf<L: LeafKey>(node: &Node<L>) -> EntityId {
    match node {
        Node::Leaf(v) => v.key(),
        Node::Split { children, .. } => first_leaf(&children[0]),
    }
}

/// First pane of the subtree next to `target`: the previous sibling, or the
/// next one when `target` is first (`removeNode`'s `siblingID`).
fn sibling_focus<L: LeafKey>(node: &Node<L>, target: EntityId) -> Option<EntityId> {
    let Node::Split { children, .. } = node else {
        return None;
    };
    if let Some(index) = children
        .iter()
        .position(|c| matches!(c, Node::Leaf(v) if v.key() == target))
    {
        let other = if index > 0 { index - 1 } else { index + 1 };
        return children.get(other).map(first_leaf);
    }
    children.iter().find_map(|c| sibling_focus(c, target))
}

fn insert_split<L: LeafKey>(
    node: Node<L>,
    target: EntityId,
    axis: Axis,
    new_leaf: L,
    split_id: u64,
) -> Node<L> {
    match node {
        Node::Leaf(leaf) if leaf.key() == target => Node::Split {
            axis,
            children: vec![Node::Leaf(leaf), Node::Leaf(new_leaf)],
            ratios: vec![0.5, 0.5],
            id: split_id,
        },
        Node::Leaf(leaf) => Node::Leaf(leaf),
        Node::Split {
            axis: split_axis,
            children,
            ratios,
            id,
        } => {
            let target_index = children
                .iter()
                .position(|c| matches!(c, Node::Leaf(v) if v.key() == target));
            if split_axis == axis
                && let Some(index) = target_index
            {
                // Same direction: add a sibling and share the target's space.
                let mut children = children;
                let mut ratios = ratios;
                let half = ratios[index] / 2.0;
                ratios[index] = half;
                ratios.insert(index + 1, half);
                children.insert(index + 1, Node::Leaf(new_leaf));
                return Node::Split {
                    axis: split_axis,
                    children,
                    ratios,
                    id,
                };
            }
            let mut new_leaf = Some(new_leaf);
            let children = children
                .into_iter()
                .map(|child| {
                    if contains(&child, target) {
                        insert_split(child, target, axis, new_leaf.take().unwrap(), split_id)
                    } else {
                        child
                    }
                })
                .collect();
            Node::Split {
                axis: split_axis,
                children,
                ratios,
                id,
            }
        }
    }
}

fn contains<L: LeafKey>(node: &Node<L>, target: EntityId) -> bool {
    match node {
        Node::Leaf(v) => v.key() == target,
        Node::Split { children, .. } => children.iter().any(|c| contains(c, target)),
    }
}

fn remove_leaf<L: LeafKey>(node: Node<L>, target: EntityId) -> Option<Node<L>> {
    match node {
        Node::Leaf(v) if v.key() == target => None,
        Node::Leaf(v) => Some(Node::Leaf(v)),
        Node::Split {
            axis,
            children,
            ratios,
            id,
        } => {
            let mut kept_children = Vec::new();
            let mut kept_ratios = Vec::new();
            for (child, ratio) in children.into_iter().zip(ratios) {
                if let Some(child) = remove_leaf(child, target) {
                    kept_children.push(child);
                    kept_ratios.push(ratio);
                }
            }
            match kept_children.len() {
                0 => None,
                1 => kept_children.pop(),
                _ => {
                    let total: f32 = kept_ratios.iter().sum();
                    let ratios = kept_ratios.iter().map(|r| r / total).collect();
                    Some(Node::Split {
                        axis,
                        children: kept_children,
                        ratios,
                        id,
                    })
                }
            }
        }
    }
}

impl Render for PaneTree {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.restore_selected.set(true);
        self.activate_deferred(window, cx);
        let chrome = Chrome::get(cx);
        let show_focus = self.pane_count() > 1;
        let content = match &self.root {
            Some(_) => {
                // Render needs &self while the listener needs cx; take the tree briefly.
                let root = self.root.take();
                let element = self.render_node(
                    root.as_ref().unwrap(),
                    show_focus,
                    chrome,
                    HiddenPaneEdges::default(),
                    cx,
                );
                self.root = root;
                element
            }
            None => div()
                .child(crate::l10n::l("misc.loading", "Loading..."))
                .into_any_element(),
        };
        div()
            .size_full()
            .bg(chrome.terminal_bg)
            // Command palette "Scroll to Top" / "Scroll to Bottom" (RBK-026).
            .on_action(cx.listener(|this, _: &ScrollToTop, _, cx| {
                if let Some(session) = this.focused_session(cx) {
                    session.update(cx, |s, cx| {
                        s.scroll_to_top();
                        s.refresh(cx);
                    });
                }
            }))
            .on_action(cx.listener(|this, _: &ScrollToBottom, _, cx| {
                if let Some(session) = this.focused_session(cx) {
                    session.update(cx, |s, cx| {
                        s.scroll_to_bottom();
                        s.refresh(cx);
                    });
                }
            }))
            .child(content)
    }
}

impl Focusable for PaneTree {
    fn focus_handle(&self, cx: &App) -> gpui::FocusHandle {
        self.focused_item()
            .map(|item| item.focus_handle(cx))
            .unwrap_or_else(|| cx.focus_handle())
    }
}

#[cfg(all(test, unix))]
mod terminal_font_settings_tests {
    use super::*;
    use crate::settings::Settings;
    use crate::terminal::session::TerminalSession;
    use crate::workspace::AppData;
    use chau7_next_core::data_root::DataRoot;
    use chau7_terminal::Chau7Terminal;
    use gpui::{AppContext, TestAppContext};
    use gpui_kit::test::TestWindowExt;

    /// A real TerminalView and PaneTree verify that unrelated appearance
    /// changes retain the tab's zoom while changed defaults reset it.
    #[gpui::test]
    fn terminal_settings_reload_preserves_or_resets_tab_zoom(harness: &mut TestAppContext) {
        let home = std::env::temp_dir().join(format!(
            "chau7-terminal-font-settings-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&home).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        harness.update(|cx| {
            gpui_kit::init(cx);
            cx.set_global(Settings::default());
            cx.set_global(AppData::new(root));
            crate::terminal::command_guard::init(cx);
        });

        let (window, tree) = harness.update(|cx| {
            gpui_kit::open_window(gpui::WindowOptions::default(), cx, |window, cx| {
                let terminal = Chau7Terminal::new_headless(80, 24).unwrap();
                let session =
                    cx.new(|cx| TerminalSession::from_terminal_manually_driven(terminal, None, cx));
                let view = cx.new(|cx| TerminalView::new(session, window, cx));
                let id = view.entity_id();
                let mut tree = PaneTree::empty();
                tree.root = Some(Node::Leaf(PaneItem::Terminal(view)));
                tree.focused = Some(id);
                tree.presentation_terminal = Some(id);
                cx.new(|_| tree)
            })
            .unwrap()
        });
        let view = harness.update(|cx| tree.read(cx).focused_view().unwrap());

        harness.update(|cx| view.update(cx, |view, cx| view.set_font_size(17.0, cx)));
        harness
            .update_window(window, |_, window, cx| window.render_frame(cx))
            .unwrap();
        assert_eq!(harness.update(|cx| view.read(cx).font_size()), 17.0);

        harness.update(|cx| {
            let mut settings = cx.global::<Settings>().clone();
            settings.appearance.font_family = "Menlo".into();
            cx.set_global(settings);
            tree.update(cx, |tree, cx| tree.reload_settings(false, cx));
        });
        harness
            .update_window(window, |_, window, cx| window.render_frame(cx))
            .unwrap();
        assert_eq!(harness.update(|cx| view.read(cx).font_size()), 17.0);

        harness.update(|cx| {
            let mut settings = cx.global::<Settings>().clone();
            settings.appearance.font_size = 14.0;
            cx.set_global(settings);
            tree.update(cx, |tree, cx| tree.reload_settings(true, cx));
        });
        harness
            .update_window(window, |_, window, cx| window.render_frame(cx))
            .unwrap();
        assert_eq!(harness.update(|cx| view.read(cx).font_size()), 14.0);
        let _ = std::fs::remove_dir_all(home);
    }

    fn init_headless(harness: &mut TestAppContext, label: &str) -> std::path::PathBuf {
        let home = std::env::temp_dir().join(format!("chau7-{label}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        harness.update(|cx| {
            gpui_kit::init(cx);
            cx.set_global(Settings::default());
            cx.set_global(AppData::new(root));
            crate::terminal::command_guard::init(cx);
            crate::observability::init_for_test(cx);
        });
        home
    }

    /// `close_on_exit`: the exited pane had the keyboard, so the pane that
    /// takes its place gets it (as Close Pane does).
    #[gpui::test]
    fn exited_focused_pane_hands_focus_to_its_sibling(harness: &mut TestAppContext) {
        let home = init_headless(harness, "exit-focus");
        let (window, tree) = harness.update(|cx| {
            gpui_kit::open_window(gpui::WindowOptions::default(), cx, |window, cx| {
                cx.new(|cx| PaneTree::headless_for_test(2, window, cx))
            })
            .unwrap()
        });
        let (first, second) = harness.update(|cx| {
            let views = tree.read(cx).views();
            (views[0].clone(), views[1].clone())
        });
        harness
            .update_window(window, |_, window, cx| {
                let handle = second.read(cx).focus_handle(cx);
                window.focus(&handle, cx);
                window.render_frame(cx);
            })
            .unwrap();
        harness.update(|cx| {
            second
                .read(cx)
                .session
                .clone()
                .update(cx, |_, cx| cx.emit(SessionEvent::Exited(Some(0))));
        });
        harness.run_until_parked();
        harness
            .update_window(window, |_, window, cx| {
                assert_eq!(tree.read(cx).pane_count(), 1);
                assert!(first.read(cx).focus_handle(cx).is_focused(window));
            })
            .unwrap();
        let _ = std::fs::remove_dir_all(home);
    }

    /// After an editor's save prompt, close only a pane still in the tree
    /// and never the last one.
    #[gpui::test]
    fn deferred_close_rechecks_the_tree(harness: &mut TestAppContext) {
        let home = init_headless(harness, "close-recheck");
        let (_, tree) = harness.update(|cx| {
            gpui_kit::open_window(gpui::WindowOptions::default(), cx, |window, cx| {
                cx.new(|cx| PaneTree::headless_for_test(2, window, cx))
            })
            .unwrap()
        });
        harness.update(|cx| {
            let views = tree.read(cx).views();
            let (first, second) = (views[0].entity_id(), views[1].entity_id());
            assert!(tree.read(cx).can_close_pane(second));
            tree.update(cx, |tree, cx| tree.remove(second, cx));
            assert!(!tree.read(cx).can_close_pane(second), "already gone");
            assert!(!tree.read(cx).can_close_pane(first), "last pane");
        });
        let _ = std::fs::remove_dir_all(home);
    }

    #[gpui::test]
    fn repository_input_focus_returns_to_terminal_on_click(harness: &mut TestAppContext) {
        let home =
            std::env::temp_dir().join(format!("chau7-repository-focus-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        harness.update(|cx| {
            gpui_kit::init(cx);
            cx.set_global(Settings::default());
            cx.set_global(AppData::new(root));
            crate::terminal::command_guard::init(cx);
            crate::observability::init_for_test(cx);
        });

        let (window, tree, terminal, session, search, repository_id) = harness.update(|cx| {
            let mut captured = None;
            let (window, _) =
                gpui_kit::open_window(gpui::WindowOptions::default(), cx, |window, cx| {
                    // Keep input admission enabled with an isolated process.
                    // A headless terminal has PID 0, which production correctly
                    // rejects at the shared input-admission boundary.
                    let terminal_model = Chau7Terminal::new_with_args_env_in_dir(
                        80,
                        24,
                        "/bin/cat",
                        &[],
                        &[("TERM", "xterm-256color")],
                        None,
                    )
                    .unwrap();
                    let session = cx.new(|cx| {
                        TerminalSession::from_terminal_manually_driven(terminal_model, None, cx)
                    });
                    let terminal = cx.new(|cx| TerminalView::new(session.clone(), window, cx));
                    let terminal_id = terminal.entity_id();
                    let tree = cx.new(|_| {
                        let mut tree = PaneTree::empty();
                        tree.root = Some(Node::Leaf(PaneItem::Terminal(terminal.clone())));
                        tree.focused = Some(terminal_id);
                        tree.presentation_terminal = Some(terminal_id);
                        tree
                    });
                    let repository = tree.update(cx, |tree, cx| {
                        let repository = tree.create_repository(new_pane_id(), window, cx);
                        tree.root = Some(Node::Split {
                            axis: Axis::Horizontal,
                            children: vec![
                                Node::Leaf(PaneItem::Terminal(terminal.clone())),
                                Node::Leaf(PaneItem::Repository(repository.clone())),
                            ],
                            ratios: vec![0.5, 0.5],
                            id: 1,
                        });
                        repository
                    });
                    let repository_id = repository.entity_id();
                    let search =
                        repository.update(cx, |repository, _| repository.test_history_search());
                    let focus_subscription = tree.update(cx, |_, cx| {
                        cx.subscribe_in(&terminal, window, move |tree, _, event, _, cx| {
                            if matches!(event, TerminalViewEvent::Focused) {
                                tree.set_focused(terminal_id, cx);
                            }
                        })
                    });
                    tree.update(cx, |tree, _| {
                        tree.subscriptions
                            .push((terminal_id, vec![focus_subscription]));
                    });
                    // Use the same initial focus entry point as workspace selection.
                    PaneTree::focus_entity(&tree, window, cx);
                    captured = Some((tree.clone(), terminal, session, search, repository_id));
                    tree
                })
                .unwrap();
            let (tree, terminal, session, search, repository_id) = captured.unwrap();
            (window, tree, terminal, session, search, repository_id)
        });

        // Focus-in/out callbacks require an active headless window, just as
        // native windows do. Let the queued activation callback settle first.
        harness
            .update_window(window, |_, window, _| window.activate_window())
            .unwrap();
        harness.run_until_parked();

        let mut input_revision_before_terminal = 0;
        let terminal_point = harness
            .update_window(window, |_, window, cx| {
                window.render_frame(cx);
                assert!(terminal.read(cx).focus_handle(cx).is_focused(window));
                assert_eq!(tree.read(cx).focused, Some(terminal.entity_id()));
                assert!(session.read(cx).shell_pid() > 0);
                let before = session.read(cx).input_revision();
                window.input("baseline", cx);
                assert!(
                    session.read(cx).input_revision() > before,
                    "the initially focused terminal must accept text before the focus handoff"
                );
                // The left half of this fixed two-pane fixture is the terminal.
                // Raw terminal divs do not register GPUI Kit component snapshots.
                let size = window.viewport_size();
                let terminal_point = gpui::point(size.width / 4.0, size.height / 2.0);
                window.click(("input", search.entity_id()), cx);
                terminal_point
            })
            .unwrap();
        harness.run_until_parked();

        harness
            .update_window(window, |_, window, cx| {
                assert!(
                    search.read(cx).focus_handle(cx).is_focused(window),
                    "selecting the repository pane must preserve focus in its clicked search input"
                );
                assert_eq!(tree.read(cx).focused, Some(repository_id));
                window.input("repository probe", cx);
                assert_eq!(search.read(cx).value().as_ref(), "repository probe");

                input_revision_before_terminal = session.read(cx).input_revision();
                // Hit-test the terminal position as a real pointer click would,
                // without changing focus directly or relying on component IDs.
                window.dispatch_event(
                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                        position: terminal_point,
                        pressed_button: None,
                        modifiers: Default::default(),
                    }),
                    cx,
                );
                window.render_frame(cx);
                window.dispatch_event(
                    gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                        position: terminal_point,
                        button: gpui::MouseButton::Left,
                        modifiers: Default::default(),
                        click_count: 1,
                        first_mouse: false,
                    }),
                    cx,
                );
                window.render_frame(cx);
                window.dispatch_event(
                    gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                        position: terminal_point,
                        button: gpui::MouseButton::Left,
                        modifiers: Default::default(),
                        click_count: 1,
                    }),
                    cx,
                );
                window.render_frame(cx);
            })
            .unwrap();
        harness.run_until_parked();

        harness
            .update_window(window, |_, window, cx| {
                assert!(terminal.read(cx).focus_handle(cx).is_focused(window));
                assert_eq!(tree.read(cx).focused, Some(terminal.entity_id()));
                window.input("git status", cx);
                assert!(
                    session.read(cx).input_revision() > input_revision_before_terminal,
                    "text after clicking the shell must be delivered to the terminal input handler"
                );
                assert_eq!(search.read(cx).value().as_ref(), "repository probe");
            })
            .unwrap();

        drop(tree);
        harness.update(|cx| session.update(cx, |session, _| session.close()));
        harness
            .update_window(window, |_, window, _| window.remove_window())
            .unwrap();
        let _ = std::fs::remove_dir_all(home);
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::{SavedAxis, SavedPane, SavedSplitNode};

    #[test]
    fn displayed_terminal_wins_when_focus_falls_back_from_a_side_pane() {
        let available = [1, 2];
        // A focused side pane has no terminal ID, so focused_view() falls back
        // to the first terminal while presentation_terminal retains the last
        // displayed terminal.
        assert_eq!(
            super::preferred_available_id(&available, Some(2), Some(1)),
            Some(2)
        );
        // If a displayed terminal was removed, use the focused terminal only
        // when it is still in the current split tree.
        assert_eq!(
            super::preferred_available_id(&available, Some(3), Some(1)),
            Some(1)
        );
        assert_eq!(
            super::preferred_available_id(&available, Some(3), None),
            None
        );
    }

    #[test]
    fn restored_primary_directory_does_not_fall_back_to_focused_secondary() {
        let saved = super::SavedTab {
            cwd: Some(PathBuf::from("/secondary-repo")),
            layout: Some(SavedSplitNode::Split {
                id: 1,
                axis: SavedAxis::Horizontal,
                ratios: vec![0.5, 0.5],
                children: vec![
                    SavedSplitNode::Terminal {
                        id: 10,
                        directory: None,
                    },
                    SavedSplitNode::Terminal {
                        id: 20,
                        directory: Some("/secondary-repo/src".into()),
                    },
                ],
            }),
            focused_pane: Some(20),
            panes: vec![
                SavedPane {
                    id: 10,
                    directory: None,
                    ..Default::default()
                },
                SavedPane {
                    id: 20,
                    directory: Some("/secondary-repo/src".into()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let deferred_cwd = PathBuf::from("/secondary-repo/src");
        assert_eq!(
            super::restored_primary_cwd(&saved, Some(&deferred_cwd)),
            None
        );

        let editor_only = super::SavedTab {
            cwd: Some(PathBuf::from("/focused-repo")),
            layout: Some(SavedSplitNode::Editor {
                id: 30,
                path: Some("/focused-repo/README.md".into()),
            }),
            ..Default::default()
        };
        assert_eq!(
            super::restored_primary_cwd(&editor_only, Some(&deferred_cwd)),
            None
        );
    }

    #[test]
    fn primary_and_displayed_session_metadata_reaches_tab_state() {
        let focused = super::EntityId::from(1_u64);
        let primary = super::EntityId::from(2_u64);
        let displayed = super::EntityId::from(3_u64);
        let unrelated = super::EntityId::from(4_u64);
        assert!(super::session_metadata_updates_tab(
            primary,
            Some(focused),
            Some(primary),
            Some(displayed)
        ));
        assert!(super::session_metadata_updates_tab(
            displayed,
            Some(focused),
            Some(primary),
            Some(displayed)
        ));
        assert!(!super::session_metadata_updates_tab(
            unrelated,
            Some(focused),
            Some(primary),
            Some(displayed)
        ));
    }

    #[test]
    fn parked_identity_result_keeps_full_payload_and_rejects_selection_owner_and_generation_changes()
     {
        let home = std::env::temp_dir().join(format!(
            "chau7-next-identity-admission-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&home).unwrap();
        let root = chau7_next_core::data_root::DataRoot::with_home(home.clone(), true);
        let owner = uuid::Uuid::new_v4();
        let archived_ai = chau7_next_core::session_restore::models::ArchivedAIResumeMetadata {
            provider: Some("codex".into()),
            session_id: Some("synth:fixture".into()),
            session_id_source: Some("synthetic".into()),
            resume_command: None,
        };
        let archived_context = chau7_next_core::session_restore::models::ArchivedTabContext {
            command_blocks: Some(vec![serde_json::json!({"command":"printf inert"})]),
            preview_snapshot_png_data: Some("AQID".into()),
        };
        let saved = SavedTab {
            uuid: Some(owner),
            cwd: Some(home.clone()),
            focused_pane: Some(8),
            archived_context: Some(archived_context.clone()),
            panes: vec![SavedPane {
                id: 8,
                scrollback: true,
                ai_provider: Some("codex".into()),
                ai_session_id: Some("thread-fixture".into()),
                archived_ai_resume: Some(archived_ai.clone()),
                ..Default::default()
            }],
            ..Default::default()
        };
        let mut prepared =
            crate::restore::preparation::prepare_identity(&root, saved.clone(), None);
        crate::restore::preparation::register_saved_identity_hints(&root, [&saved]);
        let hint_generation = crate::restore::preparation::identity_hint_generation(&root);
        let mut tree = super::PaneTree::park_saved(saved.clone(), None);
        tree.owner_tab = Some(owner);
        tree.identity_generation = 3;
        assert!(!tree.apply_deferred_identity(owner, 2, hint_generation, &root, &mut prepared));
        assert!(!tree.apply_deferred_identity(
            uuid::Uuid::new_v4(),
            3,
            hint_generation,
            &root,
            &mut prepared
        ));
        tree.restore_selected.set(true);
        assert!(!tree.apply_deferred_identity(owner, 3, hint_generation, &root, &mut prepared));
        tree.restore_selected.set(false);
        assert!(tree.apply_deferred_identity(owner, 3, hint_generation, &root, &mut prepared));
        assert!(tree.root.is_none());
        assert!(tree.views().is_empty());
        assert!(tree.subscriptions.is_empty());
        assert!(tree.deferred_saved().unwrap().panes[0].scrollback);
        assert_eq!(
            tree.deferred_saved().unwrap().panes[0]
                .ai_resume_command
                .as_deref(),
            Some("codex resume thread-fixture")
        );
        assert_eq!(tree.archived_context(), Some(&archived_context));
        assert_eq!(
            tree.restored_metadata(8)
                .and_then(|pane| pane.archived_ai_resume.as_ref()),
            Some(&archived_ai)
        );
        assert_eq!(
            crate::restore::archived_ai_resume_for_capture(tree.restored_metadata(8)),
            Some(archived_ai.clone())
        );
        assert_eq!(tree.archived_context().cloned(), Some(archived_context));
        assert!(tree.restore_prepared.is_none());
        tree.deferred_saved = None;
        assert!(!tree.apply_deferred_identity(owner, 3, hint_generation, &root, &mut prepared));
        crate::restore::preparation::release_owner(&root, owner);
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn background_identity_is_wired_before_activation_and_never_delivers_a_resume() {
        let pane = include_str!("pane.rs");
        let start = pane
            .find("    pub(crate) fn hydrate_deferred_identity(")
            .unwrap();
        let end = pane[start..]
            .find("    pub(crate) fn set_restore_surface(")
            .unwrap()
            + start;
        let hydration = &pane[start..end];
        assert!(hydration.contains("cx.background_spawn"));
        assert!(hydration.contains("prepare_identity(&root"));
        assert!(
            hydration
                .split_whitespace()
                .collect::<String>()
                .contains("this.update(cx")
        );
        assert!(hydration.contains("apply_deferred_identity"));
        for forbidden in [
            "create_terminal(",
            "queue_restored_resume(",
            "replay_restored_context(",
            "write_input(",
            "from_saved_prepared(",
        ] {
            assert!(!hydration.contains(forbidden), "{forbidden}");
        }
        let startup = include_str!("main.rs");
        let load = startup
            .find("let mut restored = session_store::load")
            .unwrap();
        let hints = startup.find("register_saved_identity_hints(").unwrap();
        let splash = startup.find("views::prepare_launch(cx,").unwrap();
        let monitors = startup.find("ai::init(cx);").unwrap();
        assert!(splash < load && load < hints && hints < monitors);
        let scheduler = include_str!("workspace/restore_lifecycle.rs");
        assert!(scheduler.contains("prepared.await"));
    }
    #[test]
    fn deferred_restore_preserves_full_payload_without_constructing_panes() {
        let saved = crate::session_store::SavedTab {
            uuid: Some(uuid::Uuid::from_u128(77)),
            cwd: Some(std::path::PathBuf::from("/repo")),
            focused_pane: Some(8),
            layout: Some(chau7_next_core::session_restore::SavedSplitNode::Terminal {
                id: 8,
                directory: Some("/repo".into()),
            }),
            panes: vec![crate::session_store::SavedPane {
                id: 8,
                scrollback: true,
                ai_provider: Some("claude".into()),
                ai_session_id: Some("fixture".into()),
                ..Default::default()
            }],
            ..Default::default()
        };
        let tree = super::PaneTree::park_saved(saved.clone(), None);
        assert!(tree.is_deferred());
        assert_eq!(tree.deferred_saved(), Some(&saved));
        assert!(tree.root.is_none());
        assert!(tree.pane_ids.is_empty());
        assert!(tree.subscriptions.is_empty());
        assert_eq!(tree.pane_count(), 1);
        assert_eq!(tree.focused_pane_id(), Some(8));
        assert!(tree.note_task.is_none());
    }
    use super::*;

    /// A stand-in leaf with a numeric key (`SplitNodeTests`).
    #[derive(Clone, Debug, PartialEq)]
    struct T(u64);
    impl LeafKey for T {
        fn key(&self) -> EntityId {
            EntityId::from((1u64 << 32) | self.0)
        }
    }

    fn key(n: u64) -> EntityId {
        T(n).key()
    }

    fn leaves(node: &Node<T>) -> Vec<u64> {
        let mut out = Vec::new();
        collect_leaves(node, &mut out);
        out.into_iter().map(|t| t.0).collect()
    }

    #[test]
    fn split_inserts_after_the_target_and_shares_its_space() {
        let root = Node::Leaf(T(1));
        let root = insert_split(root, key(1), Axis::Horizontal, T(2), 10);
        let root = insert_split(root, key(2), Axis::Horizontal, T(3), 11);
        assert_eq!(leaves(&root), vec![1, 2, 3]);
        let Node::Split { ratios, .. } = &root else {
            panic!("split expected");
        };
        assert_eq!(ratios, &vec![0.5, 0.25, 0.25]);
        // Another direction nests a split.
        let root = insert_split(root, key(1), Axis::Vertical, T(4), 12);
        assert_eq!(leaves(&root), vec![1, 4, 2, 3]);
    }

    #[test]
    fn removing_collapses_splits_and_focuses_the_sibling() {
        let root = insert_split(Node::Leaf(T(1)), key(1), Axis::Horizontal, T(2), 1);
        let root = insert_split(root, key(2), Axis::Vertical, T(3), 2);
        assert_eq!(sibling_focus(&root, key(3)), Some(key(2)));
        assert_eq!(sibling_focus(&root, key(1)), Some(key(2)));
        let root = remove_leaf(root, key(3)).unwrap();
        assert_eq!(leaves(&root), vec![1, 2]);
        let root = remove_leaf(root, key(1)).unwrap();
        assert!(matches!(root, Node::Leaf(T(2))));
        assert!(remove_leaf(root, key(2)).is_none());
    }

    #[test]
    fn ratios_stay_between_10_and_90_percent() {
        let mut root = insert_split(Node::Leaf(T(1)), key(1), Axis::Horizontal, T(2), 7);
        assert!(set_ratio(&mut root, 7, 0, 0.95));
        let Node::Split { ratios, .. } = &root else {
            panic!("split expected");
        };
        assert!((ratios[0] - 0.9).abs() < 1e-6);
        assert!(!set_ratio(&mut root, 99, 0, 0.5));
    }
}

#[cfg(test)]
mod pane_render_geometry_tests {
    use super::{Axis, HiddenPaneEdges, split_resize_fraction};

    #[test]
    fn hidden_edges_cover_split_boundaries_and_nested_outer_edges() {
        let edges = HiddenPaneEdges::default();
        let horizontal = (0..3)
            .map(|index| edges.child(Axis::Horizontal, index, 3))
            .collect::<Vec<_>>();
        assert_eq!(
            horizontal,
            vec![
                HiddenPaneEdges {
                    right: true,
                    ..edges
                },
                HiddenPaneEdges {
                    right: true,
                    left: true,
                    ..edges
                },
                HiddenPaneEdges {
                    left: true,
                    ..edges
                },
            ]
        );

        let nested_vertical = horizontal[1].child(Axis::Vertical, 0, 2);
        assert_eq!(
            nested_vertical,
            HiddenPaneEdges {
                right: true,
                bottom: true,
                left: true,
                ..edges
            }
        );
        assert_eq!(
            horizontal[1].child(Axis::Vertical, 1, 2),
            HiddenPaneEdges {
                top: true,
                right: true,
                left: true,
                ..edges
            }
        );
    }

    #[test]
    fn split_resize_preserves_center_and_edge_grab_offsets() {
        let origin = 37.0;
        let extent = 1000.0;
        let child_count = 3;
        let divider_index = 1;
        let available = extent - 2.0 * super::SPLIT_DIVIDER_HITBOX;
        let target_fraction = 0.34;

        for grab_offset in [0.0, 3.5, super::SPLIT_DIVIDER_HITBOX] {
            let pointer = origin
                + target_fraction * available
                + divider_index as f32 * super::SPLIT_DIVIDER_HITBOX
                + grab_offset;
            let fraction = split_resize_fraction(
                pointer,
                origin,
                extent,
                child_count,
                divider_index,
                grab_offset,
            )
            .unwrap();
            assert!((fraction - target_fraction).abs() < 0.0001);

            let moved = split_resize_fraction(
                pointer + 11.0,
                origin,
                extent,
                child_count,
                divider_index,
                grab_offset,
            )
            .unwrap();
            assert!((moved - target_fraction - 11.0 / available).abs() < 0.0001);
            assert_eq!(
                split_resize_fraction(
                    pointer,
                    origin,
                    extent,
                    child_count,
                    divider_index,
                    grab_offset,
                ),
                Some(fraction),
                "a stationary drag position must not accumulate ratio drift"
            );
        }
    }
}
