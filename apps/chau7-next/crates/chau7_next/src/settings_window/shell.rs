//! Shell and scrollback (`ShellSettingsView.swift`,
//! `ScrollbackPerfSettingsView.swift`, the default directory of
//! `GeneralSettingsView.swift` and the default zoom of
//! `FontColorsSettingsView.swift`).

use chau7_next_core::shell_env::ShellType;
use gpui::{App, Context, Entity, SharedString, Subscription, Window, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::widgets::{chip, row, section as titled, toggle};
use super::{SectionContext, SettingsView, update};
use crate::settings::{BellSound, Settings};

/// Text fields of this section.
pub(crate) struct ShellInputs {
    custom_shell: Entity<InputState>,
    startup_command: Entity<InputState>,
    default_directory: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
}

impl ShellInputs {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let settings = Settings::get(cx).clone();
        let (_, custom) = settings.terminal.effective_shell_type();
        let field = |value: String,
                     placeholder: &'static str,
                     window: &mut Window,
                     cx: &mut Context<SettingsView>| {
            cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(placeholder)
                    .default_value(value)
            })
        };
        let custom_shell = field(custom, "/path/to/shell", window, cx);
        let startup_command = field(
            settings.terminal.startup_command.clone(),
            "e.g. neofetch",
            window,
            cx,
        );
        let default_directory = field(
            settings
                .general
                .default_directory
                .clone()
                .unwrap_or_default(),
            "~",
            window,
            cx,
        );
        let on_commit = |apply: fn(&mut Settings, String)| {
            move |_: &mut SettingsView,
                  input: Entity<InputState>,
                  event: &InputEvent,
                  cx: &mut Context<SettingsView>| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    let value = input.read(cx).value().trim().to_string();
                    update(cx, |s| apply(s, value));
                }
            }
        };
        let subscriptions = vec![
            cx.subscribe(
                &custom_shell,
                on_commit(|s, v| {
                    s.terminal.shell_type = Some(ShellType::Custom);
                    s.terminal.custom_shell_path = v;
                }),
            ),
            cx.subscribe(
                &startup_command,
                on_commit(|s, v| s.terminal.startup_command = v),
            ),
            cx.subscribe(
                &default_directory,
                on_commit(|s, v| s.general.default_directory = Some(v).filter(|v| !v.is_empty())),
            ),
        ];
        Self {
            custom_shell,
            startup_command,
            default_directory,
            _subscriptions: subscriptions,
        }
    }
}

/// Folder picker for the default directory ("Choose...").
fn choose_directory(cx: &mut App) {
    let paths = cx.prompt_for_paths(gpui::PathPromptOptions {
        files: false,
        directories: true,
        multiple: false,
        prompt: Some("Choose".into()),
    });
    cx.spawn(async move |cx| {
        if let Ok(Ok(Some(paths))) = paths.await
            && let Some(path) = paths.into_iter().next()
        {
            let value = path.to_string_lossy().to_string();
            cx.update(|cx| update(cx, |s| s.general.default_directory = Some(value)));
        }
    })
    .detach();
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let t = &ctx.settings.terminal;
    let inputs = &ctx.view.shell_inputs;
    let (shell_type, _) = t.effective_shell_type();
    let shells = ShellType::ALL.into_iter().map(|kind| {
        chip(
            SharedString::from(format!("shell-{}", kind.raw_value())),
            kind.display_name(),
            shell_type == kind,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.terminal.shell_type = Some(kind)))
    });
    let bells = BellSound::ALL.into_iter().map(|sound| {
        chip(
            SharedString::from(format!("bell-{}", sound.raw_value())),
            sound.label(),
            t.bell_sound == sound,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.terminal.bell_sound = sound))
    });
    titled("Shell", chrome)
        .child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(div().text_sm().child(crate::l10n::tr("Shell")))
                .child(div().flex().flex_wrap().gap_1().children(shells)),
        )
        .when(shell_type == ShellType::Custom, |d| {
            d.child(row(
                "Custom shell path",
                div().w(px(260.0)).child(Input::new(&inputs.custom_shell)),
                chrome,
            ))
        })
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(format!("Current shell: {}", t.resolved_shell())),
        )
        .child(row(
            "Startup command",
            div()
                .w(px(260.0))
                .child(Input::new(&inputs.startup_command)),
            chrome,
        ))
        .child(row(
            "Default directory",
            div()
                .flex()
                .gap_1()
                .child(
                    div()
                        .w(px(200.0))
                        .child(Input::new(&inputs.default_directory)),
                )
                .child(
                    chip("choose-dir", "Choose...", false, chrome)
                        .on_click(|_, _, cx| choose_directory(cx)),
                ),
            chrome,
        ))
        .child(row(
            "ls colors (CLICOLOR, LSCOLORS)",
            toggle("ls-colors", t.ls_colors, chrome, |s, v| {
                s.terminal.ls_colors = v
            }),
            chrome,
        ))
        .child(row(
            "Bell",
            toggle("bell-enabled", t.bell_enabled, chrome, |s, v| {
                s.terminal.bell_enabled = v
            }),
            chrome,
        ))
        .child(row(
            "Bell sound",
            div().flex().gap_1().children(bells),
            chrome,
        ))
}

/// Scrollback stepper: 1,000 lines per step (100 below 1,000), 100 to 100,000.
pub(crate) fn scrollback_step(current: usize, delta: i32) -> usize {
    let step: i64 = if current < 1000 || (current == 1000 && delta < 0) {
        100
    } else {
        1000
    };
    (current as i64 + step * delta as i64).clamp(100, 100_000) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrollback_steps() {
        assert_eq!(scrollback_step(10_000, 1), 11_000);
        assert_eq!(scrollback_step(10_000, -1), 9_000);
        assert_eq!(scrollback_step(1_000, -1), 900);
        assert_eq!(scrollback_step(100, -1), 100);
        assert_eq!(scrollback_step(800, 1), 900);
        assert_eq!(scrollback_step(900, 1), 1000);
        assert_eq!(scrollback_step(1000, 1), 2000);
        assert_eq!(scrollback_step(100_000, 1), 100_000);
    }
}
