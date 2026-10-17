//! Display enhancements (`DisplaySettingsView.swift`): syntax highlighting,
//! clickable URLs, inline images, JSON pretty printing, line timestamps and
//! their format.

use gpui::{div, prelude::*, px};
use gpui_kit::component::input::Input;

use super::SectionContext;
use super::widgets::{row, section as titled, toggle};

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let d = &ctx.settings.appearance.display;
    titled("Display", chrome)
        .child(row(
            "Syntax highlighting",
            toggle("syntax", d.syntax_highlight, chrome, |s, v| {
                s.appearance.display.syntax_highlight = v
            }),
            chrome,
        ))
        .child(row(
            "Clickable URLs",
            toggle("urls", d.clickable_urls, chrome, |s, v| {
                s.appearance.display.clickable_urls = v
            }),
            chrome,
        ))
        .child(row(
            "Inline images (imgcat)",
            toggle("inline-images", d.inline_images, chrome, |s, v| {
                s.appearance.display.inline_images = v
            }),
            chrome,
        ))
        .child(row(
            "Pretty print JSON",
            toggle("json", d.json_pretty_print, chrome, |s, v| {
                s.appearance.display.json_pretty_print = v
            }),
            chrome,
        ))
        .child(row(
            "Line timestamps",
            toggle("timestamps", d.line_timestamps, chrome, |s, v| {
                s.appearance.display.line_timestamps = v
            }),
            chrome,
        ))
        .when(d.line_timestamps, |section| {
            section.child(row(
                "Timestamp format",
                div()
                    .w(px(150.0))
                    .child(Input::new(&ctx.view.timestamp_input)),
                chrome,
            ))
        })
}
