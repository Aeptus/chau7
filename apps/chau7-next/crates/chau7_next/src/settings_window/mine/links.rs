//! Links: Cmd-click paths and URLs, the browser and the editor
//! (`InputSettingsView.swift`).

use gpui::{SharedString, div, prelude::*, px};
use gpui_kit::component::input::Input;

use super::super::widgets::{chip, row, section as titled, toggle};
use super::super::{SectionContext, update};
use super::hint;
use crate::settings::UrlHandler;

pub(in super::super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let p = &ctx.settings.productivity;
    let key = if cfg!(target_os = "macos") {
        "Cmd"
    } else {
        "Ctrl"
    };
    let mut links = titled("Links", chrome).child(row(
        match key {
            "Cmd" => "Cmd+click opens paths and URLs",
            _ => "Ctrl+click opens paths and URLs",
        },
        toggle("cmd-click", p.cmd_click_paths, chrome, |s, v| {
            s.productivity.cmd_click_paths = v
        }),
        chrome,
    ));
    if p.cmd_click_paths {
        let handlers = UrlHandler::ALL.into_iter().map(|handler| {
            chip(
                SharedString::from(format!("url-{}", handler.raw())),
                handler.display_name(),
                p.url_handler == handler,
                chrome,
            )
            .on_click(move |_, _, cx| update(cx, |s| s.productivity.url_handler = handler))
        });
        links = links
            .child(row("Open links in", div().flex().flex_wrap().gap_1().max_w(px(340.0)).children(handlers), chrome))
            .child(row(
                "Default editor",
                div().w(px(200.0)).child(Input::new(&ctx.view.mine.editor)),
                chrome,
            ))
            .child(hint(
                "Empty uses $EDITOR, then the system default. Lines are passed to code, subl, vim, nvim and emacs.",
                chrome,
            ))
            .child(row(
                "Open in internal editor",
                toggle(
                    "cmd-click-internal",
                    p.cmd_click_internal_editor,
                    chrome,
                    |s, v| s.productivity.cmd_click_internal_editor = v,
                ),
                chrome,
            ))
            .child(hint(
                "On: Cmd-clicked files open in the tab's editor pane, at the clicked line. Off: in the editor above.",
                chrome,
            ));
    }
    links
}
