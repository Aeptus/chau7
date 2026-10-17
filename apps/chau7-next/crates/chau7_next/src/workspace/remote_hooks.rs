//! What remote control (`crate::remote`) reads from a window: its tabs, in
//! order, with their panes, and the selected tab.

use chau7_next_core::tabs_state::TabId;
use gpui::{App, Entity};

use super::Workspace;
use crate::pane::PaneTree;

/// One tab of a window, as remote control sees it.
pub struct RemoteTabSource {
    pub id: TabId,
    /// The title shown in the tab bar.
    pub title: String,
    pub custom_title: Option<String>,
    pub mcp_controlled: bool,
    pub panes: Entity<PaneTree>,
}

impl Workspace {
    pub fn remote_tabs(&self, cx: &App) -> Vec<RemoteTabSource> {
        self.state
            .tabs()
            .iter()
            .filter_map(|meta| {
                let entry = self.entries.get(&meta.id)?;
                Some(RemoteTabSource {
                    id: meta.id,
                    title: self.tab_title(meta.id, cx),
                    custom_title: meta.custom_title.clone(),
                    mcp_controlled: meta.mcp_controlled,
                    panes: entry.panes.clone(),
                })
            })
            .collect()
    }
}
