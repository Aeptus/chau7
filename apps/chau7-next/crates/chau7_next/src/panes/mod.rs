//! The non-terminal panes of a tab's split tree (`SplitPanes/` in the Swift
//! app): the text editor (with markdown runbooks), the file preview and the
//! diff viewer. Each is an entity the tree in `crate::pane` holds next to
//! terminal views; they talk to the tree through [`SidePaneEvent`].
//!
//! Text is shown with the gpui-kit code editor (`EditorState`): editing,
//! undo, selection, the find bar (Cmd+F), line numbers and wrapping come
//! from it; colors come from `highlight.rs` and the editor settings
//! (`settings/editor.rs`).

pub mod changed_files;
pub mod diff;
pub mod editor;
pub mod highlight;
pub mod preview;
pub mod repository;
mod runbook;
mod style_override;

use gpui::{
    App, Div, ElementId, FontWeight, Hsla, SharedString, Stateful, Window, div, prelude::*, px,
};
use gpui_kit::base::input::{DiagnosticColors, InputEditorStyle};
use gpui_kit::component::{Icon, IconName};

use crate::settings::Settings;
use crate::theme::Chrome;
use highlight::Palette;

pub use diff::DiffPane;
pub use editor::EditorPane;
pub use preview::PreviewPane;
pub use repository::RepositoryPane;

/// Key bindings of the panes. On macOS the View > Panes shortcuts are in
/// `actions/keymap.rs` (Swift's); elsewhere Cmd+Opt becomes Ctrl+Shift+Alt.
pub fn bind_keys(cx: &mut App) {
    editor::bind_keys(cx);
    repository::bind_keys(cx);
    if !cfg!(target_os = "macos") {
        use crate::actions::{
            AppendSelectionToEditor, DataExplorer, OpenDiffViewer, OpenFilePreview, OpenTextEditor,
            ShowChangedFiles,
        };
        use gpui::KeyBinding;
        cx.bind_keys([
            KeyBinding::new("ctrl-shift-alt-e", OpenTextEditor, Some("Workspace")),
            KeyBinding::new("ctrl-shift-alt-o", OpenFilePreview, Some("Workspace")),
            KeyBinding::new("ctrl-shift-alt-d", OpenDiffViewer, Some("Workspace")),
            KeyBinding::new(
                "ctrl-shift-alt-a",
                AppendSelectionToEditor,
                Some("Workspace"),
            ),
            KeyBinding::new("ctrl-shift-alt-x", DataExplorer, None),
            KeyBinding::new("ctrl-shift-alt-g", ShowChangedFiles, Some("Workspace")),
        ]);
    }
}

/// What a side pane asks of the tree that holds it.
#[derive(Debug, Clone)]
pub enum SidePaneEvent {
    /// Clicked or focused: becomes the tree's focused pane.
    Focused,
    /// Close this pane (after any save prompt).
    Close,
    /// Type text into the tab's first terminal (runbook Run, Run All).
    RunCommand(String),
    OpenDiff {
        file: String,
        directory: std::path::PathBuf,
        staged: bool,
    },
    PreviewFile(std::path::PathBuf),
    /// The shown file or its state changed (saved layout, titles).
    Changed,
}

/// The palette of the editor theme setting for the current window chrome.
pub fn palette(cx: &App) -> Palette {
    Palette {
        theme: Settings::get(cx).editor.config.theme,
        dark: Chrome::get(cx).is_dark,
    }
}

/// Background of a pane's text area: the editor theme, or for Default the
/// terminal background so the pane matches the tab.
pub fn text_background(palette: Palette, cx: &App) -> Hsla {
    use chau7_next_core::editor::config::EditorTheme;
    match palette.theme {
        EditorTheme::Default => Chrome::get(cx).terminal_bg,
        theme => highlight::rgb(theme.colors(palette.dark).background),
    }
}

/// Editor colors for a pane (`InputEditorStyle`), from the editor theme.
pub fn editor_style(palette: Palette, highlight_line: bool, cx: &App) -> InputEditorStyle {
    let colors = palette.theme.colors(palette.dark);
    let chrome = Chrome::get(cx);
    let background = text_background(palette, cx);
    let gutter = match palette.theme {
        chau7_next_core::editor::config::EditorTheme::Default => chrome.tab_bg,
        _ => highlight::rgb(colors.gutter),
    };
    InputEditorStyle {
        foreground: palette.foreground(),
        muted_foreground: highlight::rgb(colors.line_number),
        background,
        border: chrome.border,
        selection: chrome.accent.opacity(0.35),
        // "Highlight Current Line" also gives the caret the accent color in
        // Swift (`insertionPointColor`).
        caret: if highlight_line {
            chrome.accent
        } else {
            palette.foreground()
        },
        diagnostics: DiagnosticColors::default(),
        highlight_styles: std::sync::Arc::new(NoStyles),
        editor_invisible: None,
        editor_active_line: highlight_line.then(|| {
            if colors.dark {
                gpui::hsla(0.0, 0.0, 1.0, 0.06)
            } else {
                gpui::hsla(0.6, 0.5, 0.5, 0.08)
            }
        }),
        editor_gutter_background: Some(gutter),
        fold_icon_renderer: None,
    }
}

struct NoStyles;
impl gpui_kit::base::input::HighlightStyleResolver for NoStyles {
    fn style(&self, _: &str) -> Option<gpui::HighlightStyle> {
        None
    }
}

/// The monospaced family of the terminal font (first installed one).
pub fn mono_family(window: &Window, cx: &App) -> SharedString {
    crate::terminal::paint::terminal_font(Settings::get(cx), window).family
}

/// Header bar of a side pane (`.controlBackgroundColor`, 11 pt).
pub fn header(chrome: Chrome) -> Div {
    div()
        .flex()
        .flex_none()
        .overflow_hidden()
        .items_center()
        .gap_2()
        .h(px(26.0))
        .px_2()
        .bg(chrome.tab_bg)
        .border_b_1()
        .border_color(chrome.border)
        .text_size(px(11.0))
        .text_color(chrome.text)
}

/// A small header button with a tooltip-like label.
pub fn header_button(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    chrome: Chrome,
    enabled: bool,
) -> Stateful<Div> {
    div()
        .flex_none()
        .id(id.into())
        .px_1()
        .py(px(1.0))
        .rounded_sm()
        .text_size(px(11.0))
        .text_color(if enabled {
            chrome.text_muted
        } else {
            chrome.text_muted.opacity(0.4)
        })
        .when(enabled, |d| {
            d.cursor_pointer()
                .hover(|d| d.bg(chrome.tab_hover_bg).text_color(chrome.text))
        })
        .child(label.into())
}

/// Centered message for empty, loading and error states.
pub fn placeholder(
    icon: IconName,
    color: Option<Hsla>,
    title: impl Into<SharedString>,
    detail: Option<SharedString>,
    chrome: Chrome,
) -> Div {
    div()
        .size_full()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .gap_2()
        .text_color(chrome.text_muted)
        .child(
            Icon::new(icon)
                .size(px(22.0))
                .text_color(color.unwrap_or(chrome.text_muted)),
        )
        .child(div().text_size(px(12.0)).child(title.into()))
        .children(detail.map(|d| div().text_size(px(11.0)).opacity(0.7).child(d)))
}

/// Spinner shown while a file loads (`ProgressView`).
pub fn loading(chrome: Chrome) -> Div {
    div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .text_color(chrome.text_muted)
        .text_size(px(12.0))
        .font_weight(FontWeight::MEDIUM)
        .child(crate::l10n::tr("Loading…"))
}
