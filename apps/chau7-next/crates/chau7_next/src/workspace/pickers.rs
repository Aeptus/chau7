//! Pickers: snippets, clipboard history, SSH hosts and command history. The
//! snippet picker has its own sheet (`snippets_ui.rs`); the rest share one
//! filtered list. A new picker adds a `PickerKind`, its items in
//! `all_picker_items`, its texts, and an action in `register_picker_actions`.
//! The command palette is its own window (`palette_window.rs`) with its
//! command list here (`palette.rs`): a new palette command is one line there.

mod extras;
pub(super) mod palette;
mod snippets_ui;

use chau7_next_core::snippet_store::{self, SnippetEntry};
use gpui::{
    App, Context, Div, Entity, ScrollHandle, Stateful, Subscription, Window, div, prelude::*, px,
};
use gpui_kit::component::input::{InputEvent, InputState};

use super::widgets::{chrome_input, modal};
use super::{AppData, Workspace};
use crate::actions::*;
use crate::commands::{MigrateSnippets, ReloadSnippets};
use crate::pane::PaneTree;
use crate::settings::Settings;
use crate::snippets;
use crate::theme::Chrome;

pub(super) fn register_picker_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    let div = div
        .on_action(cx.listener(|this, _: &ShowClipboardHistory, window, cx| {
            this.toggle_picker(PickerKind::Clipboard, window, cx)
        }))
        .on_action(cx.listener(|this, _: &ShowCommandHistory, window, cx| {
            this.toggle_picker(PickerKind::History, window, cx)
        }))
        .on_action(cx.listener(|this, _: &ShowSshHosts, window, cx| {
            this.toggle_picker(PickerKind::Ssh, window, cx)
        }))
        .on_action(cx.listener(|this, _: &ToggleSnippets, window, cx| {
            this.toggle_picker(PickerKind::Snippets, window, cx)
        }))
        .on_action(cx.listener(|_, _: &ToggleCommandPalette, window, cx| {
            super::palette_window::toggle(window, cx)
        }))
        .on_action(cx.listener(|this, _: &ReloadSnippets, _, cx| {
            // Snippets are read from disk each time they are shown; only an open
            // picker has something to refresh.
            this.refilter_picker(cx);
            log::info!("snippets: reloaded");
        }))
        .on_action(cx.listener(|this, _: &MigrateSnippets, _, cx| {
            let root = cx.global::<AppData>().root.clone();
            let settings = Settings::get(cx).productivity.clone();
            let repos = this.snippet_repo_roots(cx);
            let migrated = snippets::migrate_to_clean_json(&root, &settings, &repos);
            log::info!("snippets: migrated to clean JSON: {migrated:?}");
            this.refilter_picker(cx);
        }));
    extras::register(div, cx)
}

#[derive(Clone)]
pub(super) enum PickerItem {
    Snippet(SnippetEntry),
    Clip(chau7_next_core::input::clipboard_history::ClipboardItem),
    Ssh(chau7_next_core::ssh_config::SSHConfigEntry),
    /// A shell hook line (`history.tsv`), shown only while the history
    /// database is unavailable.
    History(chau7_next_core::shell_integration::HistoryEntry),
    /// A command from the history database (HIS-004).
    Record(chau7_next_core::history_record::HistoryRecord),
    /// A command ranked by use (HIS-005).
    Frequent(chau7_next_core::history_record::FrequentCommand),
}

impl PickerItem {
    fn label(&self) -> String {
        match self {
            PickerItem::Snippet(s) => s.snippet.title.clone(),
            PickerItem::Clip(item) => item.preview(),
            PickerItem::Ssh(entry) => entry.display_name(),
            PickerItem::History(entry) => entry.command.clone(),
            PickerItem::Record(record) => record.command.clone(),
            PickerItem::Frequent(f) => f.command.clone(),
        }
    }

    fn detail(&self) -> Option<String> {
        match self {
            PickerItem::Snippet(s) => Some(
                s.snippet
                    .body
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .to_string(),
            ),
            PickerItem::Clip(item) => {
                let age = relative_age(item.age_seconds());
                Some(if item.is_pinned {
                    format!("Pinned, {age}")
                } else {
                    age
                })
            }
            PickerItem::Ssh(entry) => Some(format!(
                "ssh {}{}",
                entry
                    .user
                    .as_ref()
                    .map(|u| format!("{u}@"))
                    .unwrap_or_default(),
                entry.hostname.clone().unwrap_or_else(|| entry.host.clone())
            )),
            PickerItem::History(entry) => Some(entry.directory.clone()),
            PickerItem::Record(record) => Some(record_detail(record)),
            PickerItem::Frequent(f) => Some(format!(
                "{} {} \u{b7} {}",
                f.count,
                if f.count == 1 { "run" } else { "runs" },
                relative_age((chrono::Utc::now() - f.last_used).num_seconds())
            )),
        }
    }

    /// Text the search matches: a clipboard item's whole text, else the label.
    fn search_text(&self) -> String {
        match self {
            PickerItem::Clip(item) => item.text.clone(),
            other => other.label(),
        }
    }
}

/// Exit mark, folder, duration and age of a recorded command
/// (`HistoryRecordRow`).
fn record_detail(record: &chau7_next_core::history_record::HistoryRecord) -> String {
    let mut parts = Vec::new();
    match record.exit_code {
        Some(0) => parts.push("\u{2713}".to_string()),
        Some(code) => parts.push(format!("\u{2717} {code}")),
        None => {}
    }
    if let Some(dir) = record.directory.as_deref().filter(|d| !d.is_empty()) {
        parts.push(dir.to_string());
    }
    if let Some(duration) = record.duration {
        parts.push(crate::history::format_duration(duration));
    }
    parts.push(relative_age(
        (chrono::Utc::now() - record.timestamp).num_seconds(),
    ));
    parts.join(" \u{b7} ")
}

/// "now", "5m ago", "2h ago", "3d ago" (Swift: abbreviated relative date).
fn relative_age(secs: i64) -> String {
    match secs.max(0) {
        0..60 => "now".into(),
        60..3600 => format!("{}m ago", secs / 60),
        3600..86400 => format!("{}h ago", secs / 3600),
        _ => format!("{}d ago", secs / 86400),
    }
}

pub(super) struct PickerState {
    pub(super) kind: PickerKind,
    input: Entity<InputState>,
    items: Vec<PickerItem>,
    selected: usize,
    scroll: ScrollHandle,
    /// Command history: most used first instead of newest first.
    history_frequent: bool,
    /// Command history: only the focused tab's folder (its repository for
    /// the most used list).
    history_folder: bool,
    snip: snippets_ui::SnippetUi,
    _subscription: Subscription,
}

#[derive(Clone, Copy, PartialEq)]
pub(super) enum PickerKind {
    Snippets,
    Clipboard,
    Ssh,
    History,
}

impl Workspace {
    /// Close the open picker (a click outside it, `dismissOverlays`).
    pub(super) fn dismiss_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.picker.take().is_some() {
            self.focus_selected(window, cx);
            cx.notify();
        }
    }

    pub(super) fn toggle_picker(
        &mut self,
        kind: PickerKind,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.picker.as_ref().is_some_and(|p| p.kind == kind) {
            self.picker = None;
            self.focus_selected(window, cx);
            cx.notify();
            return;
        }
        // One panel at a time (find, rename, bookmarks close).
        self.close_other_panels(None, cx);
        let placeholder = match kind {
            PickerKind::Snippets => "Search snippets (or press a-z to quick-select)",
            PickerKind::Clipboard => "Search clipboard history",
            PickerKind::Ssh => "Connect to an SSH host (~/.ssh/config)",
            PickerKind::History => "Search command history",
        };
        let input = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::Change => {
                    this.refilter_picker(cx);
                }
                InputEvent::PressEnter { .. } => this.run_picker(window, cx),
                _ => {}
            },
        );
        input.update(cx, |i, cx| i.focus(window, cx));
        self.picker = Some(PickerState {
            kind,
            input,
            items: Vec::new(),
            selected: 0,
            scroll: ScrollHandle::new(),
            history_frequent: false,
            history_folder: false,
            snip: Default::default(),
            _subscription: subscription,
        });
        self.refilter_picker(cx);
        cx.notify();
    }

    /// The git roots of the open tabs' focused panes (for "Migrate Snippets").
    pub(super) fn snippet_repo_roots(&self, cx: &App) -> Vec<std::path::PathBuf> {
        let mut roots: Vec<std::path::PathBuf> = self
            .entries
            .values()
            .filter_map(|e| e.panes.read(cx).focused_session(cx))
            .filter_map(|s| s.read(cx).git_root.clone())
            .collect();
        roots.sort();
        roots.dedup();
        roots
    }

    pub(super) fn all_picker_items(&self, kind: PickerKind, cx: &App) -> Vec<PickerItem> {
        match kind {
            PickerKind::Snippets => {
                let root = cx.global::<AppData>().root.clone();
                let settings = Settings::get(cx).productivity.clone();
                let repo = self
                    .selected_panes()
                    .and_then(|p| p.read(cx).focused_session(cx))
                    .and_then(|s| s.read(cx).git_root.clone());
                snippets::load_entries(&root, &settings, repo.as_deref())
                    .into_iter()
                    .map(PickerItem::Snippet)
                    .collect()
            }
            PickerKind::Clipboard => cx
                .global::<AppData>()
                .clipboard
                .items
                .iter()
                .cloned()
                .map(PickerItem::Clip)
                .collect(),
            PickerKind::History => crate::history::shell_file::entries(cx)
                .iter()
                .take(500)
                .cloned()
                .map(PickerItem::History)
                .collect(),
            PickerKind::Ssh => {
                let home = cx.global::<AppData>().root.home().to_path_buf();
                std::fs::read_to_string(home.join(".ssh").join("config"))
                    .map(|text| chau7_next_core::ssh_config::parse(&text))
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|e| !e.host.contains('*') && !e.host.contains('?'))
                    .map(PickerItem::Ssh)
                    .collect()
            }
        }
    }

    /// The history picker's rows from the database; `None` while it is not
    /// open (the old shell hook list is shown then).
    fn history_items(&self, cx: &App) -> Option<Vec<PickerItem>> {
        let service = crate::history::service(cx)?;
        let picker = self.picker.as_ref()?;
        let query = picker.input.read(cx).value().trim().to_string();
        let session = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx));
        let (cwd, repo) = session
            .map(|s| {
                let s = s.read(cx);
                (
                    s.cwd.as_ref().map(|p| p.to_string_lossy().to_string()),
                    s.git_root.as_ref().map(|p| p.to_string_lossy().to_string()),
                )
            })
            .unwrap_or_default();
        let lower = query.to_lowercase();
        Some(service.with_store(|store| {
            if picker.history_frequent {
                let list = if picker.history_folder {
                    match repo.as_deref() {
                        Some(root) => store.frequent_commands_for_repo(root, 200),
                        None => store.frequent_commands(200),
                    }
                } else {
                    store.frequent_commands(200)
                };
                list.into_iter()
                    .filter(|f| lower.is_empty() || f.command.to_lowercase().contains(&lower))
                    .map(PickerItem::Frequent)
                    .collect()
            } else {
                let mut list = store.recent_unique(&query, 500);
                if picker.history_folder
                    && let Some(dir) = cwd.as_deref()
                {
                    list.retain(|r| r.directory.as_deref() == Some(dir));
                }
                list.into_iter().map(PickerItem::Record).collect()
            }
        }))
    }

    pub(super) fn refilter_picker(&mut self, cx: &mut Context<Self>) {
        let Some(kind) = self.picker.as_ref().map(|p| p.kind) else {
            return;
        };
        if kind == PickerKind::History
            && let Some(items) = self.history_items(cx)
        {
            if let Some(picker) = self.picker.as_mut() {
                picker.items = items;
                picker.selected = 0;
                picker.scroll.scroll_to_item(0);
            }
            cx.notify();
            return;
        }
        let all = self.all_picker_items(kind, cx);
        let Some(picker) = self.picker.as_mut() else {
            return;
        };
        let query = picker.input.read(cx).value().to_string();
        let lower = query.to_lowercase();
        picker.items = match kind {
            // Title, body, tags and folder; the order (pinned, source, title)
            // comes from the store.
            PickerKind::Snippets => {
                let entries: Vec<SnippetEntry> = all
                    .into_iter()
                    .filter_map(|item| match item {
                        PickerItem::Snippet(e) => Some(e),
                        _ => None,
                    })
                    .collect();
                snippet_store::filter_entries(&entries, &query)
                    .into_iter()
                    .cloned()
                    .map(PickerItem::Snippet)
                    .collect()
            }
            _ => all
                .into_iter()
                .filter(|item| {
                    lower.is_empty()
                        || item.search_text().to_lowercase().contains(&lower)
                        || item
                            .detail()
                            .is_some_and(|d| d.to_lowercase().contains(&lower))
                })
                .collect(),
        };
        picker.selected = 0;
        picker.scroll.scroll_to_item(0);
        cx.notify();
    }

    pub(super) fn run_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .picker
            .as_ref()
            .is_some_and(|p| p.kind == PickerKind::Snippets)
        {
            self.snippet_enter(window, cx);
            return;
        }
        let Some(picker) = self.picker.take() else {
            return;
        };
        let Some(item) = picker.items.get(picker.selected).cloned() else {
            self.focus_selected(window, cx);
            return;
        };
        self.run_picker_item(item, window, cx);
    }

    pub(super) fn run_picker_item(
        &mut self,
        item: PickerItem,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let PickerItem::Snippet(entry) = item {
            self.snippet_attempt_insert(entry, window, cx);
            return;
        }
        self.picker = None;
        match item {
            PickerItem::Snippet(_) => {}
            PickerItem::Clip(item) => {
                // Swift `pasteFromClipboardHistory`: on the clipboard, to the
                // top of the history, then pasted.
                cx.write_to_clipboard(gpui::ClipboardItem::new_string(item.text.clone()));
                super::update_clipboard_history(cx, |h| h.mark_pasted(&item.id));
                if let Some(view) = self
                    .selected_panes()
                    .and_then(|p| p.read(cx).focused_view())
                {
                    view.update(cx, |v, cx| v.paste_text(&item.text, cx));
                }
            }
            PickerItem::History(entry) => {
                // Typed, not run: the user reviews it and presses Enter.
                if let Some(view) = self
                    .selected_panes()
                    .and_then(|p| p.read(cx).focused_view())
                {
                    view.update(cx, |v, cx| v.send_text(&entry.command, cx));
                }
            }
            PickerItem::Record(_) | PickerItem::Frequent(_) => {
                let command = match &item {
                    PickerItem::Record(r) => r.command.clone(),
                    PickerItem::Frequent(f) => f.command.clone(),
                    _ => String::new(),
                };
                // Typed, not run: the user reviews it and presses Enter.
                if let Some(view) = self
                    .selected_panes()
                    .and_then(|p| p.read(cx).focused_view())
                {
                    view.update(cx, |v, cx| v.send_text(&command, cx));
                }
            }
            PickerItem::Ssh(entry) => {
                // A new tab connected to the host.
                let command = format!(
                    "ssh {}\r",
                    chau7_next_core::shell_escaping::escape_argument(&entry.host)
                );
                self.run_in_new_tab(&command, Some(&entry.host), window, cx);
            }
        }
        self.focus_selected(window, cx);
        cx.notify();
    }

    /// Open a tab, type `command` into it and optionally title the tab.
    pub(crate) fn run_in_new_tab(
        &mut self,
        command: &str,
        title: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let id = self.add_tab(None, true, window, cx);
        if let Some(panes) = self.entries.get(&id).map(|e| e.panes.clone()) {
            PaneTree::send_input(&panes, command.as_bytes(), cx);
        }
        if let (Some(title), Some(meta)) = (title, self.state.get_mut(id)) {
            meta.custom_title = Some(title.to_string());
        }
        cx.notify();
    }

    pub(super) fn render_picker(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<gpui::AnyElement> {
        let picker = self.picker.as_ref()?;
        if picker.kind == PickerKind::Snippets {
            return self.render_snippet_picker(chrome, cx);
        }
        let title = match picker.kind {
            PickerKind::Snippets => "Snippets",
            PickerKind::Clipboard => "Clipboard History",
            PickerKind::Ssh => "SSH Hosts",
            PickerKind::History => "Command History",
        };
        let empty = match picker.kind {
            PickerKind::Snippets => "No snippets found.",
            PickerKind::Clipboard => "No clipboard history yet.",
            PickerKind::Ssh => "No hosts found in ~/.ssh/config.",
            PickerKind::History => {
                "No commands yet. Commands are recorded when they finish (shell integration: zsh, bash, fish)."
            }
        };
        let rows: Vec<_> = picker
            .items
            .iter()
            .enumerate()
            .map(|(index, item)| {
                let selected = index == picker.selected;
                let item_clone = item.clone();
                let clip_controls = match item {
                    PickerItem::Clip(clip) => Some(clip_controls(clip, chrome, cx)),
                    _ => None,
                };
                let row = div()
                    .id(("picker-row", index))
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .flex()
                    .items_center()
                    .gap_2()
                    .when(selected, |d| d.bg(chrome.tab_selected_bg))
                    .hover(|d| d.bg(chrome.tab_hover_bg));
                let row = row
                    .flex_col()
                    .items_start()
                    .gap_0()
                    .child(
                        div()
                            .w_full()
                            .flex()
                            .justify_between()
                            .gap_2()
                            .child(div().text_sm().child(item.label()))
                            .children(clip_controls),
                    )
                    .when_some(item.detail(), |d, detail| {
                        d.child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .overflow_hidden()
                                .text_ellipsis()
                                .child(detail),
                        )
                    });
                row.on_click(cx.listener(move |this, _, window, cx| {
                    this.run_picker_item(item_clone.clone(), window, cx);
                }))
            })
            .collect();
        let is_empty = rows.is_empty();
        Some(modal(
            chrome,
            div()
                .key_context("Picker")
                .flex()
                .flex_col()
                .gap_2()
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .child(
                            div()
                                .text_sm()
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .child(title),
                        )
                        .when(picker.kind == PickerKind::History, |d| {
                            d.child(
                                div()
                                    .flex()
                                    .gap_1()
                                    .child(
                                        small_toggle(
                                            "hist-mode",
                                            if picker.history_frequent {
                                                "Most used"
                                            } else {
                                                "Recent"
                                            },
                                            picker.history_frequent,
                                            chrome,
                                        )
                                        .on_click(
                                            cx.listener(|this, _, _, cx| {
                                                if let Some(p) = this.picker.as_mut() {
                                                    p.history_frequent = !p.history_frequent;
                                                }
                                                this.refilter_picker(cx);
                                            }),
                                        ),
                                    )
                                    .child(
                                        small_toggle(
                                            "hist-folder",
                                            "This folder",
                                            picker.history_folder,
                                            chrome,
                                        )
                                        .on_click(
                                            cx.listener(|this, _, _, cx| {
                                                if let Some(p) = this.picker.as_mut() {
                                                    p.history_folder = !p.history_folder;
                                                }
                                                this.refilter_picker(cx);
                                            }),
                                        ),
                                    ),
                            )
                        })
                        .when(picker.kind == PickerKind::Clipboard, |d| {
                            d.child(small_button("clip-clear", "Clear", chrome).on_click(
                                cx.listener(|this, _, _, cx| {
                                    super::update_clipboard_history(cx, |h| h.clear());
                                    this.refilter_picker(cx);
                                }),
                            ))
                        }),
                )
                .child(chrome_input(&picker.input, chrome))
                .child(
                    div()
                        .id("picker-list")
                        .flex()
                        .flex_col()
                        .max_h(px(350.0))
                        .overflow_y_scroll()
                        .track_scroll(&picker.scroll)
                        .children(rows),
                )
                .when(is_empty, |d| {
                    d.child(div().text_xs().text_color(chrome.text_muted).child(empty))
                })
                .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                    let Some(picker) = this.picker.as_mut() else {
                        return;
                    };
                    match event.keystroke.key.as_str() {
                        "down" => {
                            picker.selected =
                                (picker.selected + 1).min(picker.items.len().saturating_sub(1));
                            picker.scroll.scroll_to_item(picker.selected);
                            cx.notify();
                        }
                        "up" => {
                            picker.selected = picker.selected.saturating_sub(1);
                            picker.scroll.scroll_to_item(picker.selected);
                            cx.notify();
                        }
                        "escape" => {
                            this.picker = None;
                            this.focus_selected(window, cx);
                            cx.notify();
                        }
                        _ => {}
                    }
                })),
            cx.listener(|this, _, window, cx| this.dismiss_picker(window, cx)),
        ))
    }
}

/// Pin and Remove buttons of a clipboard history row (KBD-003).
fn clip_controls(
    clip: &chau7_next_core::input::clipboard_history::ClipboardItem,
    chrome: Chrome,
    cx: &mut Context<Workspace>,
) -> gpui::AnyElement {
    let pin_id = clip.id.clone();
    let remove_id = clip.id.clone();
    div()
        .flex()
        .gap_1()
        .child(
            small_button(
                gpui::SharedString::from(format!("pin-{}", clip.id)),
                if clip.is_pinned { "Unpin" } else { "Pin" },
                chrome,
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                super::update_clipboard_history(cx, |h| h.toggle_pin(&pin_id));
                this.refilter_picker(cx);
            })),
        )
        .child(
            small_button(
                gpui::SharedString::from(format!("remove-{}", clip.id)),
                "Remove",
                chrome,
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                super::update_clipboard_history(cx, |h| h.remove(&remove_id));
                this.refilter_picker(cx);
            })),
        )
        .into_any_element()
}

/// A button that stays highlighted while its option is on.
fn small_toggle(
    id: impl Into<gpui::ElementId>,
    label: &'static str,
    on: bool,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    small_button(id, label, chrome).when(on, |d| d.bg(chrome.tab_selected_bg))
}

fn small_button(
    id: impl Into<gpui::ElementId>,
    label: &'static str,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px_1p5()
        .rounded_sm()
        .text_xs()
        .text_color(chrome.text_muted)
        .bg(chrome.tab_bg)
        .hover(|d| d.bg(chrome.tab_hover_bg))
        .child(label)
}
