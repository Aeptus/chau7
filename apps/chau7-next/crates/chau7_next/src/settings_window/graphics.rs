//! Graphics (`GraphicsSettingsView.swift`): Sixel and Kitty image protocols,
//! the Kitty image cache size, protocol information with test commands, and
//! (dev) a test image copied to the clipboard.

use gpui::{ClipboardItem, IntoElement, div, prelude::*, px};

use super::SectionContext;
use super::widgets::{row, section as titled, stepper, toggle};
use crate::theme::Chrome;

fn protocol_row(
    name: &'static str,
    detail: &'static str,
    enabled: bool,
    status: &'static str,
    chrome: Chrome,
) -> impl IntoElement {
    let green = gpui::hsla(0.36, 0.65, 0.45, 1.0);
    div()
        .flex()
        .items_center()
        .gap_2()
        .text_sm()
        .child(div().size(px(8.0)).rounded_full().bg(if enabled {
            green
        } else {
            chrome.text_muted
        }))
        .child(div().flex_1().child(name))
        .child(
            div()
                .text_xs()
                .font_family("monospace")
                .text_color(chrome.text_muted)
                .child(detail),
        )
        .child(
            div()
                .w(px(90.0))
                .text_right()
                .text_xs()
                .text_color(if enabled { green } else { chrome.text_muted })
                .child(status),
        )
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let a = &ctx.settings.appearance;
    let g = &a.graphics;
    let on_off = |on: bool| if on { "Enabled" } else { "Disabled" };
    let entity = ctx.view.entity.clone();
    let feedback = ctx.view.graphics_feedback;
    titled("Graphics", chrome)
        .child(row(
            "Sixel protocol",
            toggle("sixel", g.sixel, chrome, |s, v| {
                s.appearance.graphics.sixel = v
            }),
            chrome,
        ))
        .child(row(
            "Kitty graphics",
            toggle("kitty", g.kitty, chrome, |s, v| {
                s.appearance.graphics.kitty = v
            }),
            chrome,
        ))
        .child(row(
            "Image cache size",
            stepper(
                "kitty-cache",
                format!("{} MB", g.kitty_cache_limit_mb),
                chrome,
                |s, d| {
                    let g = &mut s.appearance.graphics;
                    g.kitty_cache_limit_mb =
                        (g.kitty_cache_limit_mb as i32 + 64 * d).clamp(64, 1024) as u32
                },
            )
            .when(!g.kitty, |d| d.opacity(0.5)),
            chrome,
        ))
        .child(
            div()
                .p_3()
                .rounded_lg()
                .bg(chrome.tab_bg)
                .flex()
                .flex_col()
                .gap_2()
                .child(protocol_row(
                    "iTerm2 (imgcat)",
                    "ESC ] 1337 ; File = ... BEL",
                    a.display.inline_images,
                    on_off(a.display.inline_images),
                    chrome,
                ))
                .child(protocol_row(
                    "Sixel",
                    "DCS P ... ST",
                    g.sixel,
                    on_off(g.sixel),
                    chrome,
                ))
                .child(protocol_row(
                    "Kitty Graphics",
                    "APC G ... ST",
                    g.kitty,
                    on_off(g.kitty),
                    chrome,
                )),
        )
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr(
                    "Test Sixel: convert image.png sixel:- (requires ImageMagick)",
                )),
        )
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr(
                    "Test Kitty: kitty +kitten icat image.png (requires Kitty tools)",
                )),
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap_3()
                .child(
                    div()
                        .id("render-test-image")
                        .px_3()
                        .py_1()
                        .rounded_md()
                        .border_1()
                        .border_color(chrome.border)
                        .bg(chrome.tab_bg)
                        .hover(|d| d.bg(chrome.tab_hover_bg))
                        .text_sm()
                        .child(crate::l10n::tr("Render Test Image"))
                        .on_click(move |_, _, cx| {
                            let png = crate::terminal::images::test_image_png();
                            let image = gpui::Image::from_bytes(gpui::ImageFormat::Png, png);
                            cx.write_to_clipboard(ClipboardItem::new_image(&image));
                            log::info!("Graphics test image rendered and copied to clipboard");
                            show_feedback(entity.clone(), cx);
                        }),
                )
                .children(feedback.map(|text| {
                    div()
                        .text_xs()
                        .text_color(gpui::hsla(0.36, 0.65, 0.45, 1.0))
                        .child(text)
                })),
        )
}

/// "Test image copied to clipboard", cleared after 3 s.
fn show_feedback(entity: gpui::WeakEntity<super::SettingsView>, cx: &mut gpui::App) {
    let _ = entity.update(cx, |view, cx| {
        view.graphics_feedback = Some("Test image copied to clipboard");
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(3))
                .await;
            let _ = this.update(cx, |view, cx| {
                view.graphics_feedback = None;
                cx.notify();
            });
        })
        .detach();
    });
}
