//! Current Windows page, sharing the existing theme/opacity and native window machinery.
use super::{
    SectionContext, anchors, update,
    widgets::{button, description, row, section as titled, toggle},
};
use gpui::{div, prelude::*};
pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    div().flex().flex_col().gap_4()
        .child(super::colors::windows(ctx))
        .child(titled("Window Behavior",chrome)
            .child(anchors::target("menuBarOnlyMode",row("Menu Bar Only Mode",toggle("menu-bar-only",ctx.settings.appearance.menu_bar_only,chrome,|s,v|s.appearance.menu_bar_only=v),chrome)))
            .child(description("Run Chau7 Next from the menu bar without a Dock icon. Takes effect after restarting Chau7 Next.",chrome))
            .child(anchors::target("fullscreenToolbar",row("Always Show Toolbar in Fullscreen",toggle("fullscreen-toolbar",ctx.settings.tabs.always_show_toolbar_in_fullscreen,chrome,|s,v|s.tabs.always_show_toolbar_in_fullscreen=v),chrome)))
            .child(anchors::target("windowBlur",row("Window Blur",toggle("window-blur",ctx.settings.appearance.window_blur_enabled,chrome,|s,v|s.appearance.window_blur_enabled=v),chrome)))
            .child(description("Blur the desktop behind terminal windows. Disable to reduce graphics memory usage.",chrome)))
        .child(anchors::target("overlayWindow",titled("Overlay Window",chrome).child(div().flex().gap_2()
            .child(button("window-show-overlay","Show Overlay",chrome).on_click(|_,_,cx|crate::app_actions::show_overlay(cx)))
            .child(button("window-reset-position","Reset Position",chrome).on_click(|_,_,cx|super::general::reset_window_positions(cx))))))
        .child(anchors::target("splitPanes",super::panes::splits(ctx)))
        .child(button("windows-reset","Reset Windows to Defaults",chrome).on_click(|_,_,cx|{
            update(cx,|s|s.reset_section(chau7_next_core::settings_search::SettingsSection::Windows));
            super::general::reset_window_positions(cx);
        }))
}
