//! The snippet picker (`SnippetManagerOverlayView` in `Chau7OverlayView.swift`):
//! search, quick-select letters, pin/edit/delete, the inline editor and the
//! "Fill in variables" dialog.

use std::path::PathBuf;

use chau7_next_core::snippet_store::{
    self, InputType, InputVariable, KeyMap, SnippetEntry, SnippetSource,
};
use gpui::{
    AnyElement, Context, Entity, KeyDownEvent, ScrollHandle, SharedString, Subscription, Window,
    div, prelude::*, px,
};
use gpui_kit::component::input::{InputEvent, InputState};

use super::super::widgets::{button, chrome_input, modal_width};
use super::{PickerItem, PickerKind};
use crate::settings::Settings;
use crate::snippets::{self, form::SnippetForm};
use crate::theme::Chrome;
use crate::workspace::{AppData, Workspace};

/// What the snippet sheet shows besides the list.
#[derive(Default)]
pub(super) enum Mode {
    #[default]
    List,
    Editor {
        form: Box<SnippetForm>,
        error: Option<String>,
    },
    Variables(Box<VariableForm>),
    ConfirmDelete(Box<SnippetEntry>),
}

#[derive(Default)]
pub(super) struct SnippetUi {
    pub mode: Mode,
    scroll: ScrollHandle,
}

/// The "Fill in variables" dialog.
pub(super) struct VariableForm {
    entry: SnippetEntry,
    variables: Vec<InputVariable>,
    /// One text field per text variable (and per picker without options).
    inputs: Vec<Option<Entity<InputState>>>,
    _subscriptions: Vec<Subscription>,
}

fn entries_of(items: &[PickerItem]) -> Vec<&SnippetEntry> {
    items
        .iter()
        .filter_map(|item| match item {
            PickerItem::Snippet(entry) => Some(entry),
            _ => None,
        })
        .collect()
}

impl Workspace {
    /// Git root of the focused terminal (what "active repo" follows).
    pub(crate) fn active_git_root(&self, cx: &gpui::App) -> Option<PathBuf> {
        self.focused_git_root(cx)
    }

    /// Insert a snippet by id, for automation (`SNP-037`): select `tab`
    /// first when given. Input variables are not asked for.
    #[allow(dead_code)]
    pub(crate) fn insert_snippet_by_id(
        &mut self,
        id: &str,
        tab: Option<crate::tab_bar::TabId>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let root = cx.global::<AppData>().root.clone();
        let settings = Settings::get(cx).productivity.clone();
        if let Some(tab) = tab {
            if !self.entries.contains_key(&tab) {
                return false;
            }
            self.select_tab(tab, window, cx);
        }
        let git_root = self.focused_git_root(cx);
        let Some(entry) = snippets::load_entries(&root, &settings, git_root.as_deref())
            .into_iter()
            .find(|e| e.snippet.id == id)
        else {
            return false;
        };
        self.insert_snippet_text(&entry.snippet.body, None, cx);
        true
    }

    fn focused_git_root(&self, cx: &gpui::App) -> Option<PathBuf> {
        self.selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx))
            .and_then(|s| s.read(cx).git_root.clone())
    }

    /// The repo whose snippets show now (see `snippets::active_repo`).
    fn snippet_repo(&self, cx: &gpui::App) -> Option<PathBuf> {
        let settings = &Settings::get(cx).productivity;
        snippets::active_repo(settings, self.focused_git_root(cx).as_deref())
    }

    fn refocus_snippet_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(picker) = self.picker.as_ref() {
            picker.input.update(cx, |i, cx| i.focus(window, cx));
        }
    }

    pub(super) fn snippet_new(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let repo = self.snippet_repo(cx);
        let source = if repo.is_some() {
            SnippetSource::Repo
        } else {
            SnippetSource::Global
        };
        let form = SnippetForm::new(None, source, repo, window, cx);
        form.focus_title(window, cx);
        if let Some(picker) = self.picker.as_mut() {
            picker.snip.mode = Mode::Editor {
                form: Box::new(form),
                error: None,
            };
        }
        cx.notify();
    }

    fn snippet_edit(&mut self, entry: SnippetEntry, window: &mut Window, cx: &mut Context<Self>) {
        let repo = self.snippet_repo(cx);
        let form = SnippetForm::new(Some(&entry), entry.source, repo, window, cx);
        form.focus_title(window, cx);
        if let Some(picker) = self.picker.as_mut() {
            picker.snip.mode = Mode::Editor {
                form: Box::new(form),
                error: None,
            };
        }
        cx.notify();
    }

    fn snippet_save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(Mode::Editor { form, .. }) = self.picker.as_ref().map(|p| &p.snip.mode) else {
            return;
        };
        let draft = form.draft(cx);
        let editing = form.editing.clone();
        let result = if draft.title.is_empty() {
            Err("A title is required.".to_string())
        } else if draft.source == SnippetSource::Repo && draft.repo_path.is_empty() {
            Err("Open a tab in a git repository to save a repo snippet.".to_string())
        } else {
            let root = cx.global::<AppData>().root.clone();
            let settings = Settings::get(cx).productivity.clone();
            let repo = self.snippet_repo(cx);
            snippets::save_draft(&root, &settings, editing.as_ref(), &draft, repo.as_deref())
        };
        match result {
            Ok(()) => {
                if let Some(picker) = self.picker.as_mut() {
                    picker.snip.mode = Mode::List;
                }
                self.refilter_picker(cx);
                self.refocus_snippet_search(window, cx);
            }
            Err(message) => {
                if let Some(picker) = self.picker.as_mut()
                    && let Mode::Editor { error, .. } = &mut picker.snip.mode
                {
                    *error = Some(message);
                }
            }
        }
        cx.notify();
    }

    fn snippet_back_to_list(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(picker) = self.picker.as_mut() {
            picker.snip.mode = Mode::List;
        }
        self.refocus_snippet_search(window, cx);
        cx.notify();
    }

    fn snippet_toggle_pin(&mut self, entry: &SnippetEntry, cx: &mut Context<Self>) {
        let root = cx.global::<AppData>().root.clone();
        let settings = Settings::get(cx).productivity.clone();
        snippets::toggle_pin(&root, &settings, entry);
        self.refilter_picker(cx);
    }

    fn snippet_delete(
        &mut self,
        entry: &SnippetEntry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let root = cx.global::<AppData>().root.clone();
        let settings = Settings::get(cx).productivity.clone();
        snippets::delete_entry(&root, &settings, entry);
        self.snippet_back_to_list(window, cx);
        self.refilter_picker(cx);
    }

    /// Insert `entry`, asking for its `${input:...}` variables first.
    pub(super) fn snippet_attempt_insert(
        &mut self,
        entry: SnippetEntry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let variables = snippet_store::parse_input_variables(&entry.snippet.body);
        if variables.is_empty() {
            self.snippet_insert(&entry, None, window, cx);
            return;
        }
        let mut subscriptions = Vec::new();
        let mut inputs = Vec::new();
        let last = variables.len() - 1;
        for (index, variable) in variables.iter().enumerate() {
            let wants_text = variable.input_type == InputType::Text || variable.options.is_empty();
            if !wants_text {
                inputs.push(None);
                continue;
            }
            let placeholder = if variable.default_value.is_empty() {
                "Enter value...".to_string()
            } else {
                variable.default_value.clone()
            };
            let value = variable.value.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(placeholder)
                    .default_value(value)
            });
            subscriptions.push(cx.subscribe_in(
                &input,
                window,
                move |this, _, event: &InputEvent, window, cx| {
                    if let InputEvent::PressEnter { .. } = event {
                        this.snippet_variable_enter(index, last, window, cx);
                    }
                },
            ));
            inputs.push(Some(input));
        }
        if let Some(first) = inputs.iter().flatten().next() {
            first.update(cx, |i, cx| i.focus(window, cx));
        }
        if let Some(picker) = self.picker.as_mut() {
            picker.snip.mode = Mode::Variables(Box::new(VariableForm {
                entry,
                variables,
                inputs,
                _subscriptions: subscriptions,
            }));
        }
        cx.notify();
    }

    /// Enter in a variable field: the next field, or insert after the last.
    fn snippet_variable_enter(
        &mut self,
        index: usize,
        last: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if index >= last {
            self.snippet_submit_variables(window, cx);
            return;
        }
        let next = match self.picker.as_ref().map(|p| &p.snip.mode) {
            Some(Mode::Variables(form)) => {
                form.inputs[index + 1..].iter().flatten().next().cloned()
            }
            _ => None,
        };
        match next {
            Some(input) => input.update(cx, |i, cx| i.focus(window, cx)),
            None => self.snippet_submit_variables(window, cx),
        }
    }

    /// Tab / Shift+Tab in the variables dialog: the next or previous text
    /// field, wrapping around.
    fn snippet_variable_tab(&mut self, back: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(Mode::Variables(form)) = self.picker.as_ref().map(|p| &p.snip.mode) else {
            return;
        };
        let fields: Vec<Entity<InputState>> = form.inputs.iter().flatten().cloned().collect();
        if fields.is_empty() {
            return;
        }
        let current = fields
            .iter()
            .position(|f| gpui::Focusable::focus_handle(f.read(cx), cx).is_focused(window));
        let n = fields.len();
        let next = match (current, back) {
            (Some(i), false) => (i + 1) % n,
            (Some(i), true) => (i + n - 1) % n,
            (None, false) => 0,
            (None, true) => n - 1,
        };
        fields[next].update(cx, |i, cx| i.focus(window, cx));
    }

    fn snippet_submit_variables(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(Mode::Variables(form)) = self.picker.as_ref().map(|p| &p.snip.mode) else {
            return;
        };
        let mut variables = form.variables.clone();
        for (variable, input) in variables.iter_mut().zip(&form.inputs) {
            if let Some(input) = input {
                variable.value = input.read(cx).value().to_string();
            }
        }
        let entry = form.entry.clone();
        self.snippet_insert(&entry, Some(variables), window, cx);
    }

    /// Type the snippet into the focused terminal and close the picker.
    pub(super) fn snippet_insert(
        &mut self,
        entry: &SnippetEntry,
        variables: Option<Vec<InputVariable>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.picker = None;
        self.insert_snippet_text(&entry.snippet.body, variables.as_deref(), cx);
        self.focus_selected(window, cx);
        cx.notify();
    }

    /// Expand `body` (input variables, tokens, tab stops) into the focused
    /// terminal. Also used by automation (`SNP-037`).
    pub(crate) fn insert_snippet_text(
        &mut self,
        body: &str,
        variables: Option<&[InputVariable]>,
        cx: &mut Context<Self>,
    ) {
        let Some(view) = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_view())
        else {
            return;
        };
        let body = match variables {
            Some(vars) => snippet_store::replace_input_variables(body, vars),
            None => body.to_string(),
        };
        let cwd = view
            .read(cx)
            .session
            .read(cx)
            .cwd
            .as_ref()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        let root = cx.global::<AppData>().root.clone();
        let settings = Settings::get(cx).productivity.clone();
        let insertion = snippets::prepare_insertion(&body, &cwd, &root, &settings, cx);
        view.update(cx, |v, cx| v.insert_snippet(&insertion, cx));
    }

    /// Enter in the search field.
    pub(super) fn snippet_enter(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(picker) = self.picker.as_ref() else {
            return;
        };
        if !matches!(picker.snip.mode, Mode::List) {
            return;
        }
        if let Some(PickerItem::Snippet(entry)) = picker.items.get(picker.selected).cloned() {
            self.snippet_attempt_insert(entry, window, cx);
        }
    }

    fn snippet_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(picker) = self.picker.as_mut() else {
            return;
        };
        let key = event.keystroke.key.as_str();
        let m = &event.keystroke.modifiers;
        match &picker.snip.mode {
            Mode::List => match key {
                "down" | "up" => {
                    let last = picker.items.len().saturating_sub(1);
                    picker.selected = if key == "down" {
                        (picker.selected + 1).min(last)
                    } else {
                        picker.selected.saturating_sub(1)
                    };
                    picker.snip.scroll.scroll_to_item(picker.selected);
                    cx.notify();
                }
                "escape" => {
                    self.picker = None;
                    self.focus_selected(window, cx);
                    cx.notify();
                }
                _ => {
                    let letter = key.chars().next().filter(|c| {
                        key.len() == 1
                            && c.is_ascii_alphabetic()
                            && !m.control
                            && !m.alt
                            && !m.platform
                    });
                    let empty = picker.input.read(cx).value().is_empty();
                    if let (Some(letter), true) = (letter, empty) {
                        let map: KeyMap = snippet_store::build_key_map(&entries_of(&picker.items));
                        let entry = map
                            .key_to_index
                            .get(&letter.to_ascii_lowercase())
                            .and_then(|i| picker.items.get(*i))
                            .cloned();
                        if let Some(PickerItem::Snippet(entry)) = entry {
                            window.prevent_default();
                            cx.stop_propagation();
                            self.snippet_attempt_insert(entry, window, cx);
                        }
                    }
                }
            },
            Mode::Editor { .. } | Mode::Variables(_) | Mode::ConfirmDelete(_) => match key {
                "escape" => self.snippet_back_to_list(window, cx),
                "enter" => {
                    if let Mode::ConfirmDelete(entry) = &picker.snip.mode {
                        let entry = (**entry).clone();
                        self.snippet_delete(&entry, window, cx);
                    }
                }
                _ => {}
            },
        }
    }

    pub(super) fn render_snippet_picker(
        &self,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let picker = self.picker.as_ref()?;
        debug_assert!(picker.kind == PickerKind::Snippets);
        let enabled = Settings::get(cx).productivity.snippets_enabled;
        let repo = self.snippet_repo(cx);
        let heading = |label: &'static str| {
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(label)
        };

        let body: AnyElement = match &picker.snip.mode {
            Mode::Editor { form, error } => {
                let can_save = !form.draft(cx).title.is_empty();
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(form.render(
                        chrome,
                        repo.is_some(),
                        cx,
                        |this: &mut Workspace, source, _, cx| {
                            if let Some(picker) = this.picker.as_mut()
                                && let Mode::Editor { form, .. } = &mut picker.snip.mode
                            {
                                form.source = source;
                                cx.notify();
                            }
                        },
                    ))
                    .when_some(error.clone(), |d, message| {
                        d.child(div().text_xs().text_color(chrome.danger).child(message))
                    })
                    .child(
                        div()
                            .flex()
                            .justify_end()
                            .gap_2()
                            .child(button("snip-cancel", "Cancel", chrome, false).on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.snippet_back_to_list(window, cx)
                                }),
                            ))
                            .child(
                                button("snip-save", "Save", chrome, true)
                                    .when(!can_save, |d| d.opacity(0.5))
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.snippet_save(window, cx)
                                    })),
                            ),
                    )
                    .into_any_element()
            }
            Mode::Variables(form) => self.render_variable_dialog(form, chrome, cx),
            Mode::ConfirmDelete(entry) => {
                let target = (**entry).clone();
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(heading("Delete snippet?"))
                    .child(
                        div()
                            .text_sm()
                            .text_color(chrome.text_muted)
                            .child(entry.snippet.title.clone()),
                    )
                    .child(
                        div()
                            .flex()
                            .justify_end()
                            .gap_2()
                            .child(button("snip-del-cancel", "Cancel", chrome, false).on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.snippet_back_to_list(window, cx)
                                }),
                            ))
                            .child(
                                button("snip-del-confirm", "Delete", chrome, true)
                                    .bg(chrome.danger)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.snippet_delete(&target, window, cx)
                                    })),
                            ),
                    )
                    .into_any_element()
            }
            Mode::List => self.render_snippet_list(chrome, enabled, cx),
        };

        // Escape closes the sheet from the list (`ToggleSnippets`); in the
        // editor and dialogs it goes back to the list instead.
        let context = if matches!(picker.snip.mode, Mode::List) {
            "Snippets"
        } else {
            "SnippetsForm"
        };
        let show_header = matches!(picker.snip.mode, Mode::List | Mode::Editor { .. });
        let content = div()
            .key_context(context)
            .flex()
            .flex_col()
            .gap_2()
            .when(show_header, |d| {
                d.child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(heading("Snippets"))
                        .child(
                            button("snip-new", "New", chrome, false)
                                .when(!enabled, |d| d.opacity(0.4))
                                .on_click(cx.listener(|this, _, window, cx| {
                                    if Settings::get(cx).productivity.snippets_enabled {
                                        this.snippet_new(window, cx);
                                    }
                                })),
                        ),
                )
            })
            .child(body)
            .when(enabled, |d| {
                d.when_some(repo.clone(), |d, root| {
                    d.child(
                        div()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .overflow_hidden()
                            .text_ellipsis()
                            .child(format!("Repo: {}", root.display())),
                    )
                })
            })
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                this.snippet_key_down(event, window, cx)
            }));
        Some(modal_width(
            chrome,
            560.0,
            content,
            cx.listener(|this, _, window, cx| this.dismiss_picker(window, cx)),
        ))
    }

    fn render_snippet_list(
        &self,
        chrome: Chrome,
        enabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(picker) = self.picker.as_ref() else {
            return div().into_any_element();
        };
        if !enabled {
            return div()
                .text_xs()
                .text_color(chrome.text_muted)
                .py_2()
                .child(crate::l10n::tr("Snippets are disabled in Settings."))
                .into_any_element();
        }
        let query_empty = picker.input.read(cx).value().is_empty();
        let entries = entries_of(&picker.items);
        let map = snippet_store::build_key_map(&entries);
        let rows: Vec<_> = picker
            .items
            .iter()
            .enumerate()
            .filter_map(|(index, item)| match item {
                PickerItem::Snippet(entry) => Some((index, entry)),
                _ => None,
            })
            .map(|(index, entry)| {
                let letter = query_empty
                    .then(|| map.snippet_keys.get(&entry.entry_id()).copied())
                    .flatten();
                let conflict = entry
                    .snippet
                    .validated_key()
                    .is_some_and(|k| map.conflicting.contains(&k));
                self.render_snippet_row(
                    index,
                    entry,
                    letter,
                    conflict,
                    index == picker.selected,
                    chrome,
                    cx,
                )
            })
            .collect();
        let empty = rows.is_empty();
        div()
            .flex()
            .flex_col()
            .gap_2()
            .child(chrome_input(&picker.input, chrome))
            .child(
                div()
                    .id("snippet-list")
                    .flex()
                    .flex_col()
                    .gap_1()
                    .max_h(px(400.0))
                    .overflow_y_scroll()
                    .track_scroll(&picker.snip.scroll)
                    .children(rows),
            )
            .when(empty, |d| {
                d.child(
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .py_2()
                        .child(crate::l10n::tr("No snippets found.")),
                )
            })
            .when(!empty && query_empty, |d| {
                d.child(
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("Press a letter to quick-insert")),
                )
            })
            .into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn render_snippet_row(
        &self,
        index: usize,
        entry: &SnippetEntry,
        letter: Option<char>,
        conflict: bool,
        selected: bool,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let badge = |text: String, color: gpui::Hsla| {
            div()
                .size(px(18.0))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(4.0))
                .bg(color)
                .text_color(gpui::white())
                .text_xs()
                .font_weight(gpui::FontWeight::BOLD)
                .font_family("Menlo")
                .child(text)
        };
        let pinned = entry.snippet.is_pinned;
        let small = |label: &'static str| {
            div()
                .px_1()
                .text_xs()
                .text_color(chrome.text_muted)
                .hover(|d| d.text_color(chrome.text))
                .child(label)
        };
        let id = |name: &'static str| SharedString::from(format!("snip-{name}-{index}"));
        let insert_entry = entry.clone();
        let pin_entry = entry.clone();
        let edit_entry = entry.clone();
        let delete_entry = entry.clone();
        let source_badge = div()
            .px_1p5()
            .rounded_full()
            .bg(chrome.tab_bg)
            .text_color(chrome.text_muted)
            .child(entry.source.display_name().to_uppercase())
            .text_size(px(9.0));
        div()
            .id(("snip-row", index))
            .flex()
            .items_start()
            .gap_2()
            .px_2()
            .py_1p5()
            .rounded_md()
            .when(selected, |d| d.bg(chrome.tab_selected_bg))
            .hover(|d| d.bg(chrome.tab_hover_bg))
            .when_some(letter, |d, letter| {
                d.child(badge(letter.to_string(), chrome.accent.opacity(0.8)))
            })
            .when(letter.is_none() && conflict, |d| {
                d.when_some(entry.snippet.validated_key(), |d, key| {
                    d.child(badge(key.to_string(), gpui::hsla(0.08, 0.9, 0.5, 0.8)))
                })
            })
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_1p5()
                            .when(pinned, |d| {
                                d.child(
                                    div()
                                        .text_xs()
                                        .text_color(chrome.accent)
                                        .child(crate::l10n::tr("PIN")),
                                )
                            })
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child(entry.snippet.title.clone()),
                            )
                            .child(source_badge)
                            .when(entry.is_overridden, |d| {
                                d.child(
                                    div()
                                        .text_size(px(9.0))
                                        .text_color(chrome.text_muted)
                                        .child(crate::l10n::tr("OVERRIDDEN")),
                                )
                            })
                            .when(conflict, |d| {
                                d.child(
                                    div()
                                        .text_size(px(9.0))
                                        .text_color(gpui::hsla(0.08, 0.9, 0.5, 1.0))
                                        .child(crate::l10n::tr("KEY CONFLICT")),
                                )
                            }),
                    )
                    .child(
                        div()
                            .text_xs()
                            .font_family("Menlo")
                            .text_color(chrome.text_muted)
                            .max_h(px(32.0))
                            .overflow_hidden()
                            .child(entry.snippet.body.clone()),
                    )
                    .when(!entry.snippet.tags.is_empty(), |d| {
                        d.child(
                            div()
                                .text_size(px(10.0))
                                .text_color(chrome.text_muted)
                                .child(entry.snippet.tags.join(", ")),
                        )
                    }),
            )
            .child(
                div()
                    .flex()
                    .gap_1()
                    .child(
                        small(if pinned { "Unpin" } else { "Pin" })
                            .id(id("pin"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                cx.stop_propagation();
                                this.snippet_toggle_pin(&pin_entry, cx);
                            })),
                    )
                    .child(small("Insert").id(id("insert")).on_click(cx.listener(
                        move |this, _, window, cx| {
                            cx.stop_propagation();
                            this.snippet_attempt_insert(insert_entry.clone(), window, cx);
                        },
                    )))
                    .child(small("Edit").id(id("edit")).on_click(cx.listener(
                        move |this, _, window, cx| {
                            cx.stop_propagation();
                            this.snippet_edit(edit_entry.clone(), window, cx);
                        },
                    )))
                    .child(small("Delete").id(id("delete")).on_click(cx.listener(
                        move |this, _, _, cx| {
                            cx.stop_propagation();
                            if let Some(picker) = this.picker.as_mut() {
                                picker.snip.mode =
                                    Mode::ConfirmDelete(Box::new(delete_entry.clone()));
                            }
                            cx.notify();
                        },
                    ))),
            )
            .on_click({
                let entry = entry.clone();
                cx.listener(move |this, _, window, cx| {
                    this.snippet_attempt_insert(entry.clone(), window, cx);
                })
            })
            .into_any_element()
    }

    fn render_variable_dialog(
        &self,
        form: &VariableForm,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let fields = form.variables.iter().enumerate().map(|(index, variable)| {
            let control: AnyElement = match (variable.input_type, &form.inputs[index]) {
                (_, Some(input)) => chrome_input(input, chrome).into_any_element(),
                (InputType::SingleSelect, None) => {
                    let chips = variable.options.iter().enumerate().map(|(pos, option)| {
                        let active = &variable.value == option;
                        let value = option.clone();
                        chip(("snip-var-opt", index * 1000 + pos), option, active, chrome).on_click(
                            cx.listener(move |this, _, _, cx| {
                                if let Some(picker) = this.picker.as_mut()
                                    && let Mode::Variables(form) = &mut picker.snip.mode
                                {
                                    form.variables[index].value = value.clone();
                                    cx.notify();
                                }
                            }),
                        )
                    });
                    div()
                        .flex()
                        .flex_wrap()
                        .gap_1p5()
                        .children(chips)
                        .into_any_element()
                }
                _ => {
                    let chips = variable.options.iter().enumerate().map(|(pos, option)| {
                        let active = variable.selected.contains(option);
                        let value = option.clone();
                        chip(
                            ("snip-var-multi", index * 1000 + pos),
                            option,
                            active,
                            chrome,
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(picker) = this.picker.as_mut()
                                && let Mode::Variables(form) = &mut picker.snip.mode
                            {
                                let set = &mut form.variables[index].selected;
                                if !set.remove(&value) {
                                    set.insert(value.clone());
                                }
                                cx.notify();
                            }
                        }))
                    });
                    div()
                        .flex()
                        .flex_wrap()
                        .gap_1p5()
                        .children(chips)
                        .into_any_element()
                }
            };
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .text_xs()
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .text_color(chrome.text_muted)
                        .child(variable.name.clone()),
                )
                .child(control)
        });
        div()
            .flex()
            .flex_col()
            .gap_3()
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                let keys = &event.keystroke;
                if keys.key == "tab" && !keys.modifiers.platform && !keys.modifiers.control {
                    this.snippet_variable_tab(keys.modifiers.shift, window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_sm()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(crate::l10n::tr("Fill in variables")),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(form.entry.snippet.title.clone()),
                    ),
            )
            .children(fields)
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .child(button("snip-var-cancel", "Cancel", chrome, false).on_click(
                        cx.listener(|this, _, window, cx| this.snippet_back_to_list(window, cx)),
                    ))
                    .child(button("snip-var-insert", "Insert", chrome, true).on_click(
                        cx.listener(|this, _, window, cx| {
                            this.snippet_submit_variables(window, cx)
                        }),
                    )),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .child("Tab to next field \u{2022} Enter to insert"),
            )
            .into_any_element()
    }
}

fn chip(
    id: (&'static str, usize),
    label: &str,
    active: bool,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px_2()
        .py_0p5()
        .rounded_md()
        .text_xs()
        .bg(if active { chrome.accent } else { chrome.tab_bg })
        .text_color(if active { gpui::white() } else { chrome.text })
        .hover(|d| d.opacity(0.85))
        .child(label.to_string())
}
