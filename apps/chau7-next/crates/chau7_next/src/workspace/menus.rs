//! Tab and group context menus (right click, or Ctrl+click on macOS).

use chau7_next_core::tabs_state::{TabColor, repo_group_name};
use gpui::{App, Context, Div, Pixels, Point, Stateful, Window, prelude::*};
use gpui_kit::component::native_menu::NativeMenu;

use super::drag::move_tabs_to;
use super::{AppData, Workspace};
use crate::actions::{GroupMenu, GroupMenuOp, TabMenu, TabMenuOp};
use crate::tab_bar::TabId;

pub(super) fn register_menu_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(cx.listener(Workspace::on_tab_menu))
        .on_action(cx.listener(Workspace::on_group_menu))
}

impl Workspace {
    pub(super) fn show_tab_menu(
        &mut self,
        id: TabId,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.hover = None;
        let Some(meta) = self.state.get(id).cloned() else {
            return;
        };
        let op = |op: TabMenuOp| Box::new(TabMenu { tab: id, op }) as Box<dyn gpui::Action>;
        let mut menu =
            NativeMenu::new().menu(crate::l10n::tr("Rename Tab…"), op(TabMenuOp::Rename));
        let mut colors = NativeMenu::new();
        for color in TabColor::ALL {
            colors = colors.menu(capitalize(color.name()), op(TabMenuOp::SetColor(color)));
        }
        menu = menu.submenu(crate::l10n::tr("Color"), colors).separator();
        if let Some(group) = meta.repo_group_id.clone() {
            if self.state.group_members(&group).len() > 1 {
                menu = menu
                    .menu(
                        crate::l10n::tr("Remove from Repo Group"),
                        op(TabMenuOp::RemoveFromRepoGroup),
                    )
                    .submenu(
                        crate::l10n::tr("Move Group to Window"),
                        self.window_submenu(cx, |index| op(TabMenuOp::MoveGroupToWindow(index))),
                    );
            }
        } else if meta.git_root.is_some() {
            menu = menu
                .menu(
                    crate::l10n::tr("Add to Repo Group"),
                    op(TabMenuOp::AddToRepoGroup),
                )
                .menu(
                    crate::l10n::tr("Group All Same Repo"),
                    op(TabMenuOp::GroupAllSameRepo),
                );
        }
        if self.state.selected() != Some(id) {
            menu = menu.menu(
                crate::l10n::tr("Move to Idle Tabs"),
                op(TabMenuOp::MoveToIdle),
            );
        }
        menu = menu
            .submenu(
                crate::l10n::tr("Move to Window"),
                self.window_submenu(cx, |index| op(TabMenuOp::MoveToWindow(index))),
            )
            .separator();
        if self.broadcast {
            let label = if self.broadcast_excluded.contains(&id) {
                "Include in Broadcast"
            } else {
                "Exclude from Broadcast"
            };
            menu = menu.menu(label, op(TabMenuOp::ToggleBroadcastInclusion));
        }
        menu = menu.menu(crate::l10n::tr("Close Tab"), op(TabMenuOp::Close));
        menu.show(position, window, cx);
    }

    pub(super) fn show_group_menu(
        &mut self,
        group: String,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let count = self.state.group_members(&group).len();
        let op = |op: GroupMenuOp| {
            Box::new(GroupMenu {
                group: group.clone(),
                op,
            }) as Box<dyn gpui::Action>
        };
        let mut menu = NativeMenu::new()
            .submenu(
                format!("Move \"{}\" to Window", repo_group_name(&group)),
                self.window_submenu(cx, |index| op(GroupMenuOp::MoveToWindow(index))),
            )
            .menu(
                crate::l10n::tr("Remove from Repo Group"),
                op(GroupMenuOp::Ungroup),
            )
            .separator()
            .menu(
                crate::l10n::count("context.closeGroup", "Close Group (%d tabs)", count as i64),
                op(GroupMenuOp::CloseGroup),
            );
        if let Some(root) = self.notification_repo_for_group(&group) {
            let mut notifications = NativeMenu::new();
            if crate::notifications::repo_is_muted(&root, cx) {
                notifications = notifications
                    .menu("Unmute Notifications", op(GroupMenuOp::UnmuteNotifications));
            } else {
                notifications =
                    notifications.menu("Mute Notifications", op(GroupMenuOp::MuteNotifications));
            }
            notifications = notifications
                .menu(
                    "Snooze for 15 Minutes",
                    op(GroupMenuOp::SnoozeNotifications(15)),
                )
                .menu(
                    "Snooze for 1 Hour",
                    op(GroupMenuOp::SnoozeNotifications(60)),
                )
                .menu(
                    "Snooze for 8 Hours",
                    op(GroupMenuOp::SnoozeNotifications(480)),
                );
            menu = menu.separator().submenu("Notifications", notifications);
        }
        menu.show(position, window, cx);
    }

    /// A mixed manual group must not silently mute only one of its repositories.
    fn notification_repo_for_group(&self, group: &str) -> Option<String> {
        let mut root: Option<String> = None;
        for id in self.state.group_members(group) {
            let repo = self.state.get(id)?.git_root.as_ref()?;
            if root.as_ref().is_some_and(|root| root != repo) {
                return None;
            }
            root = Some(repo.clone());
        }
        root
    }

    /// "New Window", then every other open window by title.
    pub(super) fn window_submenu(
        &self,
        cx: &App,
        action: impl Fn(Option<usize>) -> Box<dyn gpui::Action>,
    ) -> NativeMenu {
        let mut menu = NativeMenu::new().menu(crate::l10n::tr("New Window"), action(None));
        let others: Vec<_> = AppData::live(cx)
            .into_iter()
            .enumerate()
            .filter(|(_, (h, _))| Some(*h) != self.window_handle)
            .collect();
        if !others.is_empty() {
            menu = menu.separator();
        }
        for (index, (_, ws)) in others {
            let ws = ws.read(cx);
            let title = ws
                .state
                .selected()
                .map(|id| ws.tab_title(id, cx))
                .unwrap_or_else(|| format!("Window {}", index + 1));
            menu = menu.menu(title, action(Some(index)));
        }
        menu
    }

    pub(super) fn on_tab_menu(
        &mut self,
        action: &TabMenu,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let id = action.tab;
        log::info!("TABBAR menu tab={id} op={:?}", action.op);
        match &action.op {
            TabMenuOp::Rename => self.begin_rename(id, window, cx),
            TabMenuOp::Close => self.request_close_tab(id, window, cx),
            TabMenuOp::ToggleBroadcastInclusion => {
                if !self.broadcast_excluded.remove(&id) {
                    self.broadcast_excluded.insert(id);
                }
            }
            TabMenuOp::AddToRepoGroup => self.state.add_to_repo_group(id),
            TabMenuOp::RemoveFromRepoGroup => self.state.remove_from_repo_group(id),
            TabMenuOp::GroupAllSameRepo => self.state.group_all_same_repo(id),
            TabMenuOp::MoveToIdle => self.state.force_idle(id),
            TabMenuOp::SetColor(color) => {
                if let Some(meta) = self.state.get_mut(id) {
                    // Same as picking it in the rename panel: a manual override.
                    meta.color = *color;
                    meta.auto_color = None;
                    meta.manual_color_override = true;
                }
            }
            TabMenuOp::MoveToWindow(target) => {
                let me = cx.entity();
                let target = *target;
                cx.defer(move |cx| move_tabs_to(me, vec![id], target, cx));
            }
            TabMenuOp::MoveGroupToWindow(target) => {
                if let Some(group) = self.state.get(id).and_then(|m| m.repo_group_id.clone()) {
                    let ids = self.state.group_members(&group);
                    let me = cx.entity();
                    let target = *target;
                    cx.defer(move |cx| move_tabs_to(me, ids, target, cx));
                }
            }
        }
        cx.notify();
    }

    pub(super) fn on_group_menu(
        &mut self,
        action: &GroupMenu,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        log::info!("TABBAR menu group={} op={:?}", action.group, action.op);
        match &action.op {
            GroupMenuOp::MuteNotifications
            | GroupMenuOp::SnoozeNotifications(_)
            | GroupMenuOp::UnmuteNotifications => {
                if let Some(root) = self.notification_repo_for_group(&action.group) {
                    match action.op {
                        GroupMenuOp::UnmuteNotifications => {
                            crate::notifications::unmute_repo(&root, cx)
                        }
                        GroupMenuOp::SnoozeNotifications(minutes) => {
                            crate::notifications::mute_repo(
                                &root,
                                Some(
                                    chrono::Utc::now()
                                        + chrono::Duration::minutes(i64::from(minutes)),
                                ),
                                cx,
                            )
                        }
                        _ => crate::notifications::mute_repo(&root, None, cx),
                    }
                }
            }
            GroupMenuOp::Ungroup => self.state.ungroup(&action.group),
            GroupMenuOp::CloseGroup => {
                let ids = self.state.group_members(&action.group);
                self.close_tabs_confirming(ids, window, cx);
            }
            GroupMenuOp::MoveToWindow(target) => {
                let ids = self.state.group_members(&action.group);
                let me = cx.entity();
                let target = *target;
                cx.defer(move |cx| move_tabs_to(me, ids, target, cx));
            }
        }
        cx.notify();
    }
}

pub(super) fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    chars
        .next()
        .map(|c| c.to_uppercase().collect::<String>() + chars.as_str())
        .unwrap_or_default()
}
