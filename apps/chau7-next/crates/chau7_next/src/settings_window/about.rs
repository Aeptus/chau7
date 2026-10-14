//! About (`AboutSettingsView.swift`) and the About window of the app menu
//! (`AppDelegate.showAbout`, the standard About panel in Swift).

use chau7_next_core::app_shell::{architecture_label, version_label};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, Global, Render, SharedString, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;

use super::SectionContext;
use super::widgets::{button, description, info_row, section as titled};
use crate::platform::system;
use crate::theme::{Chrome, panel_titlebar};
use crate::workspace::AppData;

const GITHUB: &str = "https://github.com/Aeptus/chau7";

/// "1.2 (45)" from the bundle, else the crate version for a development build.
pub(crate) fn version_text() -> String {
    let short = system::bundle_string("CFBundleShortVersionString");
    let build = system::bundle_string("CFBundleVersion");
    if short.is_none() && build.is_none() {
        format!("{} (development build)", env!("CARGO_PKG_VERSION"))
    } else {
        version_label(short.as_deref(), build.as_deref())
    }
}

/// When the executable was built (its modification time), like Swift.
fn build_date() -> String {
    let modified = std::env::current_exe()
        .ok()
        .and_then(|exe| std::fs::metadata(exe).ok())
        .and_then(|m| m.modified().ok());
    match modified {
        Some(time) => {
            let seconds = time
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            format_utc(seconds)
        }
        None => "Unknown".to_string(),
    }
}

/// "2025-03-14 09:30 UTC".
fn format_utc(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02} UTC",
        rest / 3600,
        rest % 3600 / 60
    )
}

fn link(
    id: &'static str,
    label: &'static str,
    url: &'static str,
    chrome: Chrome,
) -> gpui::Stateful<gpui::Div> {
    button(id, label, chrome).on_click(move |_, _, cx| cx.open_url(url))
}

fn support_info(root: &chau7_next_core::data_root::DataRoot) -> String {
    [
        format!("Chau7 Next {}", version_text()),
        "Application: Chau7 Next".to_string(),
        format!(
            "Bundle ID: {}",
            system::bundle_string("CFBundleIdentifier").unwrap_or_else(|| "Not bundled".into())
        ),
        format!("Built: {}", build_date()),
        format!("Operating system: {}", system::os_version()),
        format!(
            "Architecture: {}",
            architecture_label(std::env::consts::ARCH)
        ),
        format!("Log: {}", crate::log_file_path(root).display()),
    ]
    .join("\n")
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let bundle_id = system::bundle_string("CFBundleIdentifier").unwrap_or("Not bundled".into());
    let log_path = crate::log_file_path(ctx.root);
    let reveal = log_path.clone();

    let header = div()
        .flex()
        .flex_col()
        .gap_1()
        .pb_4()
        .child(
            div()
                .text_xl()
                .font_weight(gpui::FontWeight::BOLD)
                .child(crate::l10n::tr("Chau7 Next")),
        )
        .child(description(
            "A terminal for AI-assisted development",
            chrome,
        ))
        .child(description(version_text(), chrome));

    let version = titled("Version Information", chrome)
        .child(info_row("Application", "Chau7 Next", chrome))
        .child(info_row("Bundle ID", bundle_id, chrome))
        .child(info_row("Version", version_text(), chrome))
        .child(info_row("Built", build_date(), chrome));

    let system_info = titled("System Information", chrome)
        .child(info_row("Operating system", system::os_version(), chrome))
        .child(info_row(
            "Architecture",
            architecture_label(std::env::consts::ARCH),
            chrome,
        ))
        .child(info_row(
            "Shell",
            std::env::var("SHELL").unwrap_or_else(|_| "Unknown".into()),
            chrome,
        ));

    let links = titled("Links", chrome).child(
        div()
            .flex()
            .gap_2()
            .child(link("link-github", "GitHub", GITHUB, chrome))
            .child(link(
                "link-issues",
                "Report Issue",
                "https://github.com/Aeptus/chau7/issues",
                chrome,
            ))
            .child(link(
                "link-docs",
                "Documentation",
                "https://github.com/Aeptus/chau7/blob/main/README.md",
                chrome,
            )),
    );

    let log = titled("Application Log", chrome)
        .child(info_row(
            "Log Path",
            SharedString::from(log_path.to_string_lossy().into_owned()),
            chrome,
        ))
        .child(
            div()
                .flex()
                .gap_2()
                .child(super::anchors::target(
                    "aboutSupportInfo",
                    button("copy-support-info", "Copy Support Info", chrome).on_click(
                        |_, _, cx| {
                            let root = &cx.global::<AppData>().root;
                            let text = support_info(root);
                            cx.write_to_clipboard(gpui::ClipboardItem::new_string(text));
                            super::set_message(cx, "Support info copied.".into(), false);
                        },
                    ),
                ))
                .child(
                    button("log-reveal", "Reveal in Finder", chrome)
                        .on_click(move |_, _, cx| cx.reveal_path(&reveal)),
                )
                .child(
                    button("log-console", "Diagnostics", chrome).on_click(|_, _, cx| {
                        crate::debug::open_console(Some(crate::debug::Tab::Health), cx)
                    }),
                ),
        );

    let thanks = titled("Acknowledgments", chrome)
        .child(description(
            "Chau7 Next is written in Rust on GPUI. Open-source acknowledgments and third-party notices are listed in Help > Technology, Licenses & Acknowledgments.",
            chrome,
        ))
        .child(
            div().flex().child(
                button("open-acks", "Open Acknowledgments", chrome).on_click(|_, window, cx| {
                    window.dispatch_action(Box::new(crate::actions::ShowTechnologyLicenses), cx)
                }),
            ),
        )
        .child(description("Copyright © 2024-2026 Aeptus. Licensed under AGPL 3.0.", chrome));

    div()
        .flex()
        .flex_col()
        .child(header)
        .child(version)
        .child(system_info)
        .child(links)
        .child(log)
        .child(thanks)
}

// ----- About window ---------------------------------------------------------

#[derive(Default)]
struct AboutWindowHandle(Option<AnyWindowHandle>);
impl Global for AboutWindowHandle {}

/// App menu > About Chau7 Next: a small window with the name, version and
/// credits (the standard About panel in Swift).
pub fn open_about(cx: &mut App) {
    if let Some(handle) = cx.try_global::<AboutWindowHandle>().and_then(|h| h.0)
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        return;
    }
    let bounds = Bounds::centered(None, size(px(360.0), px(380.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(300.0), px(300.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |_, cx| cx.new(|_| AboutView)) {
        Ok((handle, _)) => cx.set_global(AboutWindowHandle(Some(handle))),
        Err(err) => log::error!("about window: {err}"),
    }
    cx.activate(true);
}

struct AboutView;

const CREDITS: &str = "A modern terminal emulator designed for AI-assisted development.\n\n\
Features:\n- AI CLI detection (Claude, Codex, Gemini)\n- Command palette\n- Split panes\n- Snippets and more\n\n\
Built with Rust and GPUI.\n\nCopyright © 2024-2026";

impl Render for AboutView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(&crate::l10n::tr("About Chau7 Next"));
        let chrome = Chrome::get(cx);
        let log = crate::log_file_path(&cx.global::<AppData>().root);
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(panel_titlebar(chrome).child(div().text_sm().child(crate::l10n::tr("About"))))
            .child(
                div()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap_2()
                    .p_6()
                    .child(
                        div()
                            .text_2xl()
                            .font_weight(gpui::FontWeight::BOLD)
                            .child(crate::l10n::tr("Chau7 Next")),
                    )
                    .child(description(format!("Version {}", version_text()), chrome))
                    .child(
                        div()
                            .pt_3()
                            .text_xs()
                            .text_color(chrome.text_muted)
                            .child(CREDITS),
                    )
                    .child(
                        div()
                            .pt_3()
                            .flex()
                            .gap_2()
                            .child(link("about-github", "GitHub", GITHUB, chrome))
                            .child(
                                button("about-log", "Show Log", chrome)
                                    .on_click(move |_, _, cx| cx.reveal_path(&log)),
                            ),
                    ),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_utc_dates() {
        assert_eq!(format_utc(0), "1970-01-01 00:00 UTC");
        assert_eq!(format_utc(1_741_944_600), "2025-03-14 09:30 UTC");
        assert_eq!(format_utc(951_782_400 + 3600), "2000-02-29 01:00 UTC");
    }
}
