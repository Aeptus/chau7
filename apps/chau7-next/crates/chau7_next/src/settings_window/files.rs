//! Files: open the config file, show the data folder.

use gpui::{div, prelude::*};

use super::SectionContext;
use super::widgets::{chip, section as titled};

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let dir = ctx.root.config_dir().to_path_buf();
    titled("Files", chrome).child(
        div()
            .flex()
            .gap_2()
            .child(
                chip("open-config", "Open config.toml", false, chrome).on_click(|_, window, cx| {
                    window.dispatch_action(Box::new(crate::actions::OpenConfigFile), cx)
                }),
            )
            .child(
                chip("reveal", "Show data folder", false, chrome)
                    .on_click(move |_, _, cx| cx.reveal_path(&dir)),
            ),
    )
}
