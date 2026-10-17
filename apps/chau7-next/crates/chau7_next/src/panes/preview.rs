//! File preview pane (`SplitPanes/FilePreviewPaneView.swift`,
//! `FilePreviewModel`): read-only text at the terminal font size with
//! output-style colors (EDT-001), find bar (Cmd+F) and scroll to a line, or
//! an image fitted on a checkerboard. Header: file type icon, name, IMAGE
//! badge, close.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chau7_next_core::editor::output_highlight::OutputHighlightOptions;
use chau7_next_core::editor::text as edtext;
use gpui::{
    App, Context, Entity, EventEmitter, FocusHandle, Focusable, Image, ImageFormat, ObjectFit,
    Render, StyledImage, Subscription, Task, Window, canvas, div, fill, img, point, prelude::*, px,
    size,
};
use gpui_kit::base::input::{EditorState, InputEvent};
use gpui_kit::component::input::Editor;
use gpui_kit::component::{Icon, IconName};

use super::highlight::{self, HighlightMode, Palette};
use super::{SidePaneEvent, header, header_button, loading, placeholder};
use crate::settings::Settings;
use crate::theme::Chrome;

pub struct PreviewPane {
    state: Entity<EditorState>,
    path: Option<PathBuf>,
    is_image: bool,
    loading: bool,
    error: Option<String>,
    /// File type icon of the shown file (`NSWorkspace.icon(for:)`).
    icon: Option<Arc<Image>>,
    palette: Palette,
    options: OutputHighlightOptions,
    load_token: u64,
    load_task: Option<Task<()>>,
    focus_handle: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<SidePaneEvent> for PreviewPane {}

fn output_options(cx: &App) -> OutputHighlightOptions {
    let display = &Settings::get(cx).appearance.display;
    OutputHighlightOptions {
        enabled: display.syntax_highlight,
        clickable_urls: display.clickable_urls,
    }
}

impl PreviewPane {
    /// An empty preview ("No file selected").
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let palette = super::palette(cx);
        let options = output_options(cx);
        let state = cx.new(|cx| {
            EditorState::new(window, cx)
                .language("text")
                .folding(false)
                .indent_guides(false)
                .line_number(false)
                .soft_wrap(true)
        });
        state.update(cx, |s, cx| {
            s.set_highlighter_factory(
                highlight::factory(HighlightMode::Output(options), palette),
                cx,
            )
        });
        let subscriptions = vec![cx.subscribe(&state, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Focus) {
                cx.emit(SidePaneEvent::Focused);
            }
        })];
        Self {
            state,
            path: None,
            is_image: false,
            loading: false,
            error: None,
            icon: None,
            palette,
            options,
            load_token: 0,
            load_task: None,
            focus_handle: cx.focus_handle(),
            _subscriptions: subscriptions,
        }
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    pub fn file_name(&self) -> String {
        edtext::preview_file_name(self.path.as_deref().and_then(Path::to_str))
    }

    pub fn apply_settings(&mut self, cx: &mut Context<Self>) {
        let palette = super::palette(cx);
        let options = output_options(cx);
        if palette != self.palette || options != self.options {
            self.palette = palette;
            self.options = options;
            let factory = highlight::factory(HighlightMode::Output(options), palette);
            self.state.update(cx, |s, cx| {
                s.set_highlighter_factory(factory, cx);
                s.set_highlighter("text", cx);
            });
        }
        cx.notify();
    }

    /// `loadFile(at:scrollToLine:)`: text in the background, or an image.
    pub fn load_file(
        &mut self,
        path: PathBuf,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.load_token += 1;
        let token = self.load_token;
        self.loading = true;
        self.error = None;
        cx.notify();
        let image = edtext::is_image_path(&path.to_string_lossy());
        let read_path = path.clone();
        let task = cx.background_spawn(async move {
            let bytes = std::fs::read(&read_path);
            let icon = crate::platform::workspace::file_icon_png(&read_path, 14.0);
            (bytes, icon)
        });
        self.load_task = Some(cx.spawn_in(window, async move |this, cx| {
            let (bytes, icon) = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.load_token != token {
                    return;
                }
                this.loading = false;
                match bytes {
                    Err(err) => {
                        let what = if image { "image" } else { "file" };
                        this.error = Some(format!("Failed to load {what}: {err}"));
                    }
                    Ok(_) if image => {
                        this.is_image = true;
                        this.path = Some(path.clone());
                        this.set_text(String::new(), window, cx);
                        log::info!("Loaded image preview: {}", path.display());
                    }
                    Ok(bytes) => match String::from_utf8(bytes) {
                        Ok(text) => {
                            this.is_image = false;
                            this.path = Some(path.clone());
                            this.set_text(text.clone(), window, cx);
                            if let Some(line) = line.filter(|l| *l > 0) {
                                this.scroll_to_line(&text, line, cx);
                            }
                            log::info!("Loaded file preview: {}", path.display());
                        }
                        Err(_) => {
                            this.error = Some(
                                "Failed to load file: the file is not valid UTF-8 text.".into(),
                            );
                        }
                    },
                }
                this.icon = icon.map(|png| Arc::new(Image::from_bytes(ImageFormat::Png, png)));
                cx.emit(SidePaneEvent::Changed);
                cx.notify();
            });
        }));
    }

    fn set_text(&mut self, text: String, window: &mut Window, cx: &mut Context<Self>) {
        self.state.update(cx, |s, cx| s.set_value(text, window, cx));
    }

    fn scroll_to_line(&mut self, text: &str, line: usize, cx: &mut Context<Self>) {
        let offset = edtext::line_start_offset(text, line);
        let state = self.state.clone();
        cx.spawn(async move |_, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(30))
                .await;
            state.update(cx, |s, cx| s.set_selected_range(offset..offset, cx));
        })
        .detach();
    }

    fn render_header(&self, chrome: Chrome, cx: &mut Context<Self>) -> gpui::Div {
        header(chrome)
            .child(
                Icon::new(IconName::Eye)
                    .size(px(12.0))
                    .text_color(chrome.text_muted),
            )
            .when(self.path.is_some(), |d| match &self.icon {
                Some(icon) => d.child(img(icon.clone()).size(px(14.0))),
                None => d.child(
                    Icon::new(IconName::File)
                        .size(px(12.0))
                        .text_color(chrome.text_muted),
                ),
            })
            .child(
                div()
                    .min_w_0()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .truncate()
                    .child(self.file_name()),
            )
            .when(self.is_image, |d| {
                d.child(
                    div()
                        .px_1()
                        .rounded_sm()
                        .bg(chrome.text_muted.opacity(0.15))
                        .text_size(px(9.0))
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("IMAGE")),
                )
            })
            .child(div().flex_1())
            .child(
                header_button("preview-close", "✕", chrome, true)
                    .on_click(cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Close))),
            )
    }
}

/// Image fitted in the pane on a checkerboard (`ImagePreviewContent`).
fn image_view(path: PathBuf, chrome: Chrome) -> impl IntoElement {
    let light = chrome.panel_bg;
    let dark = chrome.panel_bg.opacity(0.85);
    div()
        .id("preview-image")
        .size_full()
        .relative()
        .overflow_scroll()
        .child(
            canvas(
                |_, _, _| {},
                move |bounds, _, window, _| {
                    let tile = px(10.0);
                    let cols = (bounds.size.width / tile).ceil() as usize + 1;
                    let rows = (bounds.size.height / tile).ceil() as usize + 1;
                    window.paint_quad(fill(bounds, light));
                    for row in 0..rows {
                        for col in 0..cols {
                            if (row + col) % 2 == 1 {
                                let origin =
                                    bounds.origin + point(tile * col as f32, tile * row as f32);
                                window.paint_quad(fill(
                                    gpui::Bounds::new(origin, size(tile, tile)),
                                    dark,
                                ));
                            }
                        }
                    }
                },
            )
            .absolute()
            .inset_0(),
        )
        .child(
            div().absolute().inset_0().p_4().child(
                img(path)
                    .size_full()
                    .object_fit(ObjectFit::Contain)
                    .with_fallback(move || {
                        placeholder(
                            IconName::TriangleAlert,
                            None,
                            "Unable to decode image",
                            None,
                            chrome,
                        )
                        .into_any_element()
                    }),
            ),
        )
}

impl Focusable for PreviewPane {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        if self.path.is_some() && !self.is_image {
            self.state.read(cx).focus_handle(cx)
        } else {
            self.focus_handle.clone()
        }
    }
}

impl Render for PreviewPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::get(cx);
        let header = self.render_header(chrome, cx);
        let body = if self.loading {
            loading(chrome).into_any_element()
        } else if let Some(error) = &self.error {
            placeholder(IconName::TriangleAlert, None, error.clone(), None, chrome)
                .into_any_element()
        } else if self.is_image
            && let Some(path) = self.path.clone()
        {
            image_view(path, chrome).into_any_element()
        } else if self.path.is_none() {
            placeholder(IconName::File, None, "No file selected", None, chrome).into_any_element()
        } else {
            let style = super::editor_style(self.palette, false, cx);
            let font_size = Settings::get(cx).appearance.zoomed_font_size();
            let editor = Editor::new(&self.state)
                .appearance(false)
                .readonly(true)
                .h_full()
                .font_family(super::mono_family(window, cx))
                .text_size(px(font_size));
            div()
                .size_full()
                .bg(super::text_background(self.palette, cx))
                .child(super::style_override::with_style(
                    editor,
                    &self.state,
                    style,
                ))
                .into_any_element()
        };
        div()
            .id("preview-pane")
            .track_focus(&self.focus_handle)
            .size_full()
            .flex()
            .flex_col()
            .on_any_mouse_down(cx.listener(|_, _, _, cx| cx.emit(SidePaneEvent::Focused)))
            .child(header)
            .child(div().flex_1().min_h_0().overflow_hidden().child(body))
    }
}
