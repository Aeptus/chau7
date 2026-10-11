//! Productivity: snippets, clipboard history, bookmarks, find defaults.

use gpui::{div, prelude::*, px};
use gpui_kit::component::input::Input;

use super::super::widgets::{chip, row, section as titled, stepper, toggle};
use super::super::{SectionContext, update};
use super::{hint, small_button};
use crate::settings::SnippetInsertMode;

pub(in super::super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let p = &ctx.settings.productivity;

    let insert_modes = [
        ("Expand (type)", SnippetInsertMode::Expand),
        ("Paste", SnippetInsertMode::Paste),
    ]
    .into_iter()
    .map(|(label, mode)| {
        chip(
            gpui::SharedString::from(format!("insert-{label}")),
            label,
            p.snippet_insert_mode == mode,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.productivity.snippet_insert_mode = mode))
    });

    let mut snippets = titled("Snippets", chrome)
        .child(row(
            "Enable snippets",
            toggle("snippets-enabled", p.snippets_enabled, chrome, |s, v| {
                s.productivity.snippets_enabled = v
            }),
            chrome,
        ))
        .child(row(
            "User snippets",
            div()
                .flex()
                .items_center()
                .gap_3()
                .child(
                    div()
                        .text_sm()
                        .text_color(chrome.text_muted)
                        .child(format!("{}", ctx.view.mine.user_snippets)),
                )
                .child(
                    small_button("manage-snippets", "Manage Snippets...", chrome)
                        .on_click(|_, _, cx| crate::snippets::manager::open(cx)),
                ),
            chrome,
        ))
        .child(row(
            "Repository snippets",
            toggle(
                "repo-snippets-enabled",
                p.repo_snippets_enabled,
                chrome,
                |s, v| s.productivity.repo_snippets_enabled = v,
            ),
            chrome,
        ));
    if p.repo_snippets_enabled {
        snippets = snippets
            .child(row(
                "Snippets path",
                div()
                    .w(px(220.0))
                    .child(Input::new(&ctx.view.mine.repo_path)),
                chrome,
            ))
            .child(hint(
                "Relative to the git root; the default is .chau7/snippets.",
                chrome,
            ))
            .child(hint(
                "Repo snippets in Documents, Desktop and Downloads follow \"Allow protected folder access\" in General.",
                chrome,
            ));
        if cfg!(target_os = "macos") && ctx.settings.general.allow_protected_folder_access {
            snippets = snippets.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        small_button("grant-access", "Grant Access", chrome).on_click(
                            |_, _, cx| {
                                let home = cx
                                    .global::<crate::workspace::AppData>()
                                    .root
                                    .home()
                                    .to_path_buf();
                                crate::snippets::request_protected_folder_access(&home);
                            },
                        ),
                    )
                    .child(
                        small_button("open-files-settings", "Open System Settings", chrome)
                            .on_click(|_, _, cx| {
                                cx.open_url(crate::snippets::FILES_AND_FOLDERS_SETTINGS_URL)
                            }),
                    ),
            );
        }
    }
    snippets = snippets
        .child(row(
            "Insert mode",
            div().flex().gap_1().children(insert_modes),
            chrome,
        ))
        .child(row(
            "Placeholder navigation",
            toggle("placeholders", p.snippet_placeholders, chrome, |s, v| {
                s.productivity.snippet_placeholders = v
            }),
            chrome,
        ));

    let clipboard = titled("Clipboard and bookmarks", chrome)
        .child(row(
            "Clipboard history",
            toggle(
                "clipboard-history",
                p.clipboard_history_enabled,
                chrome,
                |s, v| s.productivity.clipboard_history_enabled = v,
            ),
            chrome,
        ))
        .child(row(
            "Maximum items",
            stepper(
                "clipboard-max",
                p.clipboard_history_max.to_string(),
                chrome,
                |s, d| {
                    let step = 10 * d as i64;
                    let v = s.productivity.clipboard_history_max as i64 + step;
                    s.productivity.clipboard_history_max = v.clamp(1, 1000) as usize;
                },
            ),
            chrome,
        ))
        .child(row(
            "Bookmarks",
            toggle("bookmarks", p.bookmarks_enabled, chrome, |s, v| {
                s.productivity.bookmarks_enabled = v
            }),
            chrome,
        ))
        .child(row(
            "Maximum per tab",
            stepper(
                "bookmarks-max",
                p.max_bookmarks_per_tab.to_string(),
                chrome,
                |s, d| {
                    let v = s.productivity.max_bookmarks_per_tab as i64 + 5 * d as i64;
                    s.productivity.max_bookmarks_per_tab = v.clamp(1, 200) as usize;
                },
            ),
            chrome,
        ));

    let search = titled("Search", chrome)
        .child(row(
            "Semantic scrollback search",
            toggle("semantic", p.semantic_search, chrome, |s, v| {
                s.productivity.semantic_search = v
            }),
            chrome,
        ))
        .child(row(
            "Find: case sensitive by default",
            toggle("find-case", p.find_case_sensitive, chrome, |s, v| {
                s.productivity.find_case_sensitive = v
            }),
            chrome,
        ))
        .child(row(
            "Find: regular expression by default",
            toggle("find-regex", p.find_regex, chrome, |s, v| {
                s.productivity.find_regex = v
            }),
            chrome,
        ));

    div()
        .flex()
        .flex_col()
        .child(snippets)
        .child(clipboard)
        .child(search)
}
