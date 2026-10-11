//! "SSH Connections..." window (`SSHConnectionView` in
//! `Profiles/SSHConnectionManager.swift`): saved connections on the left,
//! details or the editor on the right.

use chau7_next_core::ssh_config;
use chau7_next_core::ssh_connections::{COLOR_TAGS, SshConnection, validation_message};
use gpui::{
    AnyElement, AnyWindowHandle, App, Bounds, Context, Entity, Global, Render, SharedString,
    Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::{SshState, connect, ssh_edit};
use crate::theme::Chrome;
use crate::workspace::AppData;

/// A choice in a connection's context menu (right click on a row).
#[derive(Clone, PartialEq, Debug, gpui::Action)]
#[action(namespace = chau7_ssh, no_json)]
struct SshRowMenu {
    id: String,
    op: SshRowOp,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum SshRowOp {
    Connect,
    Edit,
    Duplicate,
    Delete,
}

#[derive(Default)]
struct ManagerWindow(Option<AnyWindowHandle>);
impl Global for ManagerWindow {}

pub fn open(cx: &mut App) {
    if let Some(handle) = cx.try_global::<ManagerWindow>().and_then(|h| h.0)
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        return;
    }
    let bounds = Bounds::centered(None, size(px(720.0), px(520.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(600.0), px(400.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        cx.new(|cx| SshManager::new(window, cx))
    }) {
        Ok((handle, _)) => cx.set_global(ManagerWindow(Some(handle))),
        Err(err) => log::error!("SSH window: {err}"),
    }
}

/// The text fields and color of the connection being edited.
struct EditorForm {
    original: SshConnection,
    is_new: bool,
    name: Entity<InputState>,
    host: Entity<InputState>,
    port: Entity<InputState>,
    user: Entity<InputState>,
    identity: Entity<InputState>,
    jump: Entity<InputState>,
    extra: Entity<InputState>,
    color: String,
}

enum Panel {
    Detail,
    Editor(Box<EditorForm>),
    ConfirmDelete(String),
}

pub struct SshManager {
    search: Entity<InputState>,
    selected: Option<String>,
    panel: Panel,
    status: Option<String>,
    _subscription: gpui::Subscription,
}

fn tag_color(tag: &str) -> gpui::Hsla {
    let (h, s, l) = match tag {
        "red" => (0.0, 0.75, 0.55),
        "orange" => (0.07, 0.9, 0.55),
        "yellow" => (0.15, 0.9, 0.55),
        "green" => (0.36, 0.6, 0.45),
        "purple" => (0.75, 0.55, 0.6),
        "pink" => (0.92, 0.7, 0.65),
        _ => (0.6, 0.8, 0.6),
    };
    gpui::hsla(h, s, l, 1.0)
}

fn relative_time(then: i64, now: i64) -> String {
    let secs = (now - then).max(0);
    match secs {
        0..=59 => "just now".to_string(),
        60..=3599 => format!("{} min ago", secs / 60),
        3600..=86399 => format!("{} h ago", secs / 3600),
        _ => format!("{} days ago", secs / 86400),
    }
}

impl SshManager {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::l10n::tr("Search connections..."))
        });
        let subscription = cx.subscribe(&search, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        });
        Self {
            search,
            selected: None,
            panel: Panel::Detail,
            status: None,
            _subscription: subscription,
        }
    }

    fn input(
        value: &str,
        placeholder: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        let value = value.to_string();
        cx.new(|cx| {
            InputState::new(window, cx)
                .default_value(value)
                .placeholder(placeholder)
        })
    }

    fn open_editor(
        &mut self,
        connection: SshConnection,
        is_new: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let form = EditorForm {
            name: Self::input(&connection.name, "Name (optional)", window, cx),
            host: Self::input(&connection.host, "Host", window, cx),
            port: Self::input(&connection.port.to_string(), "Port", window, cx),
            user: Self::input(&connection.user, "Username", window, cx),
            identity: Self::input(
                &connection.identity_file,
                "Identity File (e.g., ~/.ssh/id_rsa)",
                window,
                cx,
            ),
            jump: Self::input(&connection.jump_host, "Jump Host (ProxyJump)", window, cx),
            extra: Self::input(&connection.extra_options, "Extra SSH Options", window, cx),
            color: connection.color_tag.clone(),
            original: connection,
            is_new,
        };
        // Re-render the warning while the options are typed.
        cx.subscribe(&form.extra, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        })
        .detach();
        cx.subscribe(&form.host, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        })
        .detach();
        self.panel = Panel::Editor(Box::new(form));
        cx.notify();
    }

    fn draft(form: &EditorForm, cx: &App) -> SshConnection {
        let text = |input: &Entity<InputState>| input.read(cx).value().trim().to_string();
        let mut c = form.original.clone();
        c.name = text(&form.name);
        c.host = text(&form.host);
        c.port = text(&form.port).parse().unwrap_or(22);
        c.user = text(&form.user);
        c.identity_file = text(&form.identity);
        c.jump_host = text(&form.jump);
        c.extra_options = text(&form.extra);
        c.color_tag = form.color.clone();
        c
    }

    fn import_from_ssh_config(&mut self, cx: &mut Context<Self>) {
        let path = cx.global::<AppData>().root.home().join(".ssh/config");
        let entries = std::fs::read_to_string(&path)
            .map(|text| ssh_config::parse(&text))
            .unwrap_or_default();
        let mut added = 0;
        ssh_edit(cx, |ssh| added = ssh.import_config_entries(&entries));
        self.status = Some(match added {
            0 => "No new hosts in ~/.ssh/config.".to_string(),
            1 => "Imported 1 host from ~/.ssh/config.".to_string(),
            n => format!("Imported {n} hosts from ~/.ssh/config."),
        });
        cx.notify();
    }

    /// Connect / Edit... / Duplicate / Delete (`SSHConnectionView` context menu).
    fn show_row_menu(
        &mut self,
        id: &str,
        position: gpui::Point<gpui::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use gpui_kit::component::native_menu::NativeMenu;
        self.selected = Some(id.to_string());
        self.panel = Panel::Detail;
        cx.notify();
        let op = |op| {
            Box::new(SshRowMenu {
                id: id.to_string(),
                op,
            }) as Box<dyn gpui::Action>
        };
        NativeMenu::new()
            .menu(crate::l10n::tr("Connect"), op(SshRowOp::Connect))
            .menu(crate::l10n::tr("Edit..."), op(SshRowOp::Edit))
            .separator()
            .menu(crate::l10n::tr("Duplicate"), op(SshRowOp::Duplicate))
            .menu(crate::l10n::tr("Delete"), op(SshRowOp::Delete))
            .show(position, window, cx);
    }

    fn on_row_menu(&mut self, action: &SshRowMenu, window: &mut Window, cx: &mut Context<Self>) {
        let id = action.id.clone();
        match action.op {
            SshRowOp::Connect => self.connect_to(&id, window, cx),
            SshRowOp::Edit => {
                if let Some(connection) = cx.global::<SshState>().0.get(&id).cloned() {
                    self.open_editor(connection, false, window, cx);
                }
            }
            SshRowOp::Duplicate => {
                let mut new_id = None;
                ssh_edit(cx, |ssh| new_id = ssh.duplicate(&id));
                self.selected = new_id.or(Some(id));
                self.panel = Panel::Detail;
            }
            SshRowOp::Delete => {
                self.selected = Some(id.clone());
                self.panel = Panel::ConfirmDelete(id);
            }
        }
        cx.notify();
    }

    fn connect_to(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if connect(id, cx) {
            window.remove_window();
        } else {
            self.status = Some("No terminal window is open.".to_string());
            cx.notify();
        }
    }

    fn row(
        &self,
        connection: &SshConnection,
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = connection.id.clone();
        let selected = self.selected.as_deref() == Some(id.as_str());
        let click_id = id.clone();
        let menu_id = id.clone();
        div()
            .id(SharedString::from(format!("ssh-row-{id}")))
            .flex()
            .items_center()
            .gap_2()
            .px_2()
            .py_1()
            .rounded_md()
            .cursor_pointer()
            .bg(if selected {
                chrome.accent.opacity(0.18)
            } else {
                chrome.panel_bg
            })
            .hover(|d| d.bg(chrome.tab_hover_bg))
            .on_click(
                cx.listener(move |this, event: &gpui::ClickEvent, window, cx| {
                    this.selected = Some(click_id.clone());
                    this.panel = Panel::Detail;
                    if event.click_count() >= 2 {
                        this.connect_to(&click_id, window, cx);
                    }
                    cx.notify();
                }),
            )
            .on_mouse_down(
                gpui::MouseButton::Right,
                cx.listener(move |this, event: &gpui::MouseDownEvent, window, cx| {
                    this.show_row_menu(&menu_id, event.position, window, cx)
                }),
            )
            .child(
                div()
                    .size(px(10.0))
                    .rounded_full()
                    .bg(tag_color(&connection.color_tag)),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(
                        div()
                            .text_sm()
                            .overflow_hidden()
                            .child(SharedString::from(connection.display_name())),
                    )
                    .when(!connection.name.is_empty(), |d| {
                        d.child(
                            div()
                                .text_xs()
                                .text_color(chrome.text_muted)
                                .overflow_hidden()
                                .child(SharedString::from(connection.host.clone())),
                        )
                    }),
            )
            .into_any_element()
    }

    fn render_sidebar(&mut self, chrome: Chrome, cx: &mut Context<Self>) -> AnyElement {
        let query = self.search.read(cx).value().trim().to_string();
        let (recent, all): (Vec<SshConnection>, Vec<SshConnection>) = {
            let ssh = &cx.global::<SshState>().0;
            let recent = if query.is_empty() {
                ssh.recent().into_iter().cloned().collect()
            } else {
                Vec::new()
            };
            (recent, ssh.search(&query).into_iter().cloned().collect())
        };
        let mut list = div()
            .id("ssh-list")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_0p5()
            .p_1();
        if !recent.is_empty() {
            list = list.child(
                div()
                    .px_2()
                    .py_1()
                    .text_xs()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(chrome.text_muted)
                    .child(crate::l10n::tr("Recent")),
            );
            for connection in &recent {
                list = list.child(self.row(connection, chrome, cx));
            }
            list = list.child(div().h(px(1.0)).my_1().bg(chrome.border));
        }
        if all.is_empty() {
            list = list.child(div().p_3().text_xs().text_color(chrome.text_muted).child(
                if query.is_empty() {
                    "No saved connections."
                } else {
                    "No matches."
                },
            ));
        }
        for connection in &all {
            list = list.child(self.row(connection, chrome, cx));
        }
        let small = |id: &'static str, label: &'static str| {
            div()
                .id(id)
                .size(px(24.0))
                .flex()
                .items_center()
                .justify_center()
                .rounded_md()
                .cursor_pointer()
                .bg(chrome.tab_bg)
                .hover(|d| d.bg(chrome.tab_hover_bg))
                .child(label)
        };
        div()
            .w(px(260.0))
            .flex_shrink_0()
            .h_full()
            .flex()
            .flex_col()
            .border_r_1()
            .border_color(chrome.border)
            .child(div().p_2().child(Input::new(&self.search)))
            .child(list)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .p_2()
                    .border_t_1()
                    .border_color(chrome.border)
                    .child(
                        small("ssh-add", "+").on_click(cx.listener(|this, _, window, cx| {
                            this.selected = None;
                            this.open_editor(SshConnection::default(), true, window, cx);
                        })),
                    )
                    .child(small("ssh-remove", "\u{2212}").on_click(cx.listener(
                        |this, _, _, cx| {
                            if let Some(id) = this.selected.clone() {
                                this.panel = Panel::ConfirmDelete(id);
                                cx.notify();
                            }
                        },
                    )))
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("ssh-import-config")
                            .px_2()
                            .py_0p5()
                            .rounded_md()
                            .text_xs()
                            .cursor_pointer()
                            .bg(chrome.tab_bg)
                            .hover(|d| d.bg(chrome.tab_hover_bg))
                            .child(crate::l10n::tr("Import from ~/.ssh/config"))
                            .on_click(
                                cx.listener(|this, _, _, cx| this.import_from_ssh_config(cx)),
                            ),
                    ),
            )
            .into_any_element()
    }

    fn button(
        id: &'static str,
        label: &'static str,
        primary: bool,
        chrome: Chrome,
    ) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .px_3()
            .py_1()
            .rounded_md()
            .text_sm()
            .cursor_pointer()
            .bg(if primary {
                chrome.accent
            } else {
                chrome.tab_bg
            })
            .text_color(if primary { gpui::white() } else { chrome.text })
            .hover(|d| d.opacity(0.85))
            .child(label)
    }

    fn render_detail(&mut self, chrome: Chrome, cx: &mut Context<Self>) -> AnyElement {
        let selected = self
            .selected
            .as_deref()
            .and_then(|id| cx.global::<SshState>().0.get(id).cloned());
        let Some(connection) = selected else {
            return div()
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap_2()
                .child(
                    div()
                        .text_base()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("No Connection Selected")),
                )
                .child(
                    div()
                        .text_sm()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr(
                            "Select a connection from the list or create a new one.",
                        )),
                )
                .when_some(self.status.clone(), |d, status| {
                    d.child(
                        div()
                            .mt_2()
                            .text_xs()
                            .text_color(chrome.accent)
                            .child(status),
                    )
                })
                .into_any_element();
        };
        let home = cx
            .global::<AppData>()
            .root
            .home()
            .to_string_lossy()
            .into_owned();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let field = |label: &'static str, value: String| {
            div()
                .flex()
                .gap_4()
                .text_sm()
                .child(
                    div()
                        .w(px(110.0))
                        .text_color(chrome.text_muted)
                        .child(label),
                )
                .child(div().flex_1().min_w_0().child(SharedString::from(value)))
        };
        let mut details = div().flex().flex_col().gap_2();
        details = details
            .child(field("Host:", connection.host.clone()))
            .child(field("Port:", connection.port.to_string()));
        if !connection.user.is_empty() {
            details = details.child(field("User:", connection.user.clone()));
        }
        if !connection.identity_file.is_empty() {
            details = details.child(field("Identity:", connection.identity_file.clone()));
        }
        if !connection.jump_host.is_empty() {
            details = details.child(field("Jump Host:", connection.jump_host.clone()));
        }
        if let Some(last) = connection.last_connected {
            details = details.child(field("Last Connected:", relative_time(last, now)));
        }
        let connect_id = connection.id.clone();
        let edit_connection = connection.clone();
        let dup_id = connection.id.clone();
        let del_id = connection.id.clone();
        div()
            .flex_1()
            .min_w_0()
            .p_5()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .child(
                                div()
                                    .text_lg()
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child(SharedString::from(connection.display_name())),
                            )
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(chrome.text_muted)
                                    .child(SharedString::from(connection.host.clone())),
                            ),
                    )
                    .child(
                        Self::button("ssh-connect", "Connect", true, chrome).on_click(cx.listener(
                            move |this, _, window, cx| this.connect_to(&connect_id, window, cx),
                        )),
                    ),
            )
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(details)
            .child(div().h(px(1.0)).bg(chrome.border))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_xs()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(chrome.text_muted)
                            .child(crate::l10n::tr("SSH Command")),
                    )
                    .child(
                        div()
                            .p_2()
                            .rounded_md()
                            .bg(chrome.tab_bg)
                            .text_xs()
                            .font_family("monospace")
                            .child(SharedString::from(connection.ssh_command(&home))),
                    ),
            )
            .child(div().flex_1())
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(Self::button("ssh-edit", "Edit...", false, chrome).on_click(
                        cx.listener(move |this, _, window, cx| {
                            this.open_editor(edit_connection.clone(), false, window, cx)
                        }),
                    ))
                    .child(
                        Self::button("ssh-duplicate", "Duplicate", false, chrome).on_click(
                            cx.listener(move |this, _, _, cx| {
                                let mut new_id = None;
                                ssh_edit(cx, |ssh| new_id = ssh.duplicate(&dup_id));
                                this.selected = new_id.or_else(|| this.selected.clone());
                                cx.notify();
                            }),
                        ),
                    )
                    .child(
                        Self::button("ssh-delete", "Delete", false, chrome).on_click(cx.listener(
                            move |this, _, _, cx| {
                                this.panel = Panel::ConfirmDelete(del_id.clone());
                                cx.notify();
                            },
                        )),
                    ),
            )
            .into_any_element()
    }

    fn render_editor(&mut self, chrome: Chrome, cx: &mut Context<Self>) -> AnyElement {
        let Panel::Editor(form) = &self.panel else {
            return div().into_any_element();
        };
        let draft = Self::draft(form, cx);
        let validation = draft.extra_options_validation();
        let warning = (!draft.extra_options.is_empty() && !validation.is_valid)
            .then(|| validation_message(validation.issue.as_ref()));
        let can_save = !draft.host.is_empty();
        let labeled = |label: &'static str, input: &Entity<InputState>| {
            div()
                .flex()
                .items_center()
                .gap_3()
                .child(
                    div()
                        .w(px(110.0))
                        .text_sm()
                        .text_color(chrome.text_muted)
                        .child(label),
                )
                .child(div().flex_1().child(Input::new(input)))
        };
        let colors = COLOR_TAGS.into_iter().map(|tag| {
            let active = form.color == tag;
            div()
                .id(SharedString::from(format!("ssh-color-{tag}")))
                .size(px(20.0))
                .rounded_full()
                .cursor_pointer()
                .bg(tag_color(tag))
                .border_2()
                .border_color(if active { chrome.text } else { chrome.panel_bg })
                .on_click(cx.listener(move |this, _, _, cx| {
                    if let Panel::Editor(form) = &mut this.panel {
                        form.color = tag.to_string();
                    }
                    cx.notify();
                }))
        });
        let title = if form.is_new {
            "New Connection"
        } else {
            "Edit Connection"
        };
        let save_draft = draft.clone();
        let mut body = div()
            .flex_1()
            .min_w_0()
            .p_5()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_base()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(title),
            )
            .child(labeled("Name", &form.name))
            .child(labeled("Host", &form.host))
            .child(labeled("Port", &form.port))
            .child(labeled("Username", &form.user))
            .child(labeled("Identity File", &form.identity))
            .child(labeled("Jump Host", &form.jump))
            .child(labeled("Extra Options", &form.extra));
        if let Some(message) = warning {
            body = body.child(
                div()
                    .text_xs()
                    .text_color(gpui::hsla(0.09, 0.9, 0.55, 1.0))
                    .child(SharedString::from(message)),
            );
        }
        body.child(
            div()
                .flex()
                .items_center()
                .gap_3()
                .child(
                    div()
                        .w(px(110.0))
                        .text_sm()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("Tab Color")),
                )
                .child(div().flex().gap_2().children(colors)),
        )
        .child(div().flex_1())
        .child(
            div()
                .flex()
                .justify_end()
                .gap_2()
                .child(
                    Self::button("ssh-cancel", "Cancel", false, chrome).on_click(cx.listener(
                        |this, _, _, cx| {
                            this.panel = Panel::Detail;
                            cx.notify();
                        },
                    )),
                )
                .child(
                    Self::button("ssh-save", "Save", true, chrome)
                        .when(!can_save, |d| d.opacity(0.4))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if save_draft.host.is_empty() {
                                return;
                            }
                            let connection = save_draft.clone();
                            let id = connection.id.clone();
                            ssh_edit(cx, |ssh| {
                                if ssh.get(&connection.id).is_some() {
                                    ssh.update(connection);
                                } else {
                                    ssh.add(connection);
                                }
                            });
                            this.selected = Some(id);
                            this.panel = Panel::Detail;
                            cx.notify();
                        })),
                ),
        )
        .into_any_element()
    }

    fn render_confirm(&mut self, id: &str, chrome: Chrome, cx: &mut Context<Self>) -> AnyElement {
        let name = cx
            .global::<SshState>()
            .0
            .get(id)
            .map(|c| c.display_name())
            .unwrap_or_default();
        let id = id.to_string();
        div()
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(gpui::hsla(0.0, 0.0, 0.0, 0.3))
            .occlude()
            .child(
                div()
                    .w(px(360.0))
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .rounded_xl()
                    .border_1()
                    .border_color(chrome.border)
                    .bg(chrome.panel_bg)
                    .shadow_xl()
                    .child(
                        div()
                            .text_base()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(SharedString::from(format!("Delete \"{name}\"?"))),
                    )
                    .child(
                        div()
                            .flex()
                            .justify_end()
                            .gap_2()
                            .child(
                                Self::button("ssh-del-cancel", "Cancel", false, chrome).on_click(
                                    cx.listener(|this, _, _, cx| {
                                        this.panel = Panel::Detail;
                                        cx.notify();
                                    }),
                                ),
                            )
                            .child(Self::button("ssh-del-ok", "Delete", true, chrome).on_click(
                                cx.listener(move |this, _, _, cx| {
                                    ssh_edit(cx, |ssh| ssh.delete(&id));
                                    if this.selected.as_deref() == Some(id.as_str()) {
                                        this.selected = None;
                                    }
                                    this.panel = Panel::Detail;
                                    cx.notify();
                                }),
                            )),
                    ),
            )
            .into_any_element()
    }
}

impl Render for SshManager {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(&crate::l10n::tr("SSH Connections"));
        let chrome = Chrome::get(cx);
        let sidebar = self.render_sidebar(chrome, cx);
        let confirm = match &self.panel {
            Panel::ConfirmDelete(id) => {
                let id = id.clone();
                Some(self.render_confirm(&id, chrome, cx))
            }
            _ => None,
        };
        let main = match &self.panel {
            Panel::Editor(_) => self.render_editor(chrome, cx),
            _ => self.render_detail(chrome, cx),
        };
        div()
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .on_action(cx.listener(Self::on_row_menu))
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(TitleBar::new().child(div().text_sm().child(crate::l10n::tr("SSH Connections"))))
            .child(div().flex_1().min_h_0().flex().child(sidebar).child(main))
            .children(confirm)
    }
}
