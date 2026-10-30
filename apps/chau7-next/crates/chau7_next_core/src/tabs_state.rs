//! Tab list state for one window: order, selection, repo groups, idle tabs,
//! recently closed tabs.
//!
//! Ported from `apps/chau7-macos/Sources/Chau7/Overlay/OverlayTabsModel.swift`
//! and `OverlayTabsModel+TabSwitchOptimization.swift` (`newTab`,
//! `insertionIndexForNewTab`, `closeTab`, `reopenClosedTab`, `selectNextTab`,
//! `selectPreviousTab`, `selectTab(number:)`, `forceTabIdle`, `idleTabCount`,
//! `addTabToRepoGroup`, `removeTabFromRepoGroup`, `groupAllSameRepo`,
//! `coalesceGroup`, `moveTab`). UI and terminal sessions live elsewhere; this
//! module only tracks ids and metadata so it can be tested in isolation.

use crate::tab_bar_layout::{TabBarLayoutItem, TabBarLayoutTab, coalesced_order, display_items};
use crate::token_optimization::{TabTokenOptOverride, TokenOptimizationMode};
use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};

fn normalized_path(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                result.pop();
            }
            other => result.push(other.as_os_str()),
        }
    }
    result
}

/// Preferred enclosing root first, otherwise the most specific recent root
/// (`KnownRepoRootResolver`). Components avoid sibling-prefix matches.
pub fn known_repo_root(
    directory: &Path,
    preferred: Option<&str>,
    recent: &[String],
) -> Option<String> {
    let directory = normalized_path(directory);
    if directory.as_os_str().is_empty() {
        return None;
    }
    if let Some(root) = preferred {
        let root = normalized_path(Path::new(root));
        if !root.as_os_str().is_empty() && directory.starts_with(&root) {
            return Some(root.to_string_lossy().into_owned());
        }
    }
    recent
        .iter()
        .map(|root| normalized_path(Path::new(root)))
        .filter(|root| !root.as_os_str().is_empty() && directory.starts_with(root))
        .max_by_key(|root| root.as_os_str().len())
        .map(|root| root.to_string_lossy().into_owned())
}

pub type TabId = u64;

/// Tab colors, same order and values as `Appearance/TabColor.swift`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TabColor {
    Blue,
    Teal,
    Green,
    Yellow,
    Orange,
    Pink,
    Purple,
    Gray,
}

impl TabColor {
    pub const ALL: [TabColor; 8] = [
        TabColor::Blue,
        TabColor::Teal,
        TabColor::Green,
        TabColor::Yellow,
        TabColor::Orange,
        TabColor::Pink,
        TabColor::Purple,
        TabColor::Gray,
    ];

    /// RGB in 0..1, from `TabColor.color`.
    pub fn rgb(self) -> (f32, f32, f32) {
        match self {
            TabColor::Blue => (0.25, 0.55, 0.95),
            TabColor::Teal => (0.20, 0.70, 0.70),
            TabColor::Green => (0.25, 0.75, 0.40),
            TabColor::Yellow => (0.95, 0.80, 0.25),
            TabColor::Orange => (0.95, 0.55, 0.25),
            TabColor::Pink => (0.95, 0.45, 0.70),
            TabColor::Purple => (0.65, 0.45, 0.90),
            TabColor::Gray => (0.70, 0.70, 0.72),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            TabColor::Blue => "blue",
            TabColor::Teal => "teal",
            TabColor::Green => "green",
            TabColor::Yellow => "yellow",
            TabColor::Orange => "orange",
            TabColor::Pink => "pink",
            TabColor::Purple => "purple",
            TabColor::Gray => "gray",
        }
    }

    pub fn from_name(name: &str) -> Option<TabColor> {
        TabColor::ALL.into_iter().find(|c| c.name() == name)
    }
}

/// Where new tabs go (`FeatureSettings.newTabPosition`, default "end").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NewTabPosition {
    #[default]
    End,
    AfterCurrent,
}

/// Per-tab metadata the tab bar needs.
#[derive(Debug, Clone, PartialEq)]
pub struct TabMeta {
    pub id: TabId,
    pub custom_title: Option<String>,
    pub color: TabColor,
    pub repo_group_id: Option<String>,
    /// Inherited tags are provisional until the shell resolves its repository.
    pub has_inherited_repo_group: bool,
    /// Git root associated with the focused-session UI and existing APIs.
    pub git_root: Option<String>,
    /// Git root of the first terminal in the split tree; drives automatic grouping.
    pub primary_git_root: Option<String>,
    /// Git root of the displayed terminal; drives manual grouping actions.
    pub presentation_git_root: Option<String>,
    /// Seconds (any monotonic clock) of the last terminal activity.
    pub last_activity: f64,
    /// Seconds (same clock) when the tab was created (hover card footer).
    pub created_at: f64,
    /// Color picked from the AI tool running in the tab (`autoColor`).
    pub auto_color: Option<TabColor>,
    /// The user picked a color in the rename panel: it beats `auto_color`.
    pub manual_color_override: bool,
    /// Opened by an MCP client (`isMCPControlled`).
    pub mcp_controlled: bool,
    /// Per-tab token optimization override (`tokenOptOverride`).
    pub token_opt_override: TabTokenOptOverride,
    /// Stable identity of the tab (`OverlayTab.id`): what MCP clients use as
    /// `tab_id`, and the `tab_id` of events. Kept when the tab moves to
    /// another window and across relaunch (set it with [`Self::set_uuid`]).
    pub uuid: uuid::Uuid,
}

impl TabMeta {
    pub fn new(id: TabId, color: TabColor) -> Self {
        let uuid = uuid::Uuid::new_v4();
        crate::notifications::tab_resolver::register_tab_uuid(id, uuid);
        Self {
            id,
            custom_title: None,
            color,
            repo_group_id: None,
            has_inherited_repo_group: false,
            git_root: None,
            primary_git_root: None,
            presentation_git_root: None,
            last_activity: 0.0,
            created_at: 0.0,
            auto_color: None,
            manual_color_override: false,
            mcp_controlled: false,
            token_opt_override: TabTokenOptOverride::Default,
            uuid,
        }
    }

    /// Give the tab its saved identity back (session restore), so MCP
    /// clients, events and remote control see the same tab after relaunch.
    pub fn set_uuid(&mut self, uuid: uuid::Uuid) {
        self.uuid = uuid;
        crate::notifications::tab_resolver::register_tab_uuid(self.id, uuid);
    }

    /// `effectiveColor`: a manual pick, else the automatic color when
    /// `auto_theme` (`isAutoTabThemeEnabled`) is on, else the tab color.
    pub fn effective_color(&self, auto_theme: bool) -> TabColor {
        if self.manual_color_override {
            return self.color;
        }
        match self.auto_color {
            Some(auto) if auto_theme => auto,
            _ => self.color,
        }
    }

    /// `commitRename`: an empty title clears the custom title, an unchanged
    /// one is not stored; a changed color becomes a manual override.
    pub fn apply_rename(&mut self, text: &str, original_title: &str, color: TabColor) {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            self.custom_title = None;
        } else if trimmed != original_title {
            self.custom_title = Some(trimmed.to_string());
        }
        if color != self.color {
            self.auto_color = None;
            self.manual_color_override = true;
        }
        self.color = color;
    }
}

/// `toggleTokenOpt(for:)`: the next per-tab override when the hover card
/// button is clicked; `None` when the mode is off.
pub fn next_token_opt_override(
    mode: TokenOptimizationMode,
    current: TabTokenOptOverride,
) -> Option<TabTokenOptOverride> {
    use TabTokenOptOverride as O;
    use TokenOptimizationMode as M;
    Some(match (mode, current) {
        (M::Off, _) => return None,
        (M::AllTabs, O::Default) => O::ForceOff,
        (M::AllTabs, _) => O::Default,
        (M::AiOnly, O::Default) => O::ForceOff,
        (M::AiOnly, O::ForceOff) => O::ForceOn,
        (M::AiOnly, O::ForceOn) => O::Default,
        (M::Manual, O::Default) => O::ForceOn,
        (M::Manual, _) => O::Default,
    })
}

/// Repository roots for each split-tab role. Kept together to make it
/// difficult to accidentally reconcile one role using another role's root.
#[derive(Debug, Clone, Default)]
struct RepositoryRoots {
    focused: Option<String>,
    primary: Option<String>,
    presentation: Option<String>,
}

/// `optimizerOverrideState`: `Some(active)` only when the tab deviates from
/// its mode's default behavior.
pub fn token_opt_override_state(
    mode: TokenOptimizationMode,
    current: TabTokenOptOverride,
) -> Option<bool> {
    use TabTokenOptOverride as O;
    use TokenOptimizationMode as M;
    match (mode, current) {
        (M::Off, _) => None,
        (M::AllTabs, O::ForceOff) => Some(false),
        (M::AllTabs, _) => None,
        (M::Manual, O::ForceOn) => Some(true),
        (M::Manual, _) => None,
        (M::AiOnly, O::ForceOn) => Some(true),
        (M::AiOnly, O::ForceOff) => Some(false),
        (M::AiOnly, O::Default) => None,
    }
}

/// `updateAutoColor`: the tab color for a command line, from the AI tool
/// color map (first word contains a known name) and then the user's custom
/// detection rules (pattern anywhere in the command). Longer names are
/// tried first so the result does not depend on map order.
pub fn auto_color_for_command(
    command: &str,
    custom_rules: &[(String, TabColor)],
) -> Option<TabColor> {
    let first_word = command.split(' ').next().unwrap_or_default().to_lowercase();
    let lowered = command.to_lowercase();
    let mut known: Vec<(&String, &&str)> = crate::ai::tool_registry::TAB_COLOR_MAP.iter().collect();
    known.sort_by(|a, b| b.0.len().cmp(&a.0.len()).then(a.0.cmp(b.0)));
    for (pattern, color) in known {
        if !pattern.is_empty() && first_word.contains(pattern.as_str()) {
            return TabColor::from_name(color);
        }
    }
    for (pattern, color) in custom_rules {
        let pattern = pattern.trim().to_lowercase();
        if pattern.is_empty() {
            continue;
        }
        if lowered.contains(&pattern) || first_word.contains(&pattern) {
            return Some(*color);
        }
    }
    None
}

/// A closed tab kept for "Reopen Closed Tab".
#[derive(Debug, Clone, PartialEq)]
pub struct ClosedTab {
    pub meta: TabMeta,
    pub original_index: usize,
    pub directory: Option<String>,
}

/// What the caller must do after [`TabsState::close`].
#[derive(Debug, Clone, PartialEq)]
pub enum CloseOutcome {
    /// Tab was not found.
    NotFound,
    /// Tab removed; the caller tears down its sessions.
    Closed,
    /// It was the window's only tab; the caller closes the window.
    CloseWindow,
}

#[derive(Debug, Clone, Default)]
pub struct TabsState {
    tabs: Vec<TabMeta>,
    selected: Option<TabId>,
    closed: Vec<ClosedTab>,
    forced_idle: HashSet<TabId>,
    pub new_tab_position: NewTabPosition,
    /// `idleTabThresholdMinutes * 60`; default 10 minutes.
    pub idle_threshold_secs: f64,
    /// `groupIdleTabs`, default true.
    pub group_idle_tabs: bool,
    /// `repoGroupingMode == .auto`; default off (manual grouping only).
    pub auto_repo_grouping: bool,
}

/// Maximum number of tabs remembered for reopening.
pub const CLOSED_TAB_LIMIT: usize = 10;

impl TabsState {
    pub fn new() -> Self {
        Self {
            idle_threshold_secs: 600.0,
            group_idle_tabs: true,
            ..Default::default()
        }
    }

    pub fn tabs(&self) -> &[TabMeta] {
        &self.tabs
    }

    pub fn len(&self) -> usize {
        self.tabs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.tabs.is_empty()
    }

    pub fn selected(&self) -> Option<TabId> {
        self.selected
    }

    pub fn index_of(&self, id: TabId) -> Option<usize> {
        self.tabs.iter().position(|t| t.id == id)
    }

    pub fn get(&self, id: TabId) -> Option<&TabMeta> {
        self.tabs.iter().find(|t| t.id == id)
    }

    pub fn get_mut(&mut self, id: TabId) -> Option<&mut TabMeta> {
        self.tabs.iter_mut().find(|t| t.id == id)
    }

    /// Color for the next new tab: cycles through the palette by tab count.
    pub fn next_color(&self) -> TabColor {
        TabColor::ALL[self.tabs.len() % TabColor::ALL.len()]
    }

    /// Insert a new tab like `newTab`: it inherits the selected tab's repo
    /// group, and goes right after the selected tab when it does (or when the
    /// position setting says so), otherwise at the end.
    pub fn add(&mut self, meta: TabMeta, select: bool) {
        self.add_with_inheritance(meta, None, select);
    }

    /// Actual shell tabs only inherit a group when their starting directory
    /// is within that repository (`RepoGroupInheritance`).
    pub fn add_in_directory(&mut self, meta: TabMeta, directory: &Path, select: bool) {
        self.add_with_inheritance(meta, Some(directory), select);
    }

    fn add_with_inheritance(&mut self, mut meta: TabMeta, directory: Option<&Path>, select: bool) {
        let inherited = self
            .selected
            .and_then(|id| self.get(id))
            .and_then(|t| t.repo_group_id.clone())
            .filter(|root| {
                directory.is_none_or(|cwd| {
                    normalized_path(cwd).starts_with(normalized_path(Path::new(root)))
                })
            });
        if meta.repo_group_id.is_none() {
            meta.repo_group_id = inherited.clone();
            meta.has_inherited_repo_group = inherited.is_some();
        }
        let current = self.selected.and_then(|id| self.index_of(id));
        let index = match (inherited.is_some(), self.new_tab_position, current) {
            (true, _, Some(i)) | (_, NewTabPosition::AfterCurrent, Some(i)) => i + 1,
            _ => self.tabs.len(),
        };
        let id = meta.id;
        let group = meta.repo_group_id.clone();
        self.tabs.insert(index.min(self.tabs.len()), meta);
        if let Some(group) = group {
            self.coalesce_group(&group);
        }
        if select || self.selected.is_none() {
            self.select(id);
        }
    }

    /// Append a tab at the end (cross-window moves, restore) and optionally select it.
    pub fn push(&mut self, meta: TabMeta, select: bool) {
        let id = meta.id;
        self.tabs.push(meta);
        if select || self.selected.is_none() {
            self.select(id);
        }
    }

    pub fn select(&mut self, id: TabId) -> bool {
        if self.index_of(id).is_none() {
            return false;
        }
        self.selected = Some(id);
        self.forced_idle.remove(&id);
        true
    }

    pub fn select_next(&mut self) {
        self.step(1);
    }

    pub fn select_previous(&mut self) {
        self.step(-1);
    }

    fn step(&mut self, delta: isize) {
        if let Some(id) = self.step_target(delta) {
            self.select(id);
        }
    }

    /// The tab `delta` places from the selected one, wrapping around
    /// (next/previous tab), without selecting it. None with fewer than two
    /// tabs or nothing selected.
    pub fn step_target(&self, delta: isize) -> Option<TabId> {
        let count = self.tabs.len() as isize;
        if count < 2 {
            return None;
        }
        let index = self.selected.and_then(|id| self.index_of(id))?;
        let next = (index as isize + delta).rem_euclid(count) as usize;
        Some(self.tabs[next].id)
    }

    /// Select a 1-based tab by its position in the rendered tab-bar row.
    /// Idle-dropdown, repository-group, and new-tab items are not numbered.
    /// The same display policy used by rendering supplies the ordered tabs.
    pub fn select_visible_number(&mut self, number: usize, now: f64) -> bool {
        match self.visible_number_target(number, now) {
            Some(id) => self.select(id),
            None => false,
        }
    }

    /// The tab [`Self::select_visible_number`] would select.
    pub fn visible_number_target(&self, number: usize, now: f64) -> Option<TabId> {
        self.display_items(now)
            .into_iter()
            .filter_map(|item| match item {
                TabBarLayoutItem::Tab(id) => Some(id),
                _ => None,
            })
            .nth(number.max(1) - 1)
    }

    /// `selectTab(number:)`: 1-based, out of range is ignored.
    pub fn select_number(&mut self, number: usize) {
        if let Some(id) = self.number_target(number) {
            self.select(id);
        }
    }

    /// The tab [`Self::select_number`] would select.
    pub fn number_target(&self, number: usize) -> Option<TabId> {
        self.tabs.get(number.max(1) - 1).map(|tab| tab.id)
    }

    /// Close a tab, remembering it for reopen. Selection follows `closeTab`:
    /// the tab to the left of the closed one (or the new first tab).
    pub fn close(&mut self, id: TabId, directory: Option<String>) -> CloseOutcome {
        let Some(index) = self.index_of(id) else {
            return CloseOutcome::NotFound;
        };
        if self.tabs.len() == 1 {
            return CloseOutcome::CloseWindow;
        }
        let meta = self.tabs.remove(index);
        self.forced_idle.remove(&id);
        self.closed.push(ClosedTab {
            meta,
            original_index: index,
            directory,
        });
        if self.closed.len() > CLOSED_TAB_LIMIT {
            self.closed.remove(0);
        }
        if self.selected == Some(id) {
            let new_index = index.saturating_sub(1).min(self.tabs.len() - 1);
            self.selected = Some(self.tabs[new_index].id);
        }
        CloseOutcome::Closed
    }

    /// Put `meta` in place of tab `id` and select it (closing the last tab
    /// with "New Tab", `makeFreshTab`). Not recorded for reopen.
    pub fn replace(&mut self, id: TabId, meta: TabMeta) -> bool {
        let Some(index) = self.index_of(id) else {
            return false;
        };
        self.forced_idle.remove(&id);
        let new_id = meta.id;
        self.tabs[index] = meta;
        self.selected = Some(new_id);
        true
    }

    /// Remove a tab without recording it (moved to another window).
    pub fn take(&mut self, id: TabId) -> Option<TabMeta> {
        let index = self.index_of(id)?;
        let meta = self.tabs.remove(index);
        self.forced_idle.remove(&id);
        if self.selected == Some(id) {
            self.selected = if self.tabs.is_empty() {
                None
            } else {
                Some(self.tabs[index.saturating_sub(1).min(self.tabs.len() - 1)].id)
            };
        }
        Some(meta)
    }

    /// `reopenClosedTab`: pops the last closed tab and reinserts it at its
    /// original index (clamped), selected. The caller recreates the session
    /// using `directory`. The reopened tab gets `new_id`.
    pub fn reopen_closed(&mut self, new_id: TabId) -> Option<ClosedTab> {
        let mut entry = self.closed.pop()?;
        entry.meta.id = new_id;
        let index = entry.original_index.min(self.tabs.len());
        self.tabs.insert(index, entry.meta.clone());
        self.select(new_id);
        Some(entry)
    }

    pub fn closed_count(&self) -> usize {
        self.closed.len()
    }

    /// The closed tabs Reopen Closed Tab can bring back, oldest first.
    pub fn closed_tabs(&self) -> &[ClosedTab] {
        &self.closed
    }

    /// Move a tab to `to_index` (reorder by drag).
    pub fn move_tab(&mut self, id: TabId, to_index: usize) {
        let Some(from) = self.index_of(id) else {
            return;
        };
        let meta = self.tabs.remove(from);
        let to = to_index.min(self.tabs.len());
        self.tabs.insert(to, meta);
    }

    /// `moveCurrentTabRight` / `moveCurrentTabLeft`: swap the selected tab
    /// with its neighbor (`delta` 1 or -1); nothing at either end.
    pub fn move_selected(&mut self, delta: isize) -> bool {
        let Some(index) = self.selected.and_then(|id| self.index_of(id)) else {
            return false;
        };
        let target = index as isize + delta;
        if target < 0 || target >= self.tabs.len() as isize {
            return false;
        }
        self.tabs.swap(index, target as usize);
        true
    }

    /// Move every tab of a repo group, as a block, so it starts at the slot of
    /// `to_index` in the list without the group.
    pub fn move_group(&mut self, group: &str, to_index: usize) {
        let (members, rest): (Vec<_>, Vec<_>) = self
            .tabs
            .drain(..)
            .partition(|t| t.repo_group_id.as_deref() == Some(group));
        self.tabs = rest;
        let at = to_index.min(self.tabs.len());
        for (offset, meta) in members.into_iter().enumerate() {
            self.tabs.insert(at + offset, meta);
        }
    }

    pub fn group_members(&self, group: &str) -> Vec<TabId> {
        self.tabs
            .iter()
            .filter(|t| t.repo_group_id.as_deref() == Some(group))
            .map(|t| t.id)
            .collect()
    }

    /// `coalesceGroup`: pull the group's tabs next to its first tab.
    pub fn coalesce_group(&mut self, group: &str) {
        let ids: Vec<Option<&str>> = self
            .tabs
            .iter()
            .map(|t| t.repo_group_id.as_deref())
            .collect();
        let order = coalesced_order(&ids, group);
        if order.iter().copied().eq(0..self.tabs.len()) {
            return;
        }
        let old = std::mem::take(&mut self.tabs);
        let mut slots: Vec<Option<TabMeta>> = old.into_iter().map(Some).collect();
        self.tabs = order.into_iter().filter_map(|i| slots[i].take()).collect();
    }

    /// `addTabToRepoGroup`: requires a known git root.
    pub fn add_to_repo_group(&mut self, id: TabId) {
        let Some(root) = self.get(id).and_then(|t| t.presentation_git_root.clone()) else {
            return;
        };
        if let Some(tab) = self.get_mut(id) {
            tab.repo_group_id = Some(root.clone());
            tab.has_inherited_repo_group = false;
        }
        self.coalesce_group(&root);
    }

    pub fn remove_from_repo_group(&mut self, id: TabId) {
        if let Some(tab) = self.get_mut(id) {
            tab.repo_group_id = None;
            tab.has_inherited_repo_group = false;
        }
    }

    /// Ungroup every tab of a group (group bracket menu).
    pub fn ungroup(&mut self, group: &str) {
        for tab in &mut self.tabs {
            if tab.repo_group_id.as_deref() == Some(group) {
                tab.repo_group_id = None;
                tab.has_inherited_repo_group = false;
            }
        }
    }

    /// `groupAllSameRepo`.
    pub fn group_all_same_repo(&mut self, id: TabId) {
        let Some(root) = self.get(id).and_then(|t| t.presentation_git_root.clone()) else {
            return;
        };
        for tab in &mut self.tabs {
            if tab.presentation_git_root.as_deref() == Some(root.as_str()) {
                tab.repo_group_id = Some(root.clone());
                tab.has_inherited_repo_group = false;
            }
        }
        self.coalesce_group(&root);
    }

    /// Switching into Auto immediately reconciles every known root, rather
    /// than waiting for a shell to change directories. Off/Manual keep tags.
    pub fn set_auto_repo_grouping(&mut self, automatic: bool) {
        self.set_auto_repo_grouping_in_directories(automatic, &[], &[]);
    }

    pub fn set_auto_repo_grouping_in_directories(
        &mut self,
        automatic: bool,
        directories: &[(TabId, PathBuf)],
        recent: &[String],
    ) {
        let changed = self.auto_repo_grouping != automatic;
        self.auto_repo_grouping = automatic;
        if automatic && changed {
            let ids: Vec<_> = self.tabs.iter().map(|tab| tab.id).collect();
            for id in ids {
                let directory = directories
                    .iter()
                    .find(|(tab_id, _)| *tab_id == id)
                    .map(|(_, cwd)| cwd.as_path());
                self.setup_repo_group_in_directory(id, directory, recent);
            }
        }
    }

    /// `setupRepoGroupingForTab`: seed newly attached/restored tabs even in
    /// Off/Manual, while Auto replaces persisted tags with the live root.
    pub fn setup_repo_group(&mut self, id: TabId) {
        self.setup_repo_group_in_directory(id, None, &[]);
    }

    pub fn setup_repo_group_in_directory(
        &mut self,
        id: TabId,
        directory: Option<&Path>,
        recent: &[String],
    ) {
        let automatic = self.auto_repo_grouping;
        let Some(tab) = self.get_mut(id) else { return };
        if automatic || tab.repo_group_id.is_none() {
            tab.repo_group_id = tab.primary_git_root.clone().or_else(|| {
                directory.and_then(|cwd| known_repo_root(cwd, tab.repo_group_id.as_deref(), recent))
            });
            if automatic {
                tab.has_inherited_repo_group = false;
            }
        }
        let group = tab.repo_group_id.clone();
        if let Some(group) = group {
            self.coalesce_group(&group);
        }
    }

    /// Record a session root, including unchanged values: a tab may have a
    /// preinitialized git root but a missing or stale group tag.
    pub fn set_git_root(&mut self, id: TabId, root: Option<String>) {
        self.set_git_root_in_directory(id, root, None, &[]);
    }

    pub fn set_git_root_in_directory(
        &mut self,
        id: TabId,
        root: Option<String>,
        directory: Option<&Path>,
        recent: &[String],
    ) {
        self.set_repository_roots_in_directory(
            id,
            root.clone(),
            root.clone(),
            root,
            directory,
            recent,
        );
    }

    /// Keep focused-session metadata, primary-root grouping, and displayed-root
    /// manual actions separate. None is an explicit unknown/outside-repository
    /// value; it never falls back to another split pane's root.
    pub fn set_repository_roots_in_directory(
        &mut self,
        id: TabId,
        focused_root: Option<String>,
        primary_root: Option<String>,
        presentation_root: Option<String>,
        primary_directory: Option<&Path>,
        recent: &[String],
    ) {
        self.reconcile_repository_roots_with_known(
            id,
            RepositoryRoots {
                focused: focused_root,
                primary: primary_root,
                presentation: presentation_root,
            },
            primary_directory,
            recent,
            |path| Path::new(path).exists(),
        );
    }

    /// Heal tags whose old repository vanished, without altering a live
    /// manual group. Injectable filesystem probe matches Swift's tests.
    pub fn reconcile_git_root(
        &mut self,
        id: TabId,
        root: Option<String>,
        directory_exists: impl Fn(&str) -> bool,
    ) {
        self.reconcile_repository_roots_with_known(
            id,
            RepositoryRoots {
                focused: root.clone(),
                primary: root.clone(),
                presentation: root,
            },
            None,
            &[],
            directory_exists,
        );
    }

    fn reconcile_repository_roots_with_known(
        &mut self,
        id: TabId,
        roots: RepositoryRoots,
        directory: Option<&Path>,
        recent: &[String],
        directory_exists: impl Fn(&str) -> bool,
    ) {
        let automatic = self.auto_repo_grouping;
        let Some(tab) = self.get_mut(id) else { return };
        let resolved = roots.primary.clone().or_else(|| {
            directory.and_then(|cwd| known_repo_root(cwd, tab.repo_group_id.as_deref(), recent))
        });
        let previous_group = tab.repo_group_id.clone();
        tab.git_root = roots.focused;
        tab.primary_git_root = roots.primary.clone();
        tab.presentation_git_root = roots.presentation;
        if automatic {
            tab.repo_group_id = resolved;
            tab.has_inherited_repo_group = false;
        } else if tab.has_inherited_repo_group && tab.repo_group_id != resolved {
            tab.repo_group_id = None;
            tab.has_inherited_repo_group = false;
        } else if let (Some(old), Some(live)) = (&tab.repo_group_id, &roots.primary)
            && !directory_exists(old)
            && old != live
            && directory_exists(live)
        {
            tab.repo_group_id = roots.primary;
            tab.has_inherited_repo_group = false;
        }
        let group = tab.repo_group_id.clone();
        if group != previous_group {
            // Changing the middle tab's group can split the remaining old
            // members. Keep Auto groups contiguous before joining the new one.
            if automatic && let Some(previous) = previous_group.as_deref() {
                self.coalesce_group(previous);
            }
            if let Some(group) = group {
                self.coalesce_group(&group);
            }
        }
    }

    /// Record activity. Returns whether the tab was idle until now, the only
    /// case in which activity changes the tab bar (it leaves the idle group).
    pub fn touch(&mut self, id: TabId, now: f64) -> bool {
        let was_idle = self.group_idle_tabs
            && Some(id) != self.selected
            && (self.forced_idle.contains(&id)
                || self
                    .get(id)
                    .is_some_and(|tab| now - tab.last_activity > self.idle_threshold_secs));
        if let Some(tab) = self.get_mut(id) {
            tab.last_activity = now;
        }
        self.forced_idle.remove(&id);
        was_idle
    }

    /// `forceTabIdle`: never the selected tab.
    pub fn force_idle(&mut self, id: TabId) {
        if self.selected != Some(id) && self.index_of(id).is_some() {
            self.forced_idle.insert(id);
        }
    }

    /// Idle tabs: not selected, and either forced idle or inactive for longer
    /// than the threshold. Empty when idle grouping is off.
    pub fn idle_ids(&self, now: f64) -> HashSet<TabId> {
        if !self.group_idle_tabs {
            return HashSet::new();
        }
        self.tabs
            .iter()
            .filter(|t| Some(t.id) != self.selected)
            .filter(|t| {
                self.forced_idle.contains(&t.id) || now - t.last_activity > self.idle_threshold_secs
            })
            .map(|t| t.id)
            .collect()
    }

    /// Items for the tab bar, from `TabBarLayout.displayItems`.
    pub fn display_items(&self, now: f64) -> Vec<TabBarLayoutItem<TabId>> {
        let layout: Vec<TabBarLayoutTab<TabId>> = self
            .tabs
            .iter()
            .map(|t| TabBarLayoutTab::new(t.id, t.repo_group_id.clone(), None))
            .collect();
        display_items(&layout, &self.idle_ids(now))
    }
}

/// `RepoTagChip.color(for:)`: the same repo always gets the same color
/// (FNV-1a of the path over the tab palette).
pub fn repo_group_color(group: &str) -> TabColor {
    let hash = group.bytes().fold(1_469_598_103_934_665_603u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(1_099_511_628_211)
    });
    TabColor::ALL[(hash % TabColor::ALL.len() as u64) as usize]
}

/// Last path component of a repo group id, as shown on the group tag.
pub fn repo_group_name(group: &str) -> &str {
    group
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(group)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state_with(n: u64) -> TabsState {
        let mut s = TabsState::new();
        for id in 1..=n {
            let color = s.next_color();
            s.add(TabMeta::new(id, color), true);
        }
        s
    }

    fn ids(s: &TabsState) -> Vec<TabId> {
        s.tabs().iter().map(|t| t.id).collect()
    }

    fn set_all_roots(s: &mut TabsState, id: TabId, root: &str) {
        let tab = s.get_mut(id).unwrap();
        tab.git_root = Some(root.to_string());
        tab.primary_git_root = Some(root.to_string());
        tab.presentation_git_root = Some(root.to_string());
    }

    #[test]
    fn new_tabs_go_to_end_and_cycle_colors() {
        let s = state_with(9);
        assert_eq!(ids(&s), (1..=9).collect::<Vec<_>>());
        assert_eq!(s.get(1).unwrap().color, TabColor::Blue);
        assert_eq!(s.get(9).unwrap().color, TabColor::Blue);
        assert_eq!(s.selected(), Some(9));
    }

    #[test]
    fn new_tab_after_current_when_inheriting_group() {
        let mut s = state_with(3);
        s.select(1);
        s.get_mut(1).unwrap().repo_group_id = Some("/r".into());
        s.add(TabMeta::new(10, TabColor::Blue), true);
        assert_eq!(ids(&s), vec![1, 10, 2, 3]);
        assert_eq!(s.get(10).unwrap().repo_group_id.as_deref(), Some("/r"));
    }

    #[test]
    fn new_tab_after_current_setting() {
        let mut s = state_with(3);
        s.new_tab_position = NewTabPosition::AfterCurrent;
        s.select(2);
        s.add(TabMeta::new(10, TabColor::Blue), false);
        assert_eq!(ids(&s), vec![1, 2, 10, 3]);
        assert_eq!(s.selected(), Some(2));
    }

    #[test]
    fn close_selects_left_neighbor() {
        let mut s = state_with(4);
        s.select(3);
        assert_eq!(s.close(3, None), CloseOutcome::Closed);
        assert_eq!(s.selected(), Some(2));
        s.select(1);
        s.close(1, None);
        assert_eq!(s.selected(), Some(2));
    }

    #[test]
    fn close_unselected_keeps_selection() {
        let mut s = state_with(3);
        s.select(3);
        s.close(1, None);
        assert_eq!(s.selected(), Some(3));
    }

    #[test]
    fn closing_last_tab_closes_window() {
        let mut s = state_with(1);
        assert_eq!(s.close(1, None), CloseOutcome::CloseWindow);
        assert_eq!(s.len(), 1);
    }

    #[test]
    fn token_opt_override_cycles() {
        use TabTokenOptOverride as O;
        use TokenOptimizationMode as M;
        assert_eq!(next_token_opt_override(M::Off, O::Default), None);
        assert_eq!(
            next_token_opt_override(M::AllTabs, O::Default),
            Some(O::ForceOff)
        );
        assert_eq!(
            next_token_opt_override(M::AllTabs, O::ForceOff),
            Some(O::Default)
        );
        assert_eq!(
            next_token_opt_override(M::AiOnly, O::Default),
            Some(O::ForceOff)
        );
        assert_eq!(
            next_token_opt_override(M::AiOnly, O::ForceOff),
            Some(O::ForceOn)
        );
        assert_eq!(
            next_token_opt_override(M::AiOnly, O::ForceOn),
            Some(O::Default)
        );
        assert_eq!(
            next_token_opt_override(M::Manual, O::Default),
            Some(O::ForceOn)
        );
        assert_eq!(
            token_opt_override_state(M::AllTabs, O::ForceOff),
            Some(false)
        );
        assert_eq!(token_opt_override_state(M::Manual, O::ForceOn), Some(true));
        assert_eq!(token_opt_override_state(M::AiOnly, O::Default), None);
    }

    #[test]
    fn rename_rules() {
        let mut meta = TabMeta::new(1, TabColor::Blue);
        meta.auto_color = Some(TabColor::Purple);
        // Unchanged title and color: nothing stored, auto color kept.
        meta.apply_rename(" Shell ", "Shell", TabColor::Blue);
        assert_eq!(meta.custom_title, None);
        assert_eq!(meta.effective_color(true), TabColor::Purple);
        assert_eq!(meta.effective_color(false), TabColor::Blue);
        // New title and color: stored, manual color beats auto.
        meta.apply_rename("api", "Shell", TabColor::Green);
        assert_eq!(meta.custom_title.as_deref(), Some("api"));
        assert!(meta.manual_color_override);
        assert_eq!(meta.auto_color, None);
        assert_eq!(meta.effective_color(true), TabColor::Green);
        // Empty title clears.
        meta.apply_rename("  ", "api", TabColor::Green);
        assert_eq!(meta.custom_title, None);
    }

    #[test]
    fn every_registry_tool_has_its_color() {
        for (name, color) in crate::ai::tool_registry::TAB_COLOR_MAP.iter() {
            if name.is_empty() {
                continue;
            }
            assert_eq!(
                auto_color_for_command(name, &[]),
                TabColor::from_name(color),
                "{name}"
            );
        }
        assert_eq!(auto_color_for_command("zsh", &[]), None);
        assert_eq!(auto_color_for_command("", &[]), None);
    }

    #[test]
    fn auto_color_from_command() {
        assert_eq!(
            auto_color_for_command("claude --resume x", &[]),
            Some(TabColor::Purple)
        );
        assert_eq!(auto_color_for_command("ls -la", &[]), None);
        let rules = vec![("my-agent".to_string(), TabColor::Orange)];
        assert_eq!(
            auto_color_for_command("npx my-agent run", &rules),
            Some(TabColor::Orange)
        );
    }

    #[test]
    fn replace_last_tab_with_fresh_one() {
        let mut s = state_with(1);
        s.get_mut(1).unwrap().custom_title = Some("old".into());
        assert!(s.replace(1, TabMeta::new(7, TabColor::Blue)));
        assert_eq!(ids(&s), vec![7]);
        assert_eq!(s.selected(), Some(7));
        assert_eq!(s.get(7).unwrap().custom_title, None);
        assert_eq!(s.closed_count(), 0);
        assert!(!s.replace(1, TabMeta::new(8, TabColor::Blue)));
    }

    #[test]
    fn reopen_restores_position() {
        let mut s = state_with(4);
        s.close(2, Some("/tmp".into()));
        let entry = s.reopen_closed(20).unwrap();
        assert_eq!(entry.directory.as_deref(), Some("/tmp"));
        assert_eq!(ids(&s), vec![1, 20, 3, 4]);
        assert_eq!(s.selected(), Some(20));
        assert!(s.reopen_closed(21).is_none());
    }

    #[test]
    fn next_previous_wrap() {
        let mut s = state_with(3);
        s.select(3);
        s.select_next();
        assert_eq!(s.selected(), Some(1));
        s.select_previous();
        assert_eq!(s.selected(), Some(3));
    }

    /// The workspace computes the target first so `select_tab` sees the
    /// move (switch animation): the target functions must not select.
    #[test]
    fn selection_targets_do_not_change_the_selection() {
        let mut s = state_with(3);
        s.select(3);
        assert_eq!(s.step_target(1), Some(1));
        assert_eq!(s.step_target(-1), Some(2));
        assert_eq!(s.number_target(2), Some(2));
        assert_eq!(s.number_target(9), None);
        assert_eq!(s.visible_number_target(1, 0.0), Some(1));
        assert_eq!(s.selected(), Some(3));
        assert_eq!(state_with(1).step_target(1), None);
    }

    #[test]
    fn select_number_is_one_based_and_ignores_out_of_range() {
        let mut s = state_with(3);
        s.select_number(1);
        assert_eq!(s.selected(), Some(1));
        s.select_number(9);
        assert_eq!(s.selected(), Some(1));
    }

    #[test]
    fn select_visible_number_follows_display_order_and_skips_idle_dropdown_tabs() {
        let mut s = state_with(5);
        s.select(1);
        for id in 1..=5 {
            s.touch(id, 0.0);
        }
        s.force_idle(2);
        s.force_idle(4);
        for id in [1, 3] {
            s.get_mut(id).unwrap().repo_group_id = Some("/repo".into());
        }

        assert!(s.select_visible_number(2, 1.0));
        assert_eq!(s.selected(), Some(3));
    }

    #[test]
    fn select_visible_number_preserves_one_based_nine_and_range_semantics() {
        let mut s = state_with(10);
        s.group_idle_tabs = false;
        s.select(2);

        assert!(s.select_visible_number(0, 1.0));
        assert_eq!(s.selected(), Some(1));
        assert!(!s.select_visible_number(11, 1.0));
        assert_eq!(s.selected(), Some(1));
        assert!(s.select_visible_number(9, 1.0));
        assert_eq!(s.selected(), Some(9));
    }

    #[test]
    fn group_all_same_repo_coalesces() {
        let mut s = state_with(4);
        set_all_roots(&mut s, 1, "/r");
        set_all_roots(&mut s, 3, "/r");
        s.group_all_same_repo(1);
        assert_eq!(ids(&s), vec![1, 3, 2, 4]);
        assert_eq!(s.group_members("/r"), vec![1, 3]);
        s.ungroup("/r");
        assert!(s.group_members("/r").is_empty());
    }

    #[test]
    fn move_group_as_block() {
        let mut s = state_with(5);
        for id in [2, 3] {
            s.get_mut(id).unwrap().repo_group_id = Some("/g".into());
        }
        s.move_group("/g", 3);
        assert_eq!(ids(&s), vec![1, 4, 5, 2, 3]);
    }

    #[test]
    fn idle_tabs_exclude_selected_and_respect_threshold() {
        let mut s = state_with(3);
        s.select(3);
        for id in 1..=3 {
            s.touch(id, 0.0);
        }
        assert!(s.idle_ids(10.0).is_empty());
        let idle = s.idle_ids(700.0);
        assert_eq!(idle, [1, 2].into_iter().collect());
        s.touch(1, 700.0);
        s.force_idle(1);
        s.force_idle(3);
        assert_eq!(s.idle_ids(701.0), [1, 2].into_iter().collect());
        s.group_idle_tabs = false;
        assert!(s.idle_ids(701.0).is_empty());
    }

    #[test]
    fn touch_reports_only_activity_that_leaves_the_idle_group() {
        let mut s = state_with(2);
        s.select(2);
        s.touch(1, 0.0);
        // Activity on an already active tab changes nothing the tab bar shows.
        assert!(!s.touch(1, 10.0));
        assert!(s.touch(1, 10.0 + s.idle_threshold_secs + 1.0));
        s.force_idle(1);
        assert!(s.touch(1, 2000.0));
        assert!(!s.touch(1, 2001.0));
        // The selected tab is never idle; nor is any tab without idle grouping.
        assert!(!s.touch(2, 9_999.0));
        s.group_idle_tabs = false;
        s.force_idle(1);
        assert!(!s.touch(1, 99_999.0));
    }

    #[test]
    fn display_items_follow_layout() {
        let mut s = state_with(3);
        s.select(1);
        for id in 1..=3 {
            s.touch(id, 0.0);
        }
        s.force_idle(2);
        let items = s.display_items(1.0);
        assert_eq!(
            items,
            vec![
                TabBarLayoutItem::IdleTabs,
                TabBarLayoutItem::Tab(1),
                TabBarLayoutItem::Tab(3),
                TabBarLayoutItem::NewTabButton
            ]
        );
    }

    #[test]
    fn automatic_grouping_keeps_primary_root_when_secondary_becomes_focused() {
        let mut s = state_with(2);
        s.set_auto_repo_grouping(true);
        s.set_repository_roots_in_directory(
            1,
            Some("/primary".into()),
            Some("/primary".into()),
            Some("/primary".into()),
            None,
            &[],
        );
        s.set_repository_roots_in_directory(
            2,
            Some("/primary".into()),
            Some("/primary".into()),
            Some("/primary".into()),
            None,
            &[],
        );
        assert_eq!(s.group_members("/primary"), vec![1, 2]);

        // Focusing a secondary split changes the ordinary UI root and display
        // root. Automatic grouping remains attached to the first terminal.
        s.set_repository_roots_in_directory(
            1,
            Some("/secondary".into()),
            Some("/primary".into()),
            Some("/display".into()),
            None,
            &[],
        );
        assert_eq!(s.group_members("/primary"), vec![1, 2]);
        assert_eq!(s.get(1).unwrap().git_root.as_deref(), Some("/secondary"));
        assert_eq!(
            s.get(1).unwrap().primary_git_root.as_deref(),
            Some("/primary")
        );
        assert_eq!(
            s.get(1).unwrap().presentation_git_root.as_deref(),
            Some("/display")
        );

        s.set_auto_repo_grouping(false);
        s.add_to_repo_group(1);
        assert_eq!(s.get(1).unwrap().repo_group_id.as_deref(), Some("/display"));
        assert_eq!(s.group_members("/primary"), vec![2]);
    }

    #[test]
    fn group_all_uses_each_display_root_and_does_not_fallback_for_non_repo_display() {
        let mut s = state_with(3);
        {
            let tab = s.get_mut(1).unwrap();
            tab.git_root = Some("/focused-one".into());
            tab.primary_git_root = Some("/primary-one".into());
            tab.presentation_git_root = Some("/display".into());
        }
        {
            let tab = s.get_mut(2).unwrap();
            tab.git_root = Some("/focused-two".into());
            tab.primary_git_root = Some("/primary-two".into());
            tab.presentation_git_root = Some("/display".into());
        }
        {
            let tab = s.get_mut(3).unwrap();
            tab.git_root = Some("/display".into());
            tab.primary_git_root = Some("/display".into());
            tab.presentation_git_root = None;
            tab.repo_group_id = Some("/preserved-manual".into());
        }

        s.group_all_same_repo(1);
        assert_eq!(s.group_members("/display"), vec![1, 2]);
        assert_eq!(
            s.get(3).unwrap().repo_group_id.as_deref(),
            Some("/preserved-manual")
        );
        s.add_to_repo_group(3);
        assert_eq!(
            s.get(3).unwrap().repo_group_id.as_deref(),
            Some("/preserved-manual")
        );
    }

    #[test]
    fn primary_root_changes_reconcile_without_falling_back_to_other_split_roots() {
        let mut s = state_with(1);
        s.set_auto_repo_grouping(true);
        s.set_repository_roots_in_directory(
            1,
            Some("/display-repo".into()),
            Some("/primary-repo".into()),
            Some("/display-repo".into()),
            Some(Path::new("/primary-repo/src")),
            &[],
        );
        assert_eq!(
            s.get(1).unwrap().repo_group_id.as_deref(),
            Some("/primary-repo")
        );

        s.set_repository_roots_in_directory(
            1,
            Some("/display-repo".into()),
            Some("/other-repo".into()),
            Some("/display-repo".into()),
            Some(Path::new("/other-repo/src")),
            &[],
        );
        assert_eq!(
            s.get(1).unwrap().repo_group_id.as_deref(),
            Some("/other-repo")
        );
        assert_eq!(s.get(1).unwrap().git_root.as_deref(), Some("/display-repo"));

        s.set_repository_roots_in_directory(
            1,
            Some("/display-repo".into()),
            None,
            Some("/display-repo".into()),
            Some(Path::new("/outside")),
            &[],
        );
        assert_eq!(s.get(1).unwrap().repo_group_id, None);
    }

    #[test]
    fn distinct_repo_roots_survive_close_reopen_and_window_transfer_metadata() {
        let mut s = state_with(2);
        {
            let tab = s.get_mut(1).unwrap();
            tab.git_root = Some("/focused".into());
            tab.primary_git_root = Some("/primary".into());
            tab.presentation_git_root = Some("/display".into());
        }
        assert_eq!(s.close(1, None), CloseOutcome::Closed);
        let reopened = s.reopen_closed(3).unwrap();
        assert_eq!(reopened.meta.git_root.as_deref(), Some("/focused"));
        assert_eq!(reopened.meta.primary_git_root.as_deref(), Some("/primary"));
        assert_eq!(
            reopened.meta.presentation_git_root.as_deref(),
            Some("/display")
        );
        let transferred = s.take(3).unwrap();
        assert_eq!(transferred.git_root.as_deref(), Some("/focused"));
        assert_eq!(transferred.primary_git_root.as_deref(), Some("/primary"));
        assert_eq!(
            transferred.presentation_git_root.as_deref(),
            Some("/display")
        );
    }

    #[test]
    fn auto_grouping_on_git_root_change() {
        let mut s = state_with(3);
        s.auto_repo_grouping = true;
        s.set_git_root(3, Some("/r".into()));
        s.set_git_root(1, Some("/r".into()));
        assert_eq!(s.group_members("/r"), vec![1, 3]);
        assert_eq!(ids(&s), vec![1, 3, 2]);
    }

    #[test]
    fn automatic_root_change_keeps_remaining_old_group_contiguous_and_selection() {
        let mut s = state_with(3);
        s.auto_repo_grouping = true;
        for tab in s.tabs.iter_mut() {
            tab.repo_group_id = Some("/repo-a".into());
            tab.primary_git_root = Some("/repo-a".into());
        }
        s.select(2);

        s.set_repository_roots_in_directory(
            2,
            Some("/repo-b".into()),
            Some("/repo-b".into()),
            Some("/repo-b".into()),
            Some(Path::new("/repo-b/src")),
            &[],
        );

        assert_eq!(s.selected(), Some(2));
        assert_eq!(ids(&s), vec![1, 3, 2]);
        assert_eq!(s.group_members("/repo-a"), vec![1, 3]);
        assert_eq!(s.group_members("/repo-b"), vec![2]);
    }

    #[test]
    fn automatic_root_loss_keeps_remaining_old_group_contiguous_and_selection() {
        let mut s = state_with(3);
        s.auto_repo_grouping = true;
        for tab in s.tabs.iter_mut() {
            tab.repo_group_id = Some("/repo-a".into());
            tab.primary_git_root = Some("/repo-a".into());
        }
        s.select(2);

        s.set_repository_roots_in_directory(2, None, None, None, Some(Path::new("/outside")), &[]);

        assert_eq!(s.selected(), Some(2));
        assert_eq!(ids(&s), vec![1, 3, 2]);
        assert_eq!(s.group_members("/repo-a"), vec![1, 3]);
        assert!(s.get(2).unwrap().repo_group_id.is_none());
    }

    #[test]
    fn attached_and_restored_tabs_seed_groups_even_with_automatic_mode_off() {
        let mut s = state_with(3);
        set_all_roots(&mut s, 1, "/repo");
        set_all_roots(&mut s, 2, "/repo");
        set_all_roots(&mut s, 3, "/other");
        s.get_mut(3).unwrap().repo_group_id = Some("/manual".into());
        for id in 1..=3 {
            s.setup_repo_group(id);
        }
        assert_eq!(s.group_members("/repo"), vec![1, 2]);
        assert_eq!(s.get(3).unwrap().repo_group_id.as_deref(), Some("/manual"));
    }

    #[test]
    fn enabling_automatic_grouping_reconciles_existing_roots_and_stale_restore_tags() {
        let mut s = state_with(3);
        set_all_roots(&mut s, 1, "/repo");
        set_all_roots(&mut s, 3, "/repo");
        s.get_mut(2).unwrap().repo_group_id = Some("/stale".into());
        s.set_auto_repo_grouping(true);
        assert_eq!(s.group_members("/repo"), vec![1, 3]);
        assert_eq!(ids(&s), vec![1, 3, 2]);
        assert_eq!(s.get(2).unwrap().repo_group_id, None);
        s.set_auto_repo_grouping(false);
        assert_eq!(s.group_members("/repo"), vec![1, 3]);
    }

    #[test]
    fn unchanged_known_root_repairs_missing_automatic_group() {
        let mut s = state_with(1);
        s.auto_repo_grouping = true;
        s.get_mut(1).unwrap().git_root = Some("/repo".into());
        s.set_git_root(1, Some("/repo".into()));
        assert_eq!(s.get(1).unwrap().repo_group_id.as_deref(), Some("/repo"));
        s.set_git_root(1, None);
        assert_eq!(s.get(1).unwrap().repo_group_id, None);
    }

    #[test]
    fn inherited_groups_require_a_directory_inside_the_selected_repo() {
        let mut s = state_with(1);
        s.get_mut(1).unwrap().repo_group_id = Some("/repo".into());
        s.add_in_directory(
            TabMeta::new(2, TabColor::Blue),
            Path::new("/repo/src/../tests"),
            false,
        );
        assert_eq!(s.get(2).unwrap().repo_group_id.as_deref(), Some("/repo"));
        assert!(s.get(2).unwrap().has_inherited_repo_group);
        s.add_in_directory(
            TabMeta::new(3, TabColor::Blue),
            Path::new("/repository"),
            false,
        );
        assert_eq!(s.get(3).unwrap().repo_group_id, None);
        s.add_in_directory(
            TabMeta::new(4, TabColor::Blue),
            Path::new("/repo/../elsewhere"),
            false,
        );
        assert_eq!(s.get(4).unwrap().repo_group_id, None);
    }

    #[test]
    fn inherited_groups_detach_after_the_shell_leaves_but_manual_groups_stay() {
        let mut s = state_with(1);
        s.get_mut(1).unwrap().repo_group_id = Some("/repo".into());
        s.add_in_directory(
            TabMeta::new(2, TabColor::Blue),
            Path::new("/repo/src"),
            false,
        );
        s.reconcile_git_root(2, Some("/different".into()), |_| true);
        assert_eq!(s.get(2).unwrap().repo_group_id, None);
        assert!(!s.get(2).unwrap().has_inherited_repo_group);
        s.reconcile_git_root(1, Some("/different".into()), |_| true);
        assert_eq!(s.get(1).unwrap().repo_group_id.as_deref(), Some("/repo"));
    }

    #[test]
    fn vanished_manual_repo_group_heals_to_a_live_root_and_coalesces() {
        let mut s = state_with(3);
        s.get_mut(1).unwrap().repo_group_id = Some("/old".into());
        s.get_mut(3).unwrap().repo_group_id = Some("/new".into());
        s.reconcile_git_root(1, Some("/new".into()), |root| root == "/new");
        assert_eq!(s.group_members("/new"), vec![1, 3]);
        assert_eq!(ids(&s), vec![1, 3, 2]);
        s.get_mut(2).unwrap().repo_group_id = Some("/other-missing".into());
        s.reconcile_git_root(2, Some("/also-missing".into()), |_| false);
        assert_eq!(
            s.get(2).unwrap().repo_group_id.as_deref(),
            Some("/other-missing")
        );
    }

    #[test]
    fn explicitly_grouped_tabs_stop_being_provisional() {
        let mut s = state_with(1);
        s.get_mut(1).unwrap().repo_group_id = Some("/repo".into());
        s.add_in_directory(TabMeta::new(2, TabColor::Blue), Path::new("/repo"), false);
        set_all_roots(&mut s, 2, "/repo");
        s.add_to_repo_group(2);
        assert!(!s.get(2).unwrap().has_inherited_repo_group);
        s.reconcile_git_root(2, Some("/different".into()), |_| true);
        assert_eq!(s.get(2).unwrap().repo_group_id.as_deref(), Some("/repo"));
    }

    #[test]
    fn known_root_fallback_prefers_existing_enclosing_root_then_most_specific_recent_root() {
        let repo = Path::new("/repo").components().collect::<PathBuf>();
        let nested = Path::new("/repo/nested").components().collect::<PathBuf>();
        let roots = vec!["/repo".into(), "/repo/nested".into()];
        assert_eq!(
            known_repo_root(Path::new("/repo/nested/src"), None, &roots).as_deref(),
            nested.to_str()
        );
        assert_eq!(
            known_repo_root(Path::new("/repo/nested/src"), Some("/repo"), &roots).as_deref(),
            repo.to_str()
        );
        assert_eq!(
            known_repo_root(Path::new("/repository"), Some("/repo"), &roots),
            None
        );
        assert_eq!(
            known_repo_root(Path::new("/repo/../elsewhere"), Some("/repo"), &roots),
            None
        );
    }

    #[test]
    fn automatic_mode_uses_known_roots_without_falsifying_live_git_metadata() {
        let repo = Path::new("/repo").components().collect::<PathBuf>();
        let nested = Path::new("/repo/nested").components().collect::<PathBuf>();
        let mut s = state_with(2);
        s.get_mut(1).unwrap().repo_group_id = Some("/repo".into());
        let directories = vec![
            (1, PathBuf::from("/repo/src")),
            (2, PathBuf::from("/repo/nested/test")),
        ];
        s.set_auto_repo_grouping_in_directories(true, &directories, &["/repo/nested".into()]);
        assert_eq!(s.get(1).unwrap().repo_group_id.as_deref(), repo.to_str());
        assert_eq!(s.get(2).unwrap().repo_group_id.as_deref(), nested.to_str());
        assert_eq!(s.get(1).unwrap().git_root, None);
        s.set_git_root_in_directory(1, None, Some(Path::new("/different")), &[]);
        assert_eq!(s.get(1).unwrap().repo_group_id, None);
    }

    #[test]
    fn move_selected_swaps_with_neighbor() {
        let mut s = state_with(3);
        s.select(1);
        assert!(!s.move_selected(-1));
        assert!(s.move_selected(1));
        assert_eq!(ids(&s), vec![2, 1, 3]);
        assert!(s.move_selected(1));
        assert!(!s.move_selected(1));
        assert_eq!(ids(&s), vec![2, 3, 1]);
        assert_eq!(s.selected(), Some(1));
    }

    #[test]
    fn repo_group_color_is_stable_fnv1a() {
        // FNV-1a("") is the offset basis; 1469598103934665603 % 8 == 3.
        assert_eq!(repo_group_color(""), TabColor::Yellow);
        assert_eq!(repo_group_color("/r/a"), repo_group_color("/r/a"));
    }

    #[test]
    fn repo_group_name_is_last_component() {
        assert_eq!(repo_group_name("/Users/me/code/chau7"), "chau7");
        assert_eq!(repo_group_name("/Users/me/code/chau7/"), "chau7");
    }
}
