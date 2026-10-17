//! "Manage Snippets..." window (`SnippetsSettingsView.swift`): sources and
//! search on the left, details or the editor on the right, the switches in the
//! footer, and the import/export sheet.

use std::path::PathBuf;
use std::time::Duration;

use chau7_next_core::snippet_store::{self, Snippet, SnippetEntry, SnippetSource};
use gpui::{
    AnyElement, AnyWindowHandle, App, Bounds, ClipboardItem, Context, Entity, Global,
    PathPromptOptions, Render, SharedString, Window, WindowBounds, WindowOptions, div, prelude::*,
    px, size,
};
use gpui_kit::component::TitleBar;
use gpui_kit::component::input::{Input, InputEvent, InputState, Textarea, TextareaState};

use super::form::SnippetForm;
use crate::settings::Settings;
use crate::settings_window;
use crate::theme::Chrome;
use crate::workspace::{AppData, Workspace};

/// The open manager window, if any (only one at a time).
#[derive(Default)]
struct ManagerWindow(Option<AnyWindowHandle>);
impl Global for ManagerWindow {}

pub fn open(cx: &mut App) {
    if let Some(handle) = cx.try_global::<ManagerWindow>().and_then(|h| h.0)
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        return;
    }
    let bounds = Bounds::centered(None, size(px(860.0), px(620.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(700.0), px(500.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        cx.new(|cx| SnippetsManager::new(window, cx))
    }) {
        Ok((handle, _)) => cx.set_global(ManagerWindow(Some(handle))),
        Err(err) => log::error!("snippets window: {err}"),
    }
}

/// The workspace in front: the focused terminal's window.
pub fn frontmost_workspace(cx: &App) -> Option<Entity<Workspace>> {
    let live = AppData::live(cx);
    for handle in cx.window_stack().unwrap_or_default() {
        if let Some((_, ws)) = live.iter().find(|(h, _)| *h == handle) {
            return Some(ws.clone());
        }
    }
    live.into_iter().next().map(|(_, ws)| ws)
}

enum Panel {
    /// Details of the selected snippet, or the "select one" hint.
    Detail,
    Editor {
        form: Box<SnippetForm>,
        error: Option<String>,
    },
    ConfirmDelete(Box<SnippetEntry>),
    Sheet(Box<Sheet>),
}

/// The import/export sheet.
struct Sheet {
    import: bool,
    source: SnippetSource,
    import_text: Entity<TextareaState>,
    export_text: Entity<TextareaState>,
    status: Option<(String, bool)>,
}

pub struct SnippetsManager {
    /// `None` is "All".
    filter: Option<SnippetSource>,
    search: Entity<InputState>,
    entries: Vec<SnippetEntry>,
    repo: Option<PathBuf>,
    selected: Option<String>,
    panel: Panel,
    /// Shown in the detail panel (for example an invalid repository).
    notice: Option<String>,
    /// The snippet waiting for the folder chooser of "Copy to Repo...".
    pending_copy: Option<SnippetEntry>,
    _subscription: gpui::Subscription,
    _reload: gpui::Task<()>,
}

impl SnippetsManager {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::l10n::tr("Search snippets..."))
        });
        let subscription = cx.subscribe(&search, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        });
        // Pick up edits made on disk and a change of the active repository.
        let reload = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(1000))
                    .await;
                if this.update(cx, |this, cx| this.reload(cx)).is_err() {
                    break;
                }
            }
        });
        let mut manager = Self {
            filter: Some(SnippetSource::Global),
            search,
            entries: Vec::new(),
            repo: None,
            selected: None,
            panel: Panel::Detail,
            notice: None,
            pending_copy: None,
            _subscription: subscription,
            _reload: reload,
        };
        manager.reload(cx);
        manager
    }

    /// Re-read every source; only repaint when something changed.
    fn reload(&mut self, cx: &mut Context<Self>) {
        let git_root = frontmost_workspace(cx).and_then(|ws| ws.read(cx).active_git_root(cx));
        let root = cx.global::<AppData>().root.clone();
        let settings = Settings::get(cx).productivity.clone();
        let repo = super::active_repo(&settings, git_root.as_deref());
        let entries = super::load_entries(&root, &settings, git_root.as_deref());
        if entries != self.entries || repo != self.repo {
            self.entries = entries;
            self.repo = repo;
            cx.notify();
        }
    }

    fn shown(&self, cx: &App) -> Vec<&SnippetEntry> {
        let query = self.search.read(cx).value().to_lowercase();
        self.entries
            .iter()
            .filter(|e| self.filter.is_none_or(|f| e.source == f))
            .filter(|e| {
                query.is_empty()
                    || e.snippet.title.to_lowercase().contains(&query)
                    || e.snippet.body.to_lowercase().contains(&query)
                    || e.snippet
                        .tags
                        .iter()
                        .any(|t| t.to_lowercase().contains(&query))
            })
            .collect()
    }

    fn selected_entry(&self) -> Option<&SnippetEntry> {
        let id = self.selected.as_ref()?;
        self.entries.iter().find(|e| &e.entry_id() == id)
    }

    fn settings(&self, cx: &App) -> crate::settings::ProductivitySettings {
        Settings::get(cx).productivity.clone()
    }

    fn default_repo(&self, cx: &App) -> Option<PathBuf> {
        self.repo
            .clone()
            .or_else(|| recent_repos(cx).first().map(PathBuf::from))
    }

    fn new_snippet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let source = self.filter.unwrap_or(SnippetSource::Global);
        let repo = (source == SnippetSource::Repo)
            .then(|| self.default_repo(cx))
            .flatten();
        let form = SnippetForm::new(None, source, repo, window, cx);
        form.focus_title(window, cx);
        self.panel = Panel::Editor {
            form: Box::new(form),
            error: None,
        };
        cx.notify();
    }

    fn edit_snippet(&mut self, entry: SnippetEntry, window: &mut Window, cx: &mut Context<Self>) {
        let repo = (entry.source == SnippetSource::Repo)
            .then(|| entry.repo_root.clone().or_else(|| self.default_repo(cx)))
            .flatten();
        let form = SnippetForm::new(Some(&entry), entry.source, repo, window, cx);
        form.focus_title(window, cx);
        self.panel = Panel::Editor {
            form: Box::new(form),
            error: None,
        };
        cx.notify();
    }

    fn save(&mut self, cx: &mut Context<Self>) {
        let Panel::Editor { form, .. } = &self.panel else {
            return;
        };
        if !form.can_save(cx, true) {
            return;
        }
        let draft = form.draft(cx);
        let editing = form.editing.clone();
        let root = cx.global::<AppData>().root.clone();
        let settings = self.settings(cx);
        let result = super::save_draft(
            &root,
            &settings,
            editing.as_ref(),
            &draft,
            self.repo.as_deref(),
        );
        match result {
            Ok(()) => {
                if draft.source == SnippetSource::Repo {
                    let path = draft.repo_path.clone();
                    settings_window::record_recent_repo(&path, cx);
                }
                self.panel = Panel::Detail;
                self.reload(cx);
                // Keep the saved snippet selected (its id may be new).
                let id = if draft.id.is_empty() {
                    editing.map(|e| e.snippet.id)
                } else {
                    Some(draft.id)
                };
                if let Some(id) = id {
                    self.selected = self
                        .entries
                        .iter()
                        .find(|e| e.snippet.id == id)
                        .map(|e| e.entry_id());
                }
            }
            Err(message) => {
                if let Panel::Editor { error, .. } = &mut self.panel {
                    *error = Some(message);
                }
            }
        }
        cx.notify();
    }

    fn copy_to(
        &mut self,
        entry: &SnippetEntry,
        target: SnippetSource,
        repo: Option<PathBuf>,
        cx: &mut Context<Self>,
    ) {
        let root = cx.global::<AppData>().root.clone();
        let settings = self.settings(cx);
        let paths = super::paths(&root, &settings);
        match snippet_store::duplicate_snippet(
            &paths,
            entry,
            target,
            repo.as_deref(),
            snippet_store::now_utc(),
        ) {
            Ok(_) => {
                if let Some(repo) = repo {
                    let path = repo.to_string_lossy().to_string();
                    settings_window::record_recent_repo(&path, cx);
                }
                self.notice = None;
                self.reload(cx);
            }
            Err(err) => self.notice = Some(format!("Copy failed: {err}")),
        }
        cx.notify();
    }

    /// Ask for a folder; it must be (inside) a git repository.
    fn pick_repo(
        &mut self,
        then: fn(&mut Self, PathBuf, &mut Window, &mut Context<Self>),
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let rx = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Choose a git repository".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = rx.await else {
                return;
            };
            let Some(folder) = paths.into_iter().next() else {
                return;
            };
            this.update_in(
                cx,
                |this, window, cx| match crate::platform::process::git_root(&folder) {
                    Some(root) => then(this, root, window, cx),
                    None => {
                        this.notice = Some("That folder is not a git repository.".to_string());
                        if let Panel::Editor { error, .. } = &mut this.panel {
                            *error = this.notice.clone();
                        }
                        cx.notify();
                    }
                },
            )
            .ok();
        })
        .detach();
    }

    fn open_sheet(&mut self, import: bool, window: &mut Window, cx: &mut Context<Self>) {
        let import_text = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(14)
                .placeholder(crate::l10n::tr("Paste JSON snippet data here"))
        });
        let export_text = cx.new(|cx| TextareaState::new(window, cx).rows(14));
        self.panel = Panel::Sheet(Box::new(Sheet {
            import,
            source: SnippetSource::Global,
            import_text,
            export_text,
            status: None,
        }));
        if !import {
            self.refresh_export(window, cx);
        }
        cx.notify();
    }

    /// Fill the export box with the chosen source's snippets.
    fn refresh_export(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Panel::Sheet(sheet) = &self.panel else {
            return;
        };
        let snippets: Vec<Snippet> = self
            .entries
            .iter()
            .filter(|e| e.source == sheet.source)
            .map(|e| e.snippet.clone())
            .collect();
        let json = snippet_store::export_json(&snippets);
        sheet
            .export_text
            .update(cx, |state, cx| state.set_value(json, window, cx));
    }

    fn set_status(&mut self, message: impl Into<String>, is_error: bool, cx: &mut Context<Self>) {
        if let Panel::Sheet(sheet) = &mut self.panel {
            sheet.status = Some((message.into(), is_error));
        }
        cx.notify();
    }

    fn perform_import(&mut self, cx: &mut Context<Self>) {
        let Panel::Sheet(sheet) = &self.panel else {
            return;
        };
        let text = sheet.import_text.read(cx).value().to_string();
        let root = cx.global::<AppData>().root.clone();
        let settings = self.settings(cx);
        let paths = super::paths(&root, &settings);
        match snippet_store::import_snippets(&paths, &text, sheet.source, snippet_store::now_utc())
        {
            Ok(count) => {
                self.reload(cx);
                self.set_status(
                    crate::l10n::count("snippets.import.success", "Imported %d snippets!", count),
                    false,
                    cx,
                );
            }
            Err(err) => self.set_status(format!("Error: {err}"), true, cx),
        }
    }

    fn load_import_file(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let rx = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: None,
        });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = rx.await else {
                return;
            };
            let Some(file) = paths.into_iter().next() else {
                return;
            };
            let text = std::fs::read_to_string(&file);
            this.update_in(cx, |this, window, cx| match text {
                Ok(text) => {
                    if let Panel::Sheet(sheet) = &this.panel {
                        sheet
                            .import_text
                            .update(cx, |state, cx| state.set_value(text, window, cx));
                    }
                    this.set_status("File loaded", false, cx);
                }
                Err(err) => this.set_status(format!("Error: {err}"), true, cx),
            })
            .ok();
        })
        .detach();
    }

    fn save_export_file(&mut self, cx: &mut Context<Self>) {
        let Panel::Sheet(sheet) = &self.panel else {
            return;
        };
        let text = sheet.export_text.read(cx).value().to_string();
        let name = format!(
            "{}-snippets.json",
            sheet.source.display_name().to_lowercase()
        );
        let dir = cx.global::<AppData>().root.home().to_path_buf();
        let rx = cx.prompt_for_new_path(&dir, Some(&name));
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(path))) = rx.await else {
                return;
            };
            let result = std::fs::write(&path, text);
            this.update(cx, |this, cx| match result {
                Ok(()) => this.set_status("Saved!", false, cx),
                Err(err) => this.set_status(format!("Error: {err}"), true, cx),
            })
            .ok();
        })
        .detach();
    }

    fn insert_selected(&mut self, cx: &mut Context<Self>) {
        let Some(entry) = self.selected_entry().cloned() else {
            return;
        };
        if let Some(ws) = frontmost_workspace(cx) {
            ws.update(cx, |ws, cx| {
                ws.insert_snippet_text(&entry.snippet.body, None, cx)
            });
        }
    }
}

fn pill(label: impl Into<SharedString>, color: gpui::Hsla) -> gpui::Div {
    div()
        .px_1p5()
        .py_0p5()
        .rounded(px(4.0))
        .bg(color.opacity(0.18))
        .text_color(color)
        .text_size(px(10.0))
        .font_weight(gpui::FontWeight::BOLD)
        .child(label.into())
}

fn orange() -> gpui::Hsla {
    gpui::hsla(0.08, 0.9, 0.5, 1.0)
}

impl SnippetsManager {
    fn text_button(
        &self,
        id: impl Into<gpui::ElementId>,
        label: impl Into<SharedString>,
        primary: bool,
        chrome: Chrome,
    ) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .px_3()
            .py_1()
            .rounded_md()
            .text_sm()
            .border_1()
            .border_color(chrome.border)
            .bg(if primary {
                chrome.accent
            } else {
                chrome.tab_bg
            })
            .text_color(if primary { gpui::white() } else { chrome.text })
            .hover(|d| d.opacity(0.85))
            .child(label.into())
    }

    fn filter_button(
        &self,
        id: &'static str,
        label: &'static str,
        source: Option<SnippetSource>,
        count: usize,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> gpui::Stateful<gpui::Div> {
        let selected = self.filter == source;
        div()
            .id(id)
            .flex()
            .items_center()
            .gap_1()
            .px_2()
            .py_1()
            .rounded_md()
            .text_xs()
            .bg(if selected {
                chrome.accent
            } else {
                gpui::transparent_black()
            })
            .text_color(if selected { gpui::white() } else { chrome.text })
            .hover(|d| {
                d.bg(if selected {
                    chrome.accent
                } else {
                    chrome.tab_hover_bg
                })
            })
            .child(label)
            .child(
                div()
                    .px_1()
                    .rounded(px(4.0))
                    .text_size(px(10.0))
                    .bg(if selected {
                        gpui::white().opacity(0.2)
                    } else {
                        chrome.border.opacity(0.5)
                    })
                    .child(count.to_string()),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.filter = source;
                cx.notify();
            }))
    }

    fn render_header(&self, chrome: Chrome, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .items_center()
            .justify_between()
            .p_3()
            .border_b_1()
            .border_color(chrome.border)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .text_base()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(crate::l10n::tr("Snippets")),
                    )
                    .child(div().text_xs().text_color(chrome.text_muted).child(
                        "Manage reusable text snippets. Open the snippet picker with its shortcut.",
                    )),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        self.text_button("mgr-import", "Import", false, chrome)
                            .on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.open_sheet(true, window, cx)
                                }),
                            ),
                    )
                    .child(
                        self.text_button("mgr-export", "Export", false, chrome)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.open_sheet(false, window, cx)
                            })),
                    )
                    .child(
                        self.text_button("mgr-new", "New Snippet", true, chrome)
                            .on_click(
                                cx.listener(|this, _, window, cx| this.new_snippet(window, cx)),
                            ),
                    ),
            )
    }

    fn render_sidebar(&self, chrome: Chrome, cx: &mut Context<Self>) -> impl IntoElement {
        let count =
            |source: SnippetSource| self.entries.iter().filter(|e| e.source == source).count();
        let shown = self.shown(cx);
        let empty_search = self.search.read(cx).value().is_empty();
        let rows: Vec<AnyElement> = shown
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                let selected = self.selected.as_deref() == Some(entry.entry_id().as_str());
                let id = entry.entry_id();
                div()
                    .id(("mgr-row", index))
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .py_1p5()
                    .rounded_md()
                    .when(selected, |d| d.bg(chrome.accent).text_color(gpui::white()))
                    .hover(|d| {
                        if selected {
                            d
                        } else {
                            d.bg(chrome.tab_hover_bg)
                        }
                    })
                    .child(
                        div()
                            .w(px(34.0))
                            .text_size(px(9.0))
                            .text_color(if selected {
                                gpui::white().opacity(0.8)
                            } else {
                                chrome.text_muted
                            })
                            .child(entry.source.display_name().to_uppercase()),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(gpui::FontWeight::MEDIUM)
                                    .overflow_hidden()
                                    .text_ellipsis()
                                    .whitespace_nowrap()
                                    .child(entry.snippet.title.clone()),
                            )
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .font_family("Menlo")
                                    .text_color(if selected {
                                        gpui::white().opacity(0.7)
                                    } else {
                                        chrome.text_muted
                                    })
                                    .overflow_hidden()
                                    .text_ellipsis()
                                    .whitespace_nowrap()
                                    .child(entry.snippet.body.replace('\n', " ")),
                            ),
                    )
                    .when(entry.is_overridden, |d| {
                        d.child(pill("OVERRIDDEN", orange()))
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected = Some(id.clone());
                        this.panel = Panel::Detail;
                        this.notice = None;
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        let empty = rows.is_empty();
        div()
            .w(px(280.0))
            .flex()
            .flex_col()
            .border_r_1()
            .border_color(chrome.border)
            .child(
                div()
                    .flex()
                    .gap_1()
                    .px_3()
                    .py_2()
                    .child(self.filter_button(
                        "mgr-f-all",
                        "All",
                        None,
                        self.entries.len(),
                        chrome,
                        cx,
                    ))
                    .child(self.filter_button(
                        "mgr-f-user",
                        "User",
                        Some(SnippetSource::Global),
                        count(SnippetSource::Global),
                        chrome,
                        cx,
                    ))
                    .when(self.repo.is_some(), |d| {
                        d.child(self.filter_button(
                            "mgr-f-repo",
                            "Repo",
                            Some(SnippetSource::Repo),
                            count(SnippetSource::Repo),
                            chrome,
                            cx,
                        ))
                    }),
            )
            .child(div().px_3().pb_2().child(Input::new(&self.search)))
            .child(
                div()
                    .id("mgr-list")
                    .flex_1()
                    .overflow_y_scroll()
                    .p_2()
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .children(rows)
                    .when(empty, |d| {
                        d.child(
                            div()
                                .flex()
                                .flex_col()
                                .items_center()
                                .gap_1()
                                .pt_8()
                                .child(div().text_sm().text_color(chrome.text_muted).child(
                                    if empty_search {
                                        "No snippets yet"
                                    } else {
                                        "No matching snippets"
                                    },
                                ))
                                .child(div().text_xs().text_color(chrome.text_muted).child(
                                    if empty_search {
                                        "Click \"New Snippet\" to create one"
                                    } else {
                                        "Try a different search term"
                                    },
                                )),
                        )
                    }),
            )
    }

    fn render_detail(&self, chrome: Chrome, cx: &mut Context<Self>) -> AnyElement {
        let Some(entry) = self.selected_entry().cloned() else {
            return div()
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap_2()
                .child(
                    div()
                        .text_base()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("Select a snippet to view details")),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("or create a new one")),
                )
                .child(
                    self.text_button("mgr-empty-new", "New Snippet", true, chrome)
                        .on_click(cx.listener(|this, _, window, cx| this.new_snippet(window, cx))),
                )
                .into_any_element();
        };
        let settings = self.settings(cx);
        let repo_copy = settings.repo_snippets_enabled;
        let can_copy_current = repo_copy && self.repo.is_some();
        let token = |token: &'static str, text: &'static str| {
            div()
                .flex()
                .gap_3()
                .child(
                    div()
                        .w(px(150.0))
                        .text_xs()
                        .font_family("Menlo")
                        .text_color(chrome.accent)
                        .child(token),
                )
                .child(div().text_xs().text_color(chrome.text_muted).child(text))
        };
        let section = |title: &'static str| {
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(title)
        };
        let snippet = &entry.snippet;
        let copy_entry = entry.clone();
        let copy_cur = entry.clone();
        let copy_choose = entry.clone();
        let edit_entry = entry.clone();
        let delete_entry = entry.clone();
        div()
            .id("mgr-detail")
            .flex_1()
            .min_w_0()
            .overflow_y_scroll()
            .p_4()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .flex()
                    .items_start()
                    .justify_between()
                    .gap_3()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(
                                div()
                                    .text_lg()
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child(snippet.title.clone()),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(
                                        div()
                                            .text_xs()
                                            .text_color(chrome.text_muted)
                                            .child(entry.source.display_name()),
                                    )
                                    .when_some(snippet.validated_key(), |d, key| {
                                        d.child(pill(format!("Key: {key}"), chrome.accent))
                                    })
                                    .when(entry.is_overridden, |d| {
                                        d.child(pill("OVERRIDDEN", orange()))
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_2()
                            .child(self.text_button("mgr-insert", "Insert", false, chrome).on_click(
                                cx.listener(|this, _, _, cx| this.insert_selected(cx)),
                            ))
                            .when(entry.source != SnippetSource::Global, |d| {
                                d.child(
                                    self.text_button("mgr-copy-user", "Copy to User", false, chrome)
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.copy_to(&copy_entry, SnippetSource::Global, None, cx)
                                        })),
                                )
                            })
                            .when(can_copy_current, |d| {
                                d.child(
                                    self.text_button(
                                        "mgr-copy-cur",
                                        "Copy to Current Repo",
                                        false,
                                        chrome,
                                    )
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        let repo = this.repo.clone();
                                        this.copy_to(&copy_cur, SnippetSource::Repo, repo, cx)
                                    })),
                                )
                            })
                            .when(repo_copy, |d| {
                                d.child(
                                    self.text_button("mgr-copy-repo", "Copy to Repo...", false, chrome)
                                        .on_click(cx.listener(move |this, _, window, cx| {
                                            this.pending_copy = Some(copy_choose.clone());
                                            this.pick_repo(
                                                |this, root, _, cx| {
                                                    if let Some(entry) = this.pending_copy.take() {
                                                        this.copy_to(
                                                            &entry,
                                                            SnippetSource::Repo,
                                                            Some(root),
                                                            cx,
                                                        );
                                                    }
                                                },
                                                window,
                                                cx,
                                            );
                                        })),
                                )
                            })
                            .child(self.text_button("mgr-edit", "Edit", false, chrome).on_click(
                                cx.listener(move |this, _, window, cx| {
                                    this.edit_snippet(edit_entry.clone(), window, cx)
                                }),
                            ))
                            .child(
                                self.text_button("mgr-delete", "Delete", false, chrome)
                                    .text_color(chrome.danger)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.panel = Panel::ConfirmDelete(Box::new(delete_entry.clone()));
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .when_some(self.notice.clone(), |d, notice| {
                d.child(div().text_xs().text_color(chrome.danger).child(notice))
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(section("Content"))
                    .child(
                        div()
                            .p_3()
                            .rounded_lg()
                            .bg(chrome.terminal_bg)
                            .overflow_hidden()
                            .text_xs()
                            .font_family("Menlo")
                            .child(snippet.body.clone()),
                    ),
            )
            .when(
                !snippet.tags.is_empty() || snippet.folder.is_some() || snippet.shells.is_some(),
                |d| {
                    d.child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .child(section("Metadata"))
                            .child(
                                div()
                                    .flex()
                                    .gap_4()
                                    .when(!snippet.tags.is_empty(), |d| {
                                        d.child(self.meta("Tags", snippet.tags.join(", "), chrome))
                                    })
                                    .when_some(snippet.folder.clone(), |d, folder| {
                                        d.child(self.meta("Folder", folder, chrome))
                                    })
                                    .when_some(
                                        snippet.shells.clone().filter(|s| !s.is_empty()),
                                        |d, shells| d.child(self.meta("Shells", shells.join(", "), chrome)),
                                    ),
                            ),
                    )
                },
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(section("Source File"))
                    .child(
                        div()
                            .text_xs()
                            .font_family("Menlo")
                            .text_color(chrome.text_muted)
                            .child(entry.source_path.display().to_string()),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(section("Available Tokens"))
                    .child(
                        div()
                            .p_3()
                            .rounded_lg()
                            .bg(chrome.tab_bg)
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(token("${cwd}", "Current working directory"))
                            .child(token("${home}", "User home directory"))
                            .child(token("${date}", "Current date (yyyy-MM-dd)"))
                            .child(token("${time}", "Current time (HH:mm:ss)"))
                            .child(token("${clip}", "Clipboard content"))
                            .child(token("${env:VAR}", "Environment variable"))
                            .child(token("${1:default}", "Placeholder with Tab navigation")),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(section("Input Variables"))
                    .child(
                        div()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(crate::l10n::tr("Prompt for values when inserting a snippet")),
                    )
                    .child(
                        div()
                            .p_3()
                            .rounded_lg()
                            .bg(chrome.tab_bg)
                            .flex()
                            .flex_col()
                            .gap_3()
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(div().text_sm().child(crate::l10n::tr("Text Input")))
                                    .child(token("${input:name}", "Text field, no default"))
                                    .child(token("${input:port:8080}", "Text field with default value"))
                                    .child(div().text_xs().italic().text_color(chrome.text_muted).child(
                                        "Shows a text field. Use colon to set a default value.",
                                    )),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(div().text_sm().child(crate::l10n::tr("Single Select")))
                                    .child(token("${input:env:dev|staging|prod}", "Dropdown picker"))
                                    .child(div().text_xs().italic().text_color(chrome.text_muted).child(
                                        "Options separated by | create a dropdown picker. User selects one option.",
                                    )),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(div().text_sm().child(crate::l10n::tr("Multi Select")))
                                    .child(token(
                                        "${multiselect:flags:--verbose|--dry-run|--force}",
                                        "Checkbox list",
                                    ))
                                    .child(div().text_xs().italic().text_color(chrome.text_muted).child(
                                        "Checkboxes for each option. Selected values joined with spaces.",
                                    )),
                            ),
                    ),
            )
            .into_any_element()
    }

    fn meta(&self, label: &'static str, value: String, chrome: Chrome) -> gpui::Div {
        div()
            .flex()
            .flex_col()
            .gap_0p5()
            .child(div().text_xs().text_color(chrome.text_muted).child(label))
            .child(div().text_xs().child(value))
    }

    fn render_editor(&self, chrome: Chrome, cx: &mut Context<Self>) -> AnyElement {
        let Panel::Editor { form, error } = &self.panel else {
            return div().into_any_element();
        };
        let settings = self.settings(cx);
        let can_save = form.can_save(cx, true);
        let repo_enabled = settings.repo_snippets_enabled;
        let mut options: Vec<PathBuf> = Vec::new();
        if let Some(current) = &self.repo {
            options.push(current.clone());
        }
        for recent in &recent_repos(cx) {
            let path = PathBuf::from(recent);
            if !options.contains(&path) {
                options.push(path);
            }
        }
        if let Some(chosen) = &form.repo
            && !options.contains(chosen)
        {
            options.insert(0, chosen.clone());
        }
        let chips: Vec<_> = options
            .iter()
            .enumerate()
            .map(|(i, path)| {
                let active = form.repo.as_ref() == Some(path);
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| path.display().to_string());
                let value = path.clone();
                div()
                    .id(("mgr-repo", i))
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .text_xs()
                    .border_1()
                    .border_color(if active { chrome.accent } else { chrome.border })
                    .bg(if active {
                        chrome.accent.opacity(0.18)
                    } else {
                        chrome.tab_bg
                    })
                    .child(name)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Panel::Editor { form, .. } = &mut this.panel {
                            form.repo = Some(value.clone());
                        }
                        cx.notify();
                    }))
            })
            .collect();
        div()
            .id("mgr-editor")
            .flex_1()
            .min_w_0()
            .overflow_y_scroll()
            .p_4()
            .flex()
            .flex_col()
            .gap_3()
            .child(form.render(
                chrome,
                repo_enabled,
                cx,
                |this: &mut Self, source, _, cx| {
                    if let Panel::Editor { form, .. } = &mut this.panel {
                        form.source = source;
                        if source == SnippetSource::Repo && form.repo.is_none() {
                            form.repo = this
                                .repo
                                .clone()
                                .or_else(|| recent_repos(cx).first().map(PathBuf::from));
                        }
                    }
                    cx.notify();
                },
            ))
            .child(
                div()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .child(form.source.description()),
            )
            .when(form.source == SnippetSource::Repo && repo_enabled, |d| {
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .child(crate::l10n::tr("Repository")),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_wrap()
                                .items_center()
                                .gap_2()
                                .when(chips.is_empty(), |d| {
                                    d.child(
                                        div()
                                            .text_xs()
                                            .text_color(chrome.text_muted)
                                            .child(crate::l10n::tr("No recent repos")),
                                    )
                                })
                                .children(chips)
                                .child(
                                    self.text_button("mgr-choose-repo", "Choose...", false, chrome)
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.pick_repo(
                                                |this, root, _, cx| {
                                                    if let Panel::Editor { form, error } =
                                                        &mut this.panel
                                                    {
                                                        form.repo = Some(root);
                                                        *error = None;
                                                    }
                                                    cx.notify();
                                                },
                                                window,
                                                cx,
                                            );
                                        })),
                                ),
                        )
                        .when_some(form.repo.clone(), |d, repo| {
                            d.child(
                                div()
                                    .text_size(px(10.0))
                                    .font_family("Menlo")
                                    .text_color(chrome.text_muted)
                                    .child(repo.display().to_string()),
                            )
                        })
                        .child(div().text_xs().text_color(chrome.text_muted).child(
                            crate::l10n::tr("Repo snippets appear only when that repo is active."),
                        )),
                )
            })
            .when_some(error.clone(), |d, message| {
                d.child(div().text_xs().text_color(chrome.danger).child(message))
            })
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .child(
                        self.text_button("mgr-cancel", "Cancel", false, chrome)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.panel = Panel::Detail;
                                cx.notify();
                            })),
                    )
                    .child(
                        self.text_button("mgr-save", "Save", true, chrome)
                            .when(!can_save, |d| d.opacity(0.5))
                            .on_click(cx.listener(|this, _, _, cx| this.save(cx))),
                    ),
            )
            .into_any_element()
    }

    fn render_footer(&self, chrome: Chrome, cx: &mut Context<Self>) -> impl IntoElement {
        let settings = self.settings(cx);
        let switch =
            |id: &'static str,
             label: &'static str,
             on: bool,
             enabled: bool,
             apply: fn(&mut crate::settings::ProductivitySettings, bool)| {
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .when(!enabled, |d| d.opacity(0.4))
                    .child(
                        div()
                            .id(id)
                            .w(px(34.0))
                            .h(px(20.0))
                            .rounded_full()
                            .p(px(2.0))
                            .flex()
                            .when(on, |d| d.justify_end())
                            .bg(if on { chrome.accent } else { chrome.border })
                            .child(div().size(px(16.0)).rounded_full().bg(gpui::white()))
                            .on_click(move |_, _, cx| {
                                if enabled {
                                    settings_window::update(cx, |s| {
                                        apply(&mut s.productivity, !on)
                                    });
                                }
                            }),
                    )
                    .child(div().text_xs().child(label))
            };
        div()
            .flex()
            .items_center()
            .justify_between()
            .p_3()
            .border_t_1()
            .border_color(chrome.border)
            .child(
                div()
                    .flex()
                    .gap_4()
                    .child(switch(
                        "mgr-sw-enable",
                        "Enable Snippets",
                        settings.snippets_enabled,
                        true,
                        |p, v| p.snippets_enabled = v,
                    ))
                    .child(switch(
                        "mgr-sw-repo",
                        "Repo Snippets",
                        settings.repo_snippets_enabled,
                        settings.snippets_enabled,
                        |p, v| p.repo_snippets_enabled = v,
                    ))
                    .child(switch(
                        "mgr-sw-placeholders",
                        "Placeholders",
                        settings.snippet_placeholders,
                        settings.snippets_enabled,
                        |p, v| p.snippet_placeholders = v,
                    )),
            )
            .child(
                div()
                    .flex()
                    .gap_1()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::count(
                        "snippets.count",
                        "%d snippets",
                        self.entries.len(),
                    ))
                    .when_some(self.repo.clone(), |d, repo| {
                        d.child("\u{2022}").child(
                            repo.file_name()
                                .map(|n| n.to_string_lossy().to_string())
                                .unwrap_or_default(),
                        )
                    }),
            )
    }

    fn render_sheet(&self, chrome: Chrome, cx: &mut Context<Self>) -> AnyElement {
        let Panel::Sheet(sheet) = &self.panel else {
            return div().into_any_element();
        };
        let sources: &[SnippetSource] = if sheet.import {
            &[SnippetSource::Global, SnippetSource::Profile]
        } else {
            &[
                SnippetSource::Global,
                SnippetSource::Profile,
                SnippetSource::Repo,
            ]
        };
        let chips: Vec<_> = sources
            .iter()
            .map(|source| {
                let source = *source;
                let active = sheet.source == source;
                div()
                    .id(SharedString::from(format!("mgr-sheet-{}", source.raw())))
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .text_xs()
                    .border_1()
                    .border_color(if active { chrome.accent } else { chrome.border })
                    .bg(if active {
                        chrome.accent.opacity(0.18)
                    } else {
                        chrome.tab_bg
                    })
                    .child(source.display_name())
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if let Panel::Sheet(sheet) = &mut this.panel {
                            sheet.source = source;
                        }
                        let import = matches!(&this.panel, Panel::Sheet(s) if s.import);
                        if !import {
                            this.refresh_export(window, cx);
                        }
                        cx.notify();
                    }))
            })
            .collect();
        let import = sheet.import;
        let has_text = if import {
            !sheet.import_text.read(cx).value().is_empty()
        } else {
            !sheet.export_text.read(cx).value().is_empty()
        };
        div()
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(gpui::hsla(0.0, 0.0, 0.0, 0.35))
            .occlude()
            .child(
                div()
                    .w(px(520.0))
                    .p_4()
                    .rounded_xl()
                    .border_1()
                    .border_color(chrome.border)
                    .bg(chrome.panel_bg)
                    .shadow_xl()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .text_base()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(if import {
                                "Import Snippets"
                            } else {
                                "Export Snippets"
                            }),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(chrome.text_muted)
                                    .child(if import { "Import to" } else { "Source" }),
                            )
                            .children(chips),
                    )
                    .when(import, |d| {
                        d.child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .child(crate::l10n::tr("Paste JSON snippet data below:")),
                        )
                        .child(
                            div()
                                .h(px(260.0))
                                .overflow_hidden()
                                .child(Textarea::new(&sheet.import_text).h(px(260.0))),
                        )
                    })
                    .when(!import, |d| {
                        d.child(
                            Textarea::new(&sheet.export_text)
                                .h(px(260.0))
                                .readonly(true),
                        )
                    })
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .when(import, |d| {
                                d.child(
                                    self.text_button(
                                        "mgr-load-file",
                                        "Load from File...",
                                        false,
                                        chrome,
                                    )
                                    .on_click(cx.listener(
                                        |this, _, window, cx| this.load_import_file(window, cx),
                                    )),
                                )
                                .child(
                                    self.text_button("mgr-do-import", "Import", true, chrome)
                                        .when(!has_text, |d| d.opacity(0.5))
                                        .on_click(
                                            cx.listener(|this, _, _, cx| this.perform_import(cx)),
                                        ),
                                )
                            })
                            .when(!import, |d| {
                                d.child(
                                    self.text_button(
                                        "mgr-copy-export",
                                        "Copy to Clipboard",
                                        false,
                                        chrome,
                                    )
                                    .when(!has_text, |d| d.opacity(0.5))
                                    .on_click(cx.listener(
                                        |this, _, _, cx| {
                                            let text = match &this.panel {
                                                Panel::Sheet(s) => {
                                                    s.export_text.read(cx).value().to_string()
                                                }
                                                _ => return,
                                            };
                                            cx.write_to_clipboard(ClipboardItem::new_string(text));
                                            this.set_status("Copied to clipboard!", false, cx);
                                        },
                                    )),
                                )
                                .child(
                                    self.text_button(
                                        "mgr-save-export",
                                        "Save to File...",
                                        false,
                                        chrome,
                                    )
                                    .when(!has_text, |d| d.opacity(0.5))
                                    .on_click(
                                        cx.listener(|this, _, _, cx| this.save_export_file(cx)),
                                    ),
                                )
                            })
                            .child(div().flex_1())
                            .when_some(sheet.status.clone(), |d, (message, is_error)| {
                                d.child(
                                    div()
                                        .text_xs()
                                        .text_color(if is_error {
                                            chrome.danger
                                        } else {
                                            gpui::hsla(0.38, 0.6, 0.5, 1.0)
                                        })
                                        .child(message),
                                )
                            }),
                    )
                    .child(
                        div().flex().justify_end().child(
                            self.text_button("mgr-sheet-done", "Done", false, chrome)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.panel = Panel::Detail;
                                    cx.notify();
                                })),
                        ),
                    ),
            )
            .into_any_element()
    }

    fn render_confirm(
        &self,
        entry: &SnippetEntry,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let target = entry.clone();
        div()
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(gpui::hsla(0.0, 0.0, 0.0, 0.35))
            .occlude()
            .child(
                div()
                    .w(px(380.0))
                    .p_4()
                    .rounded_xl()
                    .border_1()
                    .border_color(chrome.border)
                    .bg(chrome.panel_bg)
                    .shadow_xl()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .text_base()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(crate::l10n::tr("Delete Snippet")),
                    )
                    .child(div().text_sm().child(format!(
                        "Are you sure you want to delete \"{}\"? This cannot be undone.",
                        entry.snippet.title
                    )))
                    .child(
                        div()
                            .flex()
                            .justify_end()
                            .gap_2()
                            .child(
                                self.text_button("mgr-del-cancel", "Cancel", false, chrome)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.panel = Panel::Detail;
                                        cx.notify();
                                    })),
                            )
                            .child(
                                self.text_button("mgr-del-ok", "Delete", true, chrome)
                                    .bg(chrome.danger)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        let root = cx.global::<AppData>().root.clone();
                                        let settings = this.settings(cx);
                                        super::delete_entry(&root, &settings, &target);
                                        this.selected = None;
                                        this.panel = Panel::Detail;
                                        this.reload(cx);
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
}

impl Render for SnippetsManager {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(&crate::l10n::tr("Snippets"));
        let chrome = Chrome::get(cx);
        let right: AnyElement = match &self.panel {
            Panel::Editor { .. } => self.render_editor(chrome, cx),
            _ => self.render_detail(chrome, cx),
        };
        let overlay: Option<AnyElement> = match &self.panel {
            Panel::Sheet(_) => Some(self.render_sheet(chrome, cx)),
            Panel::ConfirmDelete(entry) => {
                let entry = (**entry).clone();
                Some(self.render_confirm(&entry, chrome, cx))
            }
            _ => None,
        };
        div()
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                crate::theme::panel_titlebar(chrome)
                    .child(div().text_sm().child(crate::l10n::tr("Snippets"))),
            )
            .child(self.render_header(chrome, cx))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .child(self.render_sidebar(chrome, cx))
                    .child(right),
            )
            .child(self.render_footer(chrome, cx))
            .children(overlay)
    }
}

/// Recent repositories, newest first (`feature.recentRepoRoots`, shared with
/// Settings > Repositories).
fn recent_repos(cx: &App) -> Vec<String> {
    let file = cx
        .global::<crate::workspace::AppData>()
        .root
        .recent_repos_file();
    chau7_next_core::repo_metadata::load_recent(&file)
}
