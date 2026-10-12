//! Rendering (`ScrollbackPerfSettingsView.swift`, Performance and Rendering
//! parts): Suspend Background Rendering with its delay, and the Metal
//! renderer switch.

use gpui::{div, prelude::*};

use super::widgets::{chip, row, section as titled, stepper, toggle};
use super::{SectionContext, update};
use crate::settings::ActivePollingRateCap;

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let r = &ctx.settings.appearance.rendering;
    let caps = ActivePollingRateCap::ALL.into_iter().map(|cap| {
        chip(
            format!("refresh-{}", cap.raw()),
            cap.label(),
            r.active_polling_rate_cap == cap,
            chrome,
        )
        .on_click(move |_, _, cx| {
            update(cx, |s| s.appearance.rendering.active_polling_rate_cap = cap)
        })
    });
    let refresh = titled("Refresh Caps", chrome)
        .child(row(
            "Active Tab Refresh Cap",
            div().flex().gap_1().children(caps),
            chrome,
        ))
        .child(row(
            "Background View Refresh Cap",
            stepper(
                "inactive-refresh",
                format!("{} fps", r.inactive_view_max_fps),
                chrome,
                |s, d| {
                    let value = s.appearance.rendering.inactive_view_max_fps as i64 + d as i64;
                    s.appearance.rendering.inactive_view_max_fps = value.clamp(1, 120) as u32;
                },
            ),
            chrome,
        ));
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
        .child(refresh)
        .child(div().text_xs().text_color(chrome.text_muted).child(
            "On macOS, turning this off selects software drawing for the whole window at the next launch. \
             Font ligatures are disabled for CPU terminal drawing. Restart to change the window backend.",
        ))
}
