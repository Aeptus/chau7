//! Split panes inside a tab (mirrors `SplitPanes/SplitPaneController.swift`):
//! a tree of panes split horizontally or vertically, with one focused pane,
//! resizable dividers, and focus cycling. A pane is a terminal, a text
//! editor, a file preview or a diff viewer ([`PaneItem`]; the side panes
//! live in `crate::panes`).

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use chau7_next_core::editor::diff::DiffMode;
use chau7_next_core::session_restore::{
    SavedAxis, SavedSplitNode, build_ai_resume_command, normalized_resume_command,
    resolve_resume_metadata_from_saved, restore_input,
};
use gpui::{
    AnyElement, App, Axis, Context, DragMoveEvent, Entity, EntityId, EventEmitter, FocusHandle,
    Focusable, Render, Subscription, Window, div, prelude::*, px, relative,
};

use crate::actions::{ScrollToBottom, ScrollToTop};
use crate::panes::{DiffPane, EditorPane, PreviewPane, SidePaneEvent};
use crate::restore;
use crate::session_store::{SavedPane, SavedTab};
use crate::settings::Settings;
use crate::terminal::session::{SessionEvent, TerminalSession};
use crate::terminal::view::{TerminalView, TerminalViewEvent};
use crate::theme::Chrome;
use crate::workspace::AppData;

/// Identifies a pane across launches (`SplitPaneController` pane UUIDs).
/// Random, so it can also name a terminal pane's scrollback file.
pub type PaneId = u64;

/// Directory of a pane's shell right now (the session's own value is only
/// refreshed when output arrives).
pub fn live_cwd(session: &TerminalSession) -> Option<PathBuf> {
    crate::platform::process::process_cwd(session.shell_pid() as u32)
        .or_else(|| session.cwd.clone())
}

fn new_pane_id() -> PaneId {
    (uuid::Uuid::new_v4().as_u128() as u64 & 0x0000_ffff_ffff_ffff) | 1
}

/// Pane events for the workspace.
/// Size a terminal starts at before the layout gives it its own.
const DEFAULT_SIZE: (u16, u16) = (80, 24);

#[derive(Debug, Clone)]
pub enum PaneEvent {
    /// Every pane closed: the tab should close.
    Empty,
    /// Output arrived in some pane.
    Activity,
    /// Title/directory/git/AI info changed in the focused pane.
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
    /// A command of some pane changed these files.
    ChangedFiles(Vec<String>),
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
}

impl PaneItem {
    pub fn entity_id(&self) -> EntityId {
        match self {
            PaneItem::Terminal(e) => e.entity_id(),
            PaneItem::Editor(e) => e.entity_id(),
            PaneItem::Preview(e) => e.entity_id(),
            PaneItem::Diff(e) => e.entity_id(),
        }
    }

    pub fn focus_handle(&self, cx: &App) -> FocusHandle {
        match self {
            PaneItem::Terminal(e) => e.read(cx).focus_handle(cx),
            PaneItem::Editor(e) => e.read(cx).focus_handle(cx),
            PaneItem::Preview(e) => e.read(cx).focus_handle(cx),
            PaneItem::Diff(e) => e.read(cx).focus_handle(cx),
        }
    }

    fn element(&self) -> AnyElement {
        match self {
            PaneItem::Terminal(e) => e.clone().into_any_element(),
            PaneItem::Editor(e) => e.clone().into_any_element(),
            PaneItem::Preview(e) => e.clone().into_any_element(),
            PaneItem::Diff(e) => e.clone().into_any_element(),
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
}

struct DividerGhost;
impl Render for DividerGhost {
    fn render(&mut self, _w: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
    }
}

pub struct PaneTree {
    root: Option<Node<PaneItem>>,
    focused: Option<EntityId>,
    next_split_id: u64,
    subscriptions: Vec<(EntityId, Vec<Subscription>)>,
    pane_ids: HashMap<EntityId, PaneId>,
    /// Panes restored from a saved session whose scrollback has not been
    /// replayed yet. Until then the saved state is what gets saved again.
    pending_restore: HashMap<PaneId, SavedPane>,
    /// AI session a restored pane was running, kept for the life of the pane
    /// so that it is saved again (`restoreAIMetadata`).
    resume_meta: HashMap<PaneId, (String, String)>,
}

impl EventEmitter<PaneEvent> for PaneTree {}

impl PaneTree {
    fn empty() -> Self {
        Self {
            root: None,
            focused: None,
            next_split_id: 1,
            subscriptions: Vec::new(),
            pane_ids: HashMap::new(),
            pending_restore: HashMap::new(),
            resume_meta: HashMap::new(),
        }
    }

    pub fn new(cwd: Option<PathBuf>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut this = Self::empty();
        let view = this.create_terminal(cwd, new_pane_id(), DEFAULT_SIZE, window, cx);
        this.focused = Some(view.entity_id());
        this.root = Some(Node::Leaf(PaneItem::Terminal(view)));
        this
    }

    /// The panes of a tab: restored from its saved split layout when it has
    /// one (`buildRestorableController`), else one shell in `cwd`.
    pub fn from_saved(
        saved: Option<&SavedTab>,
        cwd: Option<PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let layout = saved
            .and_then(|s| s.layout.clone())
            .and_then(SavedSplitNode::normalized);
        let (Some(saved), Some(layout)) = (saved, layout) else {
            return Self::new(cwd, window, cx);
        };
        let mut this = Self::empty();
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
        this.start_restore(cx);
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
                    .map(PathBuf::from);
                Node::Leaf(PaneItem::Terminal(self.create_terminal(
                    dir,
                    *id,
                    DEFAULT_SIZE,
                    window,
                    cx,
                )))
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
            match TerminalSession::spawn(cols, rows, cwd.clone(), &settings, &root, cx) {
                Ok(session) => session,
                Err(err) => {
                    log::error!("{err}");
                    let headless = chau7_terminal::Chau7Terminal::new_headless(80, 24)
                        .expect("headless terminal");
                    headless.inject_output(
                        format!("Chau7 Next could not start a shell: {err}\r\n").as_bytes(),
                    );
                    TerminalSession::from_terminal(headless, cwd, cx)
                }
            }
        });
        let view = cx.new(|cx| TerminalView::new(session.clone(), window, cx));
        let view_id = view.entity_id();
        self.pane_ids.insert(view_id, pane_id);
        let subs = vec![
            cx.subscribe(&session, move |this, _, event, cx| match event {
                SessionEvent::Output => cx.emit(PaneEvent::Activity),
                SessionEvent::MetadataChanged => {
                    if this.focused == Some(view_id) {
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
                        this.remove(view_id, cx);
                    } else {
                        cx.notify();
                    }
                }
                SessionEvent::CommandFinished(code) => cx.emit(PaneEvent::CommandFinished(*code)),
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
                SessionEvent::ChangedFiles(files) => {
                    cx.emit(PaneEvent::ChangedFiles(files.clone()))
                }
                SessionEvent::PermissionResolved => cx.emit(PaneEvent::PermissionResolved),
                SessionEvent::ClipboardStore(_)
                | SessionEvent::ClipboardLoad
                | SessionEvent::DirectoryChanged(_)
                | SessionEvent::WaitingInput { .. } => {}
            }),
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
                    self.focus_own(window, cx);
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

    /// Panes of every kind (`allPaneIDs.count`).
    pub fn pane_count(&self) -> usize {
        self.leaves().len()
    }

    /// Focus the focused pane of `panes`.
    pub fn focus_entity(panes: &Entity<PaneTree>, window: &mut Window, cx: &mut App) {
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

    /// `appendSelectionToEditor`: needs an open editor pane.
    pub fn append_to_editor(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        match self.first_editor() {
            Some(editor) => editor.update(cx, |e, cx| e.append_text(text, window, cx)),
            None => log::warn!("No text editor pane open to append to"),
        }
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
                        this.remove(id, cx);
                        this.focus_own(window, cx);
                    });
                }
            })
            .detach();
            return;
        }
        self.remove(id, cx);
        self.focus_own(window, cx);
    }

    fn remove(&mut self, id: EntityId, cx: &mut Context<Self>) {
        let sibling = self.root.as_ref().and_then(|root| sibling_focus(root, id));
        if let Some(root) = self.root.take() {
            self.root = remove_leaf(root, id);
        }
        self.subscriptions.retain(|(view, _)| *view != id);
        if let Some(pane) = self.pane_ids.remove(&id) {
            self.pending_restore.remove(&pane);
            self.resume_meta.remove(&pane);
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

    /// Id of the focused pane, whatever its kind (`focusedPaneID`).
    pub fn focused_pane_id(&self) -> Option<PaneId> {
        self.focused_item()
            .and_then(|item| self.pane_ids.get(&item.entity_id()).copied())
    }

    /// The split layout, for saving (`exportLayout`).
    pub fn export_layout(&self, cx: &App) -> Option<SavedSplitNode> {
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

    /// AI session a restored pane was running.
    pub fn resume_meta(&self, pane: PaneId) -> Option<(String, String)> {
        self.resume_meta.get(&pane).cloned()
    }

    // ----- restore ------------------------------------------------------

    /// Replay the saved scrollback into every restored pane after
    /// `restoreDelaySeconds` (0.8 s), then type the AI resume command into
    /// the focused pane once its prompt is ready, retrying up to 16 times
    /// (`restoreTabState`, `scheduleResumeCommand`).
    fn start_restore(&mut self, cx: &mut Context<Self>) {
        if self.pending_restore.is_empty() {
            return;
        }
        let token = format!("{:x}", new_pane_id());
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(800))
                .await;
            let Ok(target) = this.update(cx, |this, cx| this.replay_pending(&token, cx)) else {
                return;
            };
            let Some((pane, command)) = target else {
                return;
            };
            let mut delay = Duration::from_millis(600);
            for _ in 0..16 {
                cx.background_executor().timer(delay).await;
                match this.update(cx, |this, cx| this.resume_ready(pane, cx)) {
                    Ok(Some(true)) => break,
                    Ok(Some(false)) => {
                        delay = (delay + Duration::from_millis(500)).min(Duration::from_secs(4));
                    }
                    // The pane or the tab is gone.
                    Ok(None) | Err(_) => return,
                }
            }
            // Ready, or retries exhausted: type it anyway, as Swift queues it.
            let _ = this.update(cx, |this, cx| this.prefill(pane, &command, cx));
        })
        .detach();
    }

    /// Type the restore line into each pending pane. Returns the resume
    /// command of the focused pane, if it was running an AI session.
    fn replay_pending(&mut self, token: &str, cx: &mut Context<Self>) -> Option<(PaneId, String)> {
        let root = cx.global::<crate::workspace::AppData>().root.clone();
        let focused = self.focused_pane_id();
        let mut target = None;
        for (pane, session) in self.pane_sessions(cx) {
            let Some(saved) = self.pending_restore.remove(&pane) else {
                continue;
            };
            let file = saved
                .scrollback
                .then(|| restore::replay_copy(&root, pane, token))
                .flatten();
            if let Some(line) = restore_input(file.as_deref(), saved.directory.as_deref()) {
                session.update(cx, |s, _| s.write_restore_line(&line));
            }
            let meta = resolve_resume_metadata_from_saved(
                saved.ai_provider.as_deref(),
                saved.ai_session_id.as_deref(),
                saved.ai_resume_command.as_deref(),
            );
            let command = build_ai_resume_command(
                meta.as_ref().map(|m| m.provider.as_str()),
                meta.as_ref().map(|m| m.session_id.as_str()),
            )
            .or_else(|| normalized_resume_command(saved.ai_resume_command.as_deref()));
            // Every restored pane keeps its AI session (`restoreAIMetadata`), so
            // it is saved again; only the focused pane gets the command typed.
            if let Some(meta) = meta {
                // The session knows its AI tool again (tab color, detection).
                session.update(cx, |s, cx| {
                    s.restore_ai_metadata(Some(&meta.provider), Some(&meta.session_id), cx)
                });
                self.resume_meta
                    .insert(pane, (meta.provider, meta.session_id));
                if let Some(command) = command
                    && Some(pane) == focused
                {
                    target = Some((pane, command));
                }
            }
        }
        target
    }

    /// `Some(true)` when the pane's shell shows a prompt, `Some(false)` when
    /// not yet, `None` when the pane no longer exists.
    fn resume_ready(&self, pane: PaneId, cx: &App) -> Option<bool> {
        let (_, session) = self
            .pane_sessions(cx)
            .into_iter()
            .find(|(id, _)| *id == pane)?;
        let session = session.read(cx);
        Some(session.is_at_prompt() && !session.is_loading() && session.exited.is_none())
    }

    fn prefill(&mut self, pane: PaneId, command: &str, cx: &mut Context<Self>) {
        if let Some((_, session)) = self
            .pane_sessions(cx)
            .into_iter()
            .find(|(id, _)| *id == pane)
        {
            // Typed at the prompt, not run (`prefillInput`; the session waits
            // for its prompt again if the shell is still busy).
            let command = command.to_string();
            session.update(cx, |s, cx| s.prefill_input(command, cx));
        }
    }

    /// Directory of the focused pane (for new tabs, restore).
    pub fn cwd(&self, cx: &App) -> Option<PathBuf> {
        self.focused_session(cx)
            .and_then(|s| s.read(cx).cwd.clone())
    }

    /// Whether any pane has a command running (close confirmation).
    /// Processes still running under the shells of this tab
    /// (`countRunningProcesses` in Swift).
    pub fn running_process_count(&self, cx: &App) -> usize {
        self.views()
            .iter()
            .map(|v| {
                let session = v.read(cx).session.read(cx);
                if session.exited.is_some() {
                    0
                } else {
                    crate::platform::process::child_process_count(session.shell_pid() as u32)
                }
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
            for child in crate::platform::process::child_pids(session.shell_pid() as u32) {
                if let Some(name) = crate::platform::process::process_name(child) {
                    names.push(name);
                }
            }
        }
        names
    }

    /// Send input to the focused pane of `panes` without re-broadcasting it.
    pub fn send_input(panes: &Entity<PaneTree>, bytes: &[u8], cx: &mut App) {
        if let Some(view) = panes.read(cx).focused_view() {
            view.update(cx, |v, cx| v.write_without_broadcast(bytes, cx));
        }
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
        view.update(cx, |v, cx| v.write_without_broadcast(&encoded.bytes, cx));
        true
    }

    pub fn set_font_size(&mut self, size: f32, cx: &mut Context<Self>) {
        for view in self.views() {
            view.update(cx, |v, cx| v.set_font_size(size, cx));
        }
    }

    pub fn reload_settings(&mut self, cx: &mut Context<Self>) {
        let settings = Settings::get(cx).clone();
        for item in self.leaves() {
            match item {
                PaneItem::Terminal(view) => view.update(cx, |v, cx| {
                    v.session
                        .update(cx, |session, _| session.apply_settings(&settings));
                    v.set_font_size(settings.appearance.zoomed_font_size(), cx);
                }),
                PaneItem::Editor(editor) => editor.update(cx, |e, cx| e.settings_changed(cx)),
                PaneItem::Preview(preview) => preview.update(cx, |p, cx| p.apply_settings(cx)),
                PaneItem::Diff(diff) => diff.update(cx, |d, cx| d.apply_settings(cx)),
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
                div()
                    .size_full()
                    .relative()
                    .when(show_focus, |d| {
                        d.border_1().border_color(if focused {
                            chrome.accent.opacity(0.6)
                        } else {
                            chrome.border.opacity(0.0)
                        })
                    })
                    .child(item.element())
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
                        let fraction = match axis {
                            Axis::Horizontal => {
                                (event.event.position.x - bounds.left()) / bounds.size.width
                            }
                            Axis::Vertical => {
                                (event.event.position.y - bounds.top()) / bounds.size.height
                            }
                        };
                        this.set_ratio(split_id, drag.index, fraction);
                        cx.notify();
                    },
                ));
                for (index, child) in children.iter().enumerate() {
                    let ratio = ratios.get(index).copied().unwrap_or(1.0);
                    let element = self.render_node(child, show_focus, chrome, cx);
                    let mut cell = div().flex_shrink_0().overflow_hidden();
                    cell = match axis {
                        Axis::Horizontal => cell.h_full().w(relative(ratio)),
                        Axis::Vertical => cell.w_full().h(relative(ratio)),
                    };
                    container = container.child(cell.child(element));
                    if index + 1 < children.len() {
                        let divider = div()
                            .id(("divider", (split_id as usize) << 8 | index))
                            .flex_shrink_0()
                            .bg(chrome.border)
                            .hover(|d| d.bg(chrome.accent.opacity(0.7)))
                            .on_drag(DividerDrag { split_id, index }, |_, _, _, cx| {
                                cx.new(|_| DividerGhost)
                            });
                        let divider = match axis {
                            Axis::Horizontal => divider.w(px(3.0)).h_full().cursor_col_resize(),
                            Axis::Vertical => divider.h(px(3.0)).w_full().cursor_row_resize(),
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
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::get(cx);
        let show_focus = self.pane_count() > 1;
        let content = match &self.root {
            Some(_) => {
                // Render needs &self while the listener needs cx; take the tree briefly.
                let root = self.root.take();
                let element = self.render_node(root.as_ref().unwrap(), show_focus, chrome, cx);
                self.root = root;
                element
            }
            None => div().into_any_element(),
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

#[cfg(test)]
mod tests {
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
