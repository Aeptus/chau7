//! Text Editor (`EditorSettingsView.swift`): font size, indentation,
//! display, editing assistance and theme of the built-in editor pane, and
//! Reset Editor to Defaults. Unlike Swift, where nothing reads these values,
//! the editor pane applies them.

use chau7_next_core::editor::config::{EditorConfig, EditorTheme, FONT_SIZE_RANGE, TAB_SIZE_RANGE};
use gpui::{div, prelude::*, px};

use super::SectionContext;
use super::update;
use super::widgets::{button, chip, description, row, section as titled, stepper, toggle};

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let c = &ctx.settings.editor.config;
    let font = titled("Font", chrome)
        .child(row(
            "Font Size",
            stepper(
                "editor-font-size",
                format!("{} pt", c.font_size),
                chrome,
                |s, d| {
                    let c = &mut s.editor.config;
                    c.font_size = (c.font_size as i64 + d as i64)
                        .clamp(FONT_SIZE_RANGE.0 as i64, FONT_SIZE_RANGE.1 as i64)
                        as u32;
                },
            ),
            chrome,
        ))
        .child(description("Editor font size in points (8-36)", chrome));
    let indentation = titled("Indentation", chrome)
        .child(row(
            "Tab Size",
            stepper(
                "editor-tab-size",
                format!("{} spaces", c.tab_size),
                chrome,
                |s, d| {
                    let c = &mut s.editor.config;
                    c.tab_size = (c.tab_size as i64 + d as i64)
                        .clamp(TAB_SIZE_RANGE.0 as i64, TAB_SIZE_RANGE.1 as i64)
                        as u32;
                },
            ),
            chrome,
        ))
        .child(description(
            "Number of spaces per indentation level (2, 4, or 8)",
            chrome,
        ))
        .child(row(
            "Use Spaces for Tabs",
            toggle("editor-spaces", c.use_spaces_for_tabs, chrome, |s, v| {
                s.editor.config.use_spaces_for_tabs = v
            }),
            chrome,
        ))
        .child(description(
            "Insert spaces instead of tab characters when pressing Tab",
            chrome,
        ))
        .child(row(
            "Auto-Indent",
            toggle("editor-auto-indent", c.auto_indent, chrome, |s, v| {
                s.editor.config.auto_indent = v
            }),
            chrome,
        ))
        .child(description(
            "Automatically match indentation of the previous line on Enter",
            chrome,
        ));
    let display = titled("Display", chrome)
        .child(row(
            "Word Wrap",
            toggle("editor-wrap", c.word_wrap, chrome, |s, v| {
                s.editor.config.word_wrap = v
            }),
            chrome,
        ))
        .child(description(
            "Wrap long lines to fit the editor width",
            chrome,
        ))
        .child(row(
            "Line Numbers",
            toggle(
                "editor-line-numbers",
                c.show_line_numbers,
                chrome,
                |s, v| s.editor.config.show_line_numbers = v,
            ),
            chrome,
        ))
        .child(description(
            "Show line numbers in the editor gutter",
            chrome,
        ))
        .child(row(
            "Highlight Current Line",
            toggle(
                "editor-current-line",
                c.highlight_current_line,
                chrome,
                |s, v| s.editor.config.highlight_current_line = v,
            ),
            chrome,
        ))
        .child(description(
            "Visually highlight the line where the cursor is positioned",
            chrome,
        ))
        .child(row(
            "Minimap",
            toggle("editor-minimap", c.show_minimap, chrome, |s, v| {
                s.editor.config.show_minimap = v
            }),
            chrome,
        ))
        .child(description(
            "Show a minimap overview of the file on the right side",
            chrome,
        ));
    let assistance = titled("Editing Assistance", chrome)
        .child(row(
            "Bracket Matching",
            toggle("editor-brackets", c.bracket_matching, chrome, |s, v| {
                s.editor.config.bracket_matching = v
            }),
            chrome,
        ))
        .child(description(
            "Highlight matching brackets, parentheses, and braces",
            chrome,
        ));
    let mut themes = div().flex().flex_wrap().gap_1().max_w(px(340.0));
    for theme in EditorTheme::ALL {
        themes = themes.child(
            chip(
                ("editor-theme", theme as usize),
                theme.label(),
                c.theme == theme,
                chrome,
            )
            .cursor_pointer()
            .on_click(move |_, _, cx| update(cx, |s| s.editor.config.theme = theme)),
        );
    }
    let theme = titled("Theme", chrome)
        .child(row("Editor Theme", themes, chrome))
        .child(description(
            "Choose a color theme for the editor syntax highlighting",
            chrome,
        ));
    let reset = div().flex().justify_end().child(
        button("editor-reset", "Reset Editor to Defaults", chrome)
            .on_click(|_, _, cx| update(cx, |s| s.editor.config = EditorConfig::default())),
    );
    div()
        .flex()
        .flex_col()
        .child(font)
        .child(indentation)
        .child(display)
        .child(assistance)
        .child(theme)
        .child(reset)
}
