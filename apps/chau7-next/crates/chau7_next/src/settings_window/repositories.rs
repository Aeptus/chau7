//! Repositories (`RepositoriesSettingsView.swift`): the recent repositories
//! (recorded when a tab first enters a repo) with their description and
//! labels; select one to edit its description, labels (comma separated)
//! and favorite files (one per line), saved in `<repo>/.chau7/metadata.json`.

use std::path::Path;

use chau7_next_core::iso8601::now_iso8601;
use chau7_next_core::repo_metadata::{self, RepoMetadata, repo_name};
use gpui::{App, Context, Entity, Global, SharedString, Window, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputState, Textarea, TextareaState};

use super::SectionContext;
use super::widgets::section as titled;
use crate::theme::Chrome;

/// The editor fields, created with the settings window.
pub(crate) struct RepoInputs {
    description: Entity<InputState>,
    labels: Entity<InputState>,
    favorites: Entity<TextareaState>,
}

impl RepoInputs {
    pub(crate) fn new<V: 'static>(window: &mut Window, cx: &mut Context<V>) -> Self {
        Self {
            description: cx.new(|cx| {
                InputState::new(window, cx).placeholder(crate::l10n::tr("What is this repo for?"))
            }),
            labels: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::l10n::tr("backend, rust, api (comma-separated)"))
            }),
            favorites: cx.new(|cx| TextareaState::new(window, cx)),
        }
    }
}

/// The repository being edited.
#[derive(Default)]
struct SelectedRepo(Option<String>);
impl Global for SelectedRepo {}

fn select(
    root: String,
    inputs: (
        Entity<InputState>,
        Entity<InputState>,
        Entity<TextareaState>,
    ),
    window: &mut Window,
    cx: &mut App,
) {
    let data = cx.global::<crate::workspace::AppData>().root.clone();
    let metadata = repo_metadata::load(&data, Path::new(&root));
    let (description, labels, favorites) = inputs;
    description.update(cx, |i, cx| {
        i.set_value(metadata.description.clone().unwrap_or_default(), window, cx)
    });
    labels.update(cx, |i, cx| {
        i.set_value(metadata.labels.join(", "), window, cx)
    });
    favorites.update(cx, |i, cx| {
        i.set_value(metadata.favorite_files.join("\n"), window, cx)
    });
    cx.set_global(SelectedRepo(Some(root)));
    cx.refresh_windows();
}

fn save(root: &str, inputs: &RepoInputs, cx: &mut App) {
    let metadata = RepoMetadata::from_fields(
        &inputs.description.read(cx).value(),
        &inputs.labels.read(cx).value(),
        &inputs.favorites.read(cx).value(),
        now_iso8601(),
    );
    crate::repository::save_metadata(root, metadata, cx);
    cx.refresh_windows();
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let recent = &ctx.known_repo_roots;
    let section = titled("Recent Repositories", chrome);
    if recent.is_empty() {
        return section.child(
            div()
                .flex()
                .flex_col()
                .items_center()
                .py_6()
                .child(
                    div()
                        .text_sm()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("No repositories discovered yet")),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted.opacity(0.7))
                        .child(crate::l10n::tr(
                            "Open a terminal in a git repository to get started",
                        )),
                ),
        );
    }
    let inputs = &ctx.view.repo_inputs;
    let selected = ctx.selected_repo.clone();
    let rows: Vec<_> =
        recent
            .iter()
            .map(|root| {
                let metadata = repo_metadata::load(ctx.root, Path::new(root));
                let chosen = selected.as_deref() == Some(root.as_str());
                let fields = (
                    inputs.description.clone(),
                    inputs.labels.clone(),
                    inputs.favorites.clone(),
                );
                let root_for_click = root.clone();
                div()
                    .id(SharedString::from(format!("repo-{root}")))
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .when(chosen, |d| d.bg(chrome.accent.opacity(0.18)))
                    .hover(|d| d.bg(chrome.tab_hover_bg))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_1()
                            .text_sm()
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child(div().text_color(chrome.accent).child("🗀"))
                            .child(repo_name(root)),
                    )
                    .when_some(metadata.description.clone(), |d, desc| {
                        d.child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .overflow_hidden()
                                .whitespace_nowrap()
                                .text_ellipsis()
                                .child(desc),
                        )
                    })
                    .when(!metadata.labels.is_empty(), |d| {
                        d.child(div().flex().gap_1().children(metadata.labels.iter().map(
                            |label| {
                                div()
                                    .px_1()
                                    .rounded_sm()
                                    .text_xs()
                                    .bg(chrome.accent.opacity(0.15))
                                    .text_color(chrome.accent)
                                    .child(label.clone())
                            },
                        )))
                    })
                    .on_click(move |_, window, cx| {
                        select(root_for_click.clone(), fields.clone(), window, cx)
                    })
            })
            .collect();
    let editor = match selected.clone().filter(|s| recent.contains(s)) {
        None => div()
            .py_4()
            .text_sm()
            .text_color(chrome.text_muted)
            .child(crate::l10n::tr("Select a repository to edit")),
        Some(root) => editor(&root, inputs, chrome),
    };
    section.child(
        div()
            .flex()
            .gap_4()
            .child(div().w(px(200.0)).flex().flex_col().gap_1().children(rows))
            .child(div().flex_1().min_w_0().child(editor)),
    )
}

fn editor(root: &str, inputs: &RepoInputs, chrome: Chrome) -> gpui::Div {
    let label = |text: &'static str| {
        div()
            .text_xs()
            .font_weight(gpui::FontWeight::MEDIUM)
            .child(text)
    };
    let save_root = root.to_string();
    let save_inputs = RepoInputs {
        description: inputs.description.clone(),
        labels: inputs.labels.clone(),
        favorites: inputs.favorites.clone(),
    };
    div()
        .flex()
        .flex_col()
        .gap_3()
        .child(
            div()
                .flex()
                .items_center()
                .gap_1()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(div().text_color(chrome.accent).child("🗀"))
                .child(repo_name(root)),
        )
        .child(
            div()
                .text_xs()
                .font_family("Menlo")
                .text_color(chrome.text_muted)
                .child(root.to_string()),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(label("Description"))
                .child(Input::new(&inputs.description)),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(label("Labels"))
                .child(Input::new(&inputs.labels)),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(label("Favorite Files"))
                .child(
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted.opacity(0.7))
                        .child(crate::l10n::tr("Relative paths, one per line")),
                )
                .child(Textarea::new(&inputs.favorites).h(px(80.0))),
        )
        .child(
            div().flex().justify_end().child(
                div()
                    .id("repo-save")
                    .px_3()
                    .py_1()
                    .rounded_md()
                    .text_sm()
                    .bg(chrome.accent)
                    .text_color(gpui::white())
                    .child(crate::l10n::tr("Save"))
                    .on_click(move |_, _, cx| save(&save_root, &save_inputs, cx)),
            ),
        )
}

/// The repository selected in the list, if any.
pub(super) fn selected_repo(cx: &App) -> Option<String> {
    cx.try_global::<SelectedRepo>().and_then(|s| s.0.clone())
}

/// Remember that a tab entered `root` (`recordRecentRepo`).
pub(crate) fn record_recent_repo(root: &str, cx: &App) {
    crate::repository::record_recent(root, cx);
}
