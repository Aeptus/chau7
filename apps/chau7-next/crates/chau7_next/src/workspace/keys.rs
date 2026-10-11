//! Window-level keyboard commands from the Swift menus and key monitor:
//! Use Selection for Find (Cmd+E), Export Text (Cmd+Shift+S), Keyboard
//! Shortcuts (Cmd+/) and Print (Cmd+P). Hide and Hide Others are app
//! actions (`app_actions.rs`).

use gpui::{Context, Div, Stateful, Window, prelude::*};

use super::{AppData, Workspace};
use crate::actions::{ExportText, PrintTerminal, ShowKeyboardShortcuts, UseSelectionForFind};
use crate::settings::Settings;

pub(super) fn register_key_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(cx.listener(|this, _: &UseSelectionForFind, window, cx| {
        let selection = this
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx))
            .and_then(|s| s.read(cx).selection_text());
        if let Some(text) = selection {
            this.search_for(&text, window, cx);
        }
    }))
    .on_action(cx.listener(|this, _: &ExportText, window, cx| this.export_text(window, cx)))
    .on_action(cx.listener(|this, _: &PrintTerminal, _, cx| this.print_terminal(cx)))
    .on_action(
        cx.listener(|_, _: &ShowKeyboardShortcuts, _, cx| {
            crate::settings_window::open_shortcuts(cx)
        }),
    )
}

impl Workspace {
    /// Print (Cmd+P): the visible text of the selected pane.
    fn print_terminal(&mut self, cx: &mut Context<Self>) {
        let Some(session) = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx))
        else {
            return;
        };
        let grid = &session.read(cx).grid;
        let cols = grid.cols.max(1) as usize;
        let text: Vec<String> = grid
            .cells
            .chunks(cols)
            .map(|row| {
                row.iter()
                    .map(|c| {
                        if c.character == '\0' {
                            ' '
                        } else {
                            c.character
                        }
                    })
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect();
        let appearance = &Settings::get(cx).appearance;
        if let Err(err) = crate::platform::print::print_text(
            text.join("\n").trim_end(),
            &appearance.font_family,
            appearance.font_size as f64,
        ) {
            log::warn!("print: {err}");
        }
    }

    /// Export Text: the selected pane's scrollback and screen to a file.
    fn export_text(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx))
        else {
            return;
        };
        let text = session.read(cx).buffer_text();
        let home = cx.global::<AppData>().root.home().to_path_buf();
        let path = cx.prompt_for_new_path(&home, Some("terminal-output.txt"));
        cx.spawn(async move |_, _| {
            if let Ok(Ok(Some(path))) = path.await {
                match std::fs::write(&path, text) {
                    Ok(()) => log::info!("terminal text exported to {}", path.display()),
                    Err(err) => log::error!("export terminal text: {err}"),
                }
            }
        })
        .detach();
    }
}

impl Workspace {
    /// Shortcut helper hint in the top-right corner of the terminal area
    /// (`keyboard.shortcutHelperHint`, on by default; Swift
    /// `ShortcutHelperHintView`): "Keyboard Shortcuts" and "Report Issue"
    /// with their shortcuts (Report Issue follows a customized shortcut).
    pub(super) fn render_shortcut_hint(
        &self,
        chrome: crate::theme::Chrome,
        cx: &gpui::App,
    ) -> Option<gpui::AnyElement> {
        let input = &Settings::get(cx).input;
        if !input.shortcut_helper_hint {
            return None;
        }
        let (keys, report) = if cfg!(target_os = "macos") {
            let report = input
                .shortcuts()
                .iter()
                .find(|s| s.action == "reportIssue")
                .map(|s| crate::l10n::platform(&s.display_string()))
                .unwrap_or_else(|| "\u{2325}\u{2318}I".to_string());
            ("\u{2318}/".to_string(), report)
        } else {
            ("Ctrl+Shift+/".to_string(), "Ctrl+Shift+Alt+I".to_string())
        };
        let line = |label: &'static str, keys: String, hint: &'static str| {
            gpui::div()
                .flex()
                .items_center()
                .gap_1p5()
                .id(label)
                .aria_label(format!("{label} {keys}"))
                .aria_description(hint)
                .child(
                    gpui::div()
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(chrome.text.opacity(0.92))
                        .child(label),
                )
                .child(
                    gpui::div()
                        .px_1p5()
                        .rounded_md()
                        .bg(gpui::black().opacity(0.25))
                        .text_color(chrome.text)
                        .child(keys),
                )
        };
        Some(
            gpui::div()
                .absolute()
                .top(gpui::px(10.0))
                .right(gpui::px(16.0))
                .flex()
                .flex_col()
                .items_end()
                .gap_1p5()
                .px_2p5()
                .py_2()
                .rounded_lg()
                .border_1()
                .border_color(gpui::white().opacity(0.18))
                .bg(gpui::white().opacity(0.14))
                .text_xs()
                .child(line(
                    "Keyboard Shortcuts",
                    keys,
                    "Show the keyboard shortcuts window",
                ))
                .child(line("Report Issue", report, "Open the bug report flow"))
                .into_any_element(),
        )
    }
}
