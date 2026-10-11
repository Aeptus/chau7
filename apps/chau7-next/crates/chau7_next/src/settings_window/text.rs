//! Text (`FontColorsSettingsView.swift`, Font part): font family picker
//! (each name in its own typeface), custom font with live validation, size,
//! default zoom, weight, ligatures, a preview line; cursor shape, blink,
//! blink rate and color; padding.

use chau7_next_core::font_catalog;
use gpui::{SharedString, div, prelude::*, px};
use gpui_kit::component::input::Input;

use super::SectionContext;
use super::update;
use super::widgets::{chip, row, section as titled, stepper, toggle};
use crate::settings::CursorShape;

/// `None` while the field is empty, else whether the font is installed.
pub(super) fn validate_font(family: &str, installed: &[String]) -> Option<bool> {
    let family = family.trim();
    (!family.is_empty()).then(|| font_catalog::is_installed(family, installed))
}

/// NSFontManager weight names.
fn weight_name(weight: i32) -> &'static str {
    match weight {
        0..=2 => "Ultralight",
        3 => "Thin",
        4 => "Light",
        5 => "Regular",
        6 => "Medium",
        7 | 8 => "Semibold",
        9 => "Bold",
        10 | 11 => "Heavy",
        _ => "Black",
    }
}

/// Cursor color choices: the scheme's, then common terminal colors.
const CURSOR_COLORS: &[(&str, &str)] = &[
    ("Scheme", ""),
    ("White", "#FFFFFF"),
    ("Green", "#00FF00"),
    ("Amber", "#FFB000"),
    ("Red", "#FF5555"),
    ("Blue", "#4C9AFF"),
    ("Pink", "#FF79C6"),
];

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let s = &ctx.settings.appearance;
    let view = ctx.view;

    let fonts = font_catalog::available_fonts(
        &view.installed_fonts,
        &s.custom_font_family,
        cfg!(target_os = "macos"),
    );
    let picker = div()
        .id("font-picker")
        .w(px(240.0))
        .h(px(150.0))
        .overflow_y_scroll()
        .rounded_md()
        .border_1()
        .border_color(chrome.border)
        .bg(chrome.tab_bg)
        .children(fonts.into_iter().enumerate().map(|(i, family)| {
            let active = family.eq_ignore_ascii_case(&s.font_family);
            let name = family.clone();
            div()
                .id(("font", i))
                .px_2()
                .py_0p5()
                .text_sm()
                .font_family(SharedString::from(family.clone()))
                .when(active, |d| d.bg(chrome.accent.opacity(0.25)))
                .hover(|d| d.bg(chrome.tab_hover_bg))
                .child(family)
                .on_click(move |_, _, cx| {
                    let name = name.clone();
                    update(cx, |s| s.appearance.font_family = name)
                })
        }));

    let validity = view.custom_font_valid.map(|valid| {
        div()
            .text_sm()
            .text_color(if valid {
                gpui::hsla(0.36, 0.7, 0.45, 1.0)
            } else {
                chrome.danger
            })
            .child(if valid {
                "✓ Font found, press Enter to apply"
            } else {
                "✗ Font not found on this system"
            })
    });

    let cursor = [
        ("Block", CursorShape::Block),
        ("Bar", CursorShape::Bar),
        ("Underline", CursorShape::Underline),
    ]
    .into_iter()
    .map(|(label, shape)| {
        let active = s.cursor_shape == shape;
        chip(
            SharedString::from(format!("cursor-{label}")),
            label,
            active,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.appearance.cursor_shape = shape.clone()))
    });
    let cursor_colors = CURSOR_COLORS.iter().map(|(label, hex)| {
        let active = s.cursor_color.eq_ignore_ascii_case(hex);
        chip(
            SharedString::from(format!("cursor-color-{label}")),
            *label,
            active,
            chrome,
        )
        .when(!hex.is_empty(), |d| {
            d.child(
                div()
                    .ml_1()
                    .size(px(8.0))
                    .rounded_full()
                    .bg(crate::terminal::paint::cursor_color(s.color_scheme, hex)),
            )
            .flex()
            .items_center()
        })
        .on_click(move |_, _, cx| update(cx, |s| s.appearance.cursor_color = hex.to_string()))
    });

    titled("Text", chrome)
        .child(row("Font", picker, chrome))
        .child(row(
            "Custom font",
            div()
                .flex()
                .flex_col()
                .items_end()
                .gap_1()
                .child(div().w(px(240.0)).child(Input::new(&view.font_input)))
                .children(validity),
            chrome,
        ))
        .child(row(
            "Size",
            stepper(
                "font-size",
                format!("{:.0} pt", s.font_size),
                chrome,
                |s, d| {
                    s.appearance.font_size = (s.appearance.font_size + d as f32).clamp(6.0, 72.0)
                },
            ),
            chrome,
        ))
        .child(row(
            "Default zoom",
            stepper(
                "zoom",
                format!("{}%", s.default_zoom_percent),
                chrome,
                |s, d| {
                    s.appearance.default_zoom_percent =
                        (s.appearance.default_zoom_percent as i32 + 5 * d).clamp(50, 200) as u32
                },
            ),
            chrome,
        ))
        .child(row(
            "Weight",
            stepper(
                "weight",
                weight_name(s.font_weight).to_string(),
                chrome,
                |s, d| s.appearance.font_weight = (s.appearance.font_weight + d).clamp(0, 14),
            ),
            chrome,
        ))
        .child(row(
            "Font ligatures",
            toggle("ligatures", s.ligatures, chrome, |s, v| {
                s.appearance.ligatures = v
            }),
            chrome,
        ))
        .child(
            div()
                .py_1()
                .text_size(px(s.zoomed_font_size()))
                .font_family(SharedString::from(s.font_family.clone()))
                .child(crate::l10n::tr(
                    "The quick brown fox jumps over the lazy dog  -> => != ===",
                )),
        )
        .child(row("Cursor", div().flex().gap_1().children(cursor), chrome))
        .child(row(
            "Cursor color",
            div()
                .flex()
                .flex_wrap()
                .justify_end()
                .max_w(px(340.0))
                .gap_1()
                .children(cursor_colors),
            chrome,
        ))
        .child(row(
            "Blinking cursor",
            toggle("blink", s.cursor_blink, chrome, |s, v| {
                s.appearance.cursor_blink = v
            }),
            chrome,
        ))
        .child(row(
            "Blink rate",
            stepper(
                "blink-rate",
                format!("{:.1} s", s.blink_interval().as_secs_f32()),
                chrome,
                |s, d| {
                    let rate = s.appearance.cursor_blink_rate.unwrap_or(0.5) + 0.1 * d as f32;
                    s.appearance.cursor_blink_rate =
                        Some((rate * 10.0).round() / 10.0).map(|r: f32| r.clamp(0.3, 2.0));
                },
            ),
            chrome,
        ))
        .child(row(
            "Padding",
            stepper("padding", format!("{:.0} px", s.padding), chrome, |s, d| {
                s.appearance.padding = (s.appearance.padding + 2.0 * d as f32).clamp(0.0, 40.0)
            }),
            chrome,
        ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_custom_fonts() {
        let installed = vec!["Menlo".to_string()];
        assert_eq!(validate_font("", &installed), None);
        assert_eq!(validate_font("menlo", &installed), Some(true));
        assert_eq!(validate_font("Nope", &installed), Some(false));
    }

    #[test]
    fn weight_names() {
        assert_eq!(weight_name(5), "Regular");
        assert_eq!(weight_name(9), "Bold");
        assert_eq!(weight_name(14), "Black");
    }
}
