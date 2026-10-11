//! Rendering (`ScrollbackPerfSettingsView.swift`, Performance and Rendering
//! parts): Suspend Background Rendering with its delay, and the Metal
//! renderer switch.

use gpui::{div, prelude::*};

use super::SectionContext;
use super::widgets::{row, section as titled, stepper, toggle};

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let r = &ctx.settings.appearance.rendering;
    titled("Rendering", chrome)
        .child(row(
            "Suspend background rendering",
            toggle("suspend", r.suspend_background, chrome, |s, v| {
                s.appearance.rendering.suspend_background = v
            }),
            chrome,
        ))
        .when(r.suspend_background, |section| {
            section.child(row(
                "Suspend delay",
                stepper(
                    "suspend-delay",
                    format!("{:.0} s", r.suspend_delay_secs),
                    chrome,
                    |s, d| {
                        let r = &mut s.appearance.rendering;
                        r.suspend_delay_secs = (r.suspend_delay_secs + d as f32).clamp(0.0, 600.0)
                    },
                ),
                chrome,
            ))
        })
        .child(row(
            "Metal renderer",
            toggle("metal", r.gpu_renderer, chrome, |s, v| {
                s.appearance.rendering.gpu_renderer = v
            }),
            chrome,
        ))
        .child(div().text_xs().text_color(chrome.text_muted).child(
            "Turning this off draws the terminal text, backgrounds and images on the CPU. \
             Font ligatures are disabled. The window still uses GPU composition.",
        ))
}
