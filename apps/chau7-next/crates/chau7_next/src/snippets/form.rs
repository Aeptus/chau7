//! The snippet editor form, shared by the picker's inline editor and the
//! "Manage Snippets" window (`SnippetEditorView` and `SnippetEditorPanel`).

use std::path::PathBuf;

use chau7_next_core::snippet_store::{SnippetDraft, SnippetEntry, SnippetSource};
use gpui::{App, Context, Entity, SharedString, Window, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputState, Textarea, TextareaState};

use crate::theme::Chrome;

pub struct SnippetForm {
    /// The snippet being edited; `None` for a new one.
    pub editing: Option<SnippetEntry>,
    title: Entity<InputState>,
    id: Entity<InputState>,
    key: Entity<InputState>,
    tags: Entity<InputState>,
    folder: Entity<InputState>,
    shells: Entity<InputState>,
    body: Entity<TextareaState>,
    pub source: SnippetSource,
    /// Repository a Repo snippet is saved in.
    pub repo: Option<PathBuf>,
}

fn input(
    placeholder: &'static str,
    value: &str,
    window: &mut Window,
    cx: &mut App,
) -> Entity<InputState> {
    let value = value.to_string();
    cx.new(|cx| {
        InputState::new(window, cx)
            .placeholder(placeholder)
            .default_value(value)
    })
}

impl SnippetForm {
    /// A form filled from `entry`, or empty (defaults to `source`).
    pub fn new(
        entry: Option<&SnippetEntry>,
        source: SnippetSource,
        repo: Option<PathBuf>,
        window: &mut Window,
        cx: &mut App,
    ) -> Self {
        let draft = entry.map(SnippetDraft::from_entry).unwrap_or_default();
        let body_text = draft.body.clone();
        let body = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(6)
                .placeholder(crate::l10n::tr("Command or text to insert"))
                .default_value(body_text)
        });
        let (source, repo) = match entry {
            Some(e) => (e.source, e.repo_root.clone().or(repo)),
            None => (source, repo),
        };
        Self {
            editing: entry.cloned(),
            title: input("Title", &draft.title, window, cx),
            id: input("ID (optional)", &draft.id, window, cx),
            key: input("Key", &draft.key, window, cx),
            tags: input("Tags (comma separated)", &draft.tags_text, window, cx),
            folder: input("Folder", &draft.folder, window, cx),
            shells: input("Shells (zsh, bash, fish)", &draft.shells_text, window, cx),
            body,
            source,
            repo,
        }
    }

    pub fn focus_title(&self, window: &mut Window, cx: &mut App) {
        self.title.update(cx, |i, cx| i.focus(window, cx));
    }

    pub fn is_new(&self) -> bool {
        self.editing.is_none()
    }

    /// The form as a draft; the title is trimmed.
    pub fn draft(&self, cx: &App) -> SnippetDraft {
        let read = |e: &Entity<InputState>| e.read(cx).value().to_string();
        SnippetDraft {
            id: read(&self.id).trim().to_string(),
            title: read(&self.title).trim().to_string(),
            body: self.body.read(cx).value().to_string(),
            tags_text: read(&self.tags),
            folder: read(&self.folder),
            shells_text: read(&self.shells),
            key: read(&self.key),
            source: self.source,
            repo_path: self
                .repo
                .as_ref()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default(),
        }
    }

    /// Save needs a title, a body (when `require_body`), and a repository for
    /// Repo snippets.
    pub fn can_save(&self, cx: &App, require_body: bool) -> bool {
        let draft = self.draft(cx);
        !draft.title.is_empty()
            && (!require_body || !draft.body.is_empty())
            && (draft.source != SnippetSource::Repo || !draft.repo_path.is_empty())
    }

    /// The fields. `set_source` is called when a location chip is clicked.
    pub fn render<T: 'static>(
        &self,
        chrome: Chrome,
        repo_available: bool,
        cx: &mut Context<T>,
        set_source: fn(&mut T, SnippetSource, &mut Window, &mut Context<T>),
    ) -> impl IntoElement {
        let mut sources = vec![SnippetSource::Global, SnippetSource::Profile];
        if repo_available || self.source == SnippetSource::Repo {
            sources.push(SnippetSource::Repo);
        }
        let chips = sources.into_iter().map(|source| {
            let active = self.source == source;
            div()
                .id(SharedString::from(format!(
                    "snippet-source-{}",
                    source.raw()
                )))
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
                .hover(|d| d.bg(chrome.tab_hover_bg))
                .child(source.display_name())
                .on_click(cx.listener(move |this, _, window, cx| {
                    set_source(this, source, window, cx);
                }))
        });
        div()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .text_sm()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(if self.is_new() {
                        "New Snippet"
                    } else {
                        "Edit Snippet"
                    }),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(div().flex_1().child(Input::new(&self.title)))
                    .child(div().w(px(110.0)).child(Input::new(&self.id)))
                    .child(div().w(px(56.0)).child(Input::new(&self.key))),
            )
            .child(Textarea::new(&self.body).h(px(120.0)))
            .child(
                div()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .child("Variables: ${input:Name} or ${input:Name:default}"),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(div().flex_1().child(Input::new(&self.tags)))
                    .child(div().flex_1().child(Input::new(&self.folder))),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .items_center()
                    .child(div().flex_1().child(Input::new(&self.shells)))
                    .child(div().flex().gap_1().children(chips)),
            )
    }
}
