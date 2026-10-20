//! Per-editor Mermaid preview entities. Compilation and native rasterization stay off the UI thread.
use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use chau7_next_core::editor::mermaid::{self, Diagram, Request, Theme};
use gpui::{
    App, ClipboardItem, Context, IntoElement, Render, RenderImage, ScrollHandle, Task, Window,
    canvas, div, img, point, prelude::*, px,
};

use crate::theme::Chrome;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Zoom {
    Fit,
    Scale(f32),
}

#[derive(Clone, Copy)]
enum Action {
    Fit,
    Actual,
    In,
    Out,
    Expand,
    Source,
    Copy,
}

struct Ready {
    diagram: Arc<Diagram>,
    image: Arc<RenderImage>,
    scale: f32,
}

pub(super) struct MermaidView {
    request: Request,
    width: f32,
    zoom: Zoom,
    expanded: bool,
    source_visible: bool,
    pending: bool,
    error: Option<String>,
    ready: Option<Ready>,
    task: Option<Task<()>>,
    generation: u64,
    scroll: ScrollHandle,
}

pub(super) fn theme(chrome: Chrome, background: gpui::Hsla) -> Theme {
    fn rgb(colour: gpui::Hsla) -> [u8; 3] {
        let c = colour.to_rgb();
        [c.r, c.g, c.b].map(|v| (v.clamp(0.0, 1.0) * 255.0).round() as u8)
    }
    Theme {
        background: rgb(background),
        foreground: rgb(chrome.text),
        muted: rgb(chrome.text_muted),
        border: rgb(chrome.border),
        accent: rgb(chrome.accent),
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

impl MermaidView {
    pub(super) fn new(source: &str, theme: Theme, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            request: Request::new(source, 640.0, theme, now_ms()),
            width: 640.0,
            zoom: Zoom::Fit,
            expanded: false,
            source_visible: false,
            pending: false,
            error: None,
            ready: None,
            task: None,
            generation: 0,
            scroll: ScrollHandle::new(),
        };
        view.schedule(cx);
        view
    }

    pub(super) fn configure(&mut self, source: &str, theme: Theme, cx: &mut Context<Self>) {
        let request = Request::new(source, self.width, theme, now_ms());
        if request == self.request {
            return;
        }
        // Reusing a block position must never display the previous block or file's diagram.
        if request.source != self.request.source {
            self.ready = None;
            self.zoom = Zoom::Fit;
            self.source_visible = false;
            self.scroll.set_offset(point(px(0.0), px(0.0)));
        }
        self.request = request;
        self.schedule(cx);
    }

    fn resize(&mut self, width: f32, cx: &mut Context<Self>) {
        if !width.is_finite() || width < 96.0 {
            return;
        }
        // The key is quantized; the exact width is retained for Fit sizing.
        let request = Request::new(&self.request.source, width, self.request.theme, now_ms());
        if request == self.request && (width - self.width).abs() < 1.0 {
            return;
        }
        self.width = width;
        if request != self.request || self.zoom == Zoom::Fit {
            self.request = request;
            self.schedule(cx);
        }
    }

    fn schedule(&mut self, cx: &mut Context<Self>) {
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        let request = self.request.clone();
        let width = self.width;
        let zoom = self.zoom;
        let renderer = cx.svg_renderer();
        self.pending = true;
        self.error = None;
        // Dropping the task cancels debounced work. Already-running workers have no UI ownership.
        self.task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(120))
                .await;
            let result = cx
                .background_executor()
                .spawn(async move {
                    let diagram = mermaid::compile(&request)?;
                    let scale = match zoom {
                        Zoom::Fit => (width / diagram.width).min(1.0),
                        Zoom::Scale(scale) => scale,
                    };
                    // GPUI renders SVG at 2x. Bound both dimensions and total raster memory.
                    let raster_scale = scale
                        .min(2048.0 / diagram.width.max(diagram.height))
                        .min((2_000_000.0 / (diagram.width * diagram.height)).sqrt());
                    let image = renderer
                        .render_single_frame(diagram.svg.as_bytes(), raster_scale)
                        .map_err(|e| format!("Cannot display diagram: {e}"))?;
                    Ok::<_, String>(Ready {
                        diagram,
                        image,
                        scale,
                    })
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.finish(generation, result, cx);
            });
        }));
        cx.notify();
    }

    fn finish(&mut self, generation: u64, result: Result<Ready, String>, cx: &mut Context<Self>) {
        if self.generation != generation {
            return;
        }
        self.pending = false;
        match result {
            Ok(ready) => {
                self.ready = Some(ready);
                self.error = None;
            }
            Err(error) => {
                self.ready = None;
                self.error = Some(error);
            }
        }
        cx.notify();
    }

    fn action(&mut self, action: Action, cx: &mut Context<Self>) {
        let old_zoom = self.zoom;
        match action {
            Action::Fit => self.zoom = Zoom::Fit,
            Action::Actual => self.zoom = Zoom::Scale(1.0),
            Action::In | Action::Out => {
                let current = match self.zoom {
                    Zoom::Scale(scale) => scale,
                    Zoom::Fit => self.ready.as_ref().map_or(1.0, |r| r.scale),
                };
                let factor = if matches!(action, Action::In) {
                    1.25
                } else {
                    0.8
                };
                self.zoom = Zoom::Scale((current * factor).clamp(0.1, 4.0));
            }
            Action::Expand => self.expanded = !self.expanded,
            Action::Source => self.source_visible = !self.source_visible,
            Action::Copy => {
                if let Some(ready) = &self.ready {
                    cx.write_to_clipboard(ClipboardItem::new_string(ready.diagram.svg.clone()));
                }
            }
        }
        if old_zoom != self.zoom {
            self.scroll.set_offset(point(px(0.0), px(0.0)));
            self.schedule(cx);
        }
        cx.notify();
    }

    fn button(
        &self,
        label: &'static str,
        action: Action,
        chrome: Chrome,
        cx: &Context<Self>,
    ) -> impl IntoElement + use<> {
        div()
            .id(label)
            .px_2()
            .py_1()
            .rounded_md()
            .cursor_pointer()
            .hover(move |d| d.bg(chrome.tab_hover_bg))
            .child(crate::l10n::tr(label))
            .on_click(cx.listener(move |this, _, _, cx| this.action(action, cx)))
    }
}

impl Render for MermaidView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = Chrome::get(cx);
        let weak = cx.entity().downgrade();
        let toolbar = div()
            .flex()
            .flex_wrap()
            .items_center()
            .gap_1()
            .px_2()
            .py_1()
            .bg(chrome.tab_bg)
            .text_size(px(11.0))
            .child("Mermaid")
            .child(self.button("Fit", Action::Fit, chrome, cx))
            .child(self.button("100%", Action::Actual, chrome, cx))
            .child(self.button("−", Action::Out, chrome, cx))
            .child(self.button("+", Action::In, chrome, cx))
            .child(self.button(
                if self.expanded { "Collapse" } else { "Expand" },
                Action::Expand,
                chrome,
                cx,
            ))
            .child(self.button(
                if self.source_visible {
                    "Diagram"
                } else {
                    "Source"
                },
                Action::Source,
                chrome,
                cx,
            ))
            .when(self.ready.is_some(), |d| {
                d.child(self.button("Copy SVG", Action::Copy, chrome, cx))
            })
            .when(self.pending, |d| d.child(crate::l10n::tr("Rendering…")));
        let mut body = div()
            .id("mermaid-viewport")
            .w_full()
            .min_w_0()
            .max_h(px(if self.expanded { 900.0 } else { 400.0 }))
            .overflow_scroll()
            .track_scroll(&self.scroll);
        if self.source_visible || self.error.is_some() {
            body = body.child(
                div()
                    .p_3()
                    .font_family("Menlo")
                    .text_size(px(13.0))
                    .whitespace_nowrap()
                    .child(self.request.source.to_string()),
            );
        } else if let Some(ready) = &self.ready {
            body = body.child(
                img(ready.image.clone())
                    .flex_shrink_0()
                    .w(px(ready.diagram.width * ready.scale))
                    .h(px(ready.diagram.height * ready.scale)),
            );
        } else {
            body = body.child(div().p_3().child(crate::l10n::tr("Rendering diagram…")));
        }
        div()
            .id("mermaid-preview")
            .w_full()
            .min_w_0()
            .flex()
            .flex_col()
            .border_1()
            .border_color(chrome.border)
            .rounded_md()
            .overflow_hidden()
            .child(toolbar)
            .child(
                canvas(
                    move |bounds, window, cx| {
                        let width = f32::from(bounds.size.width);
                        let weak = weak.clone();
                        window.defer(cx, move |_, cx| {
                            let _ = weak.update(cx, |this, cx| this.resize(width, cx));
                        });
                    },
                    |_, _, _, _| {},
                )
                .w_full()
                .h(px(1.0)),
            )
            .when_some(self.error.clone(), |d, error| {
                d.child(
                    div()
                        .p_2()
                        .text_size(px(12.0))
                        .text_color(chrome.danger)
                        .child(error),
                )
            })
            .child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::TestAppContext;

    #[gpui::test]
    fn source_changes_reset_zoom_and_invalidate_pending_work(cx: &mut TestAppContext) {
        let colours = Theme {
            background: [0; 3],
            foreground: [255; 3],
            muted: [180; 3],
            border: [100; 3],
            accent: [100, 150, 255],
        };
        let view = cx.new(|cx| MermaidView::new("flowchart LR\n A --> B", colours, cx));
        view.update(cx, |view, cx| {
            let generation = view.generation;
            view.action(Action::Actual, cx);
            view.source_visible = true;
            assert!(view.generation > generation);
            view.configure("flowchart LR\n A --> C", colours, cx);
            assert_eq!(view.zoom, Zoom::Fit);
            assert!(!view.source_visible);
            assert!(view.ready.is_none());
            assert!(view.pending);
            assert!(view.generation > generation + 1);
            view.finish(generation, Err("obsolete result".into()), cx);
            assert!(view.pending);
            assert!(
                view.error.is_none(),
                "A stale completion must not replace current state"
            );
            let generation = view.generation;
            view.configure("flowchart LR\n A --> C", colours, cx);
            assert_eq!(
                view.generation, generation,
                "Unchanged input must not enqueue work"
            );
        });
    }
}
