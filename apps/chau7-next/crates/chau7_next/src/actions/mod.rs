//! Actions. Default key bindings are in `keymap.rs`, the menu bar in
//! `menus.rs`. A new action is declared here, bound in `keymap.rs`, listed in
//! `menus.rs`, and handled by a `register_*_actions` function in
//! `workspace/` (or `main.rs` for app-wide actions).

mod keymap;
mod menus;
mod tab_actions;

use gpui::{Action, EntityId, actions};

pub use keymap::{bind_keys, bind_shortcut_settings};
pub use menus::app_menus;
pub use tab_actions::*;

use crate::tab_bar::TabId;

actions!(
    chau7,
    [
        NewTab,
        CloseTab,
        ReopenClosedTab,
        NextTab,
        PreviousTab,
        RenameTab,
        NewWindow,
        CloseWindow,
        Quit,
        SplitRight,
        SplitDown,
        ClosePane,
        FocusNextPane,
        FocusPreviousPane,
        Copy,
        Paste,
        SelectAll,
        ClearScrollback,
        ToggleSearch,
        FindNext,
        FindPrevious,
        ToggleSnippets,
        ToggleCommandPalette,
        IncreaseFontSize,
        DecreaseFontSize,
        ResetFontSize,
        ToggleFullScreen,
        OpenConfigFile,
        OpenSettings,
        ReloadConfig,
        ShowAbout,
        Minimize,
        Zoom,
        BringAllToFront,
        RefreshTabBar,
        SeedDebugTabs,
        ToggleBroadcast,
        ShowClipboardHistory,
        ShowSshHosts,
        ShowCommandHistory,
        ScrollToTop,
        ScrollToBottom,
        // View menu.
        DataExplorer,
        ShowTerminalAnalytics,
        OpenTextEditor,
        OpenFilePreview,
        OpenDiffViewer,
        OpenRepositoryPane,
        AppendSelectionToEditor,
        ShowChangedFiles,
        // App menu.
        ShowAllApps,
        // Help menu.
        ShowWelcome,
        ShowHelp,
        ShowTechnologyLicenses,
        ImportTerminalProfiles,
        ReportIssue,
        ToggleDebugConsole,
    ]
);

// Keyboard and terminal input (`terminal/input.rs`, `terminal/mouse.rs`,
// `workspace/keys.rs`).
actions!(
    chau7,
    [
        Cut,
        PasteEscaped,
        ClearScreen,
        UseSelectionForFind,
        PreviousInputLine,
        NextInputLine,
        AutoFillFromPasswords,
        ShowKeyboardShortcuts,
        SendInterrupt,
        SendEndOfFile,
        SendSuspend,
        ClearLine,
        ClearWord,
        ExportText,
        HideApp,
        HideOtherApps,
        PrintTerminal,
    ]
);

/// Terminal context menu (right click): the chosen item.
#[derive(Clone, PartialEq, Debug, Action)]
#[action(namespace = chau7, no_json)]
pub struct TerminalMenu(pub TerminalMenuOp);

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum TerminalMenuOp {
    Copy,
    Paste,
    PasteEscaped,
    SelectAll,
    AutoFill,
    ClearScreen,
    ClearScrollback,
}

/// Select tab N (1-based).
#[derive(Clone, PartialEq, Debug, Action)]
#[action(namespace = chau7, no_json)]
pub struct SelectTabNumber(pub usize);

/// Tab context menu: the target tab travels with the action.
#[derive(Clone, PartialEq, Debug, Action)]
#[action(namespace = chau7, no_json)]
pub struct TabMenu {
    pub tab: TabId,
    pub op: TabMenuOp,
}

#[derive(Clone, PartialEq, Debug)]
pub enum TabMenuOp {
    Rename,
    Close,
    AddToRepoGroup,
    RemoveFromRepoGroup,
    GroupAllSameRepo,
    MoveToIdle,
    /// Move this tab to the identified window; `None` opens a new window.
    MoveToWindow(Option<EntityId>),
    /// Move this tab's group to another window.
    MoveGroupToWindow(Option<EntityId>),
    SetColor(chau7_next_core::tabs_state::TabColor),
    ToggleBroadcastInclusion,
}

/// Group bracket context menu.
#[derive(Clone, PartialEq, Debug, Action)]
#[action(namespace = chau7, no_json)]
pub struct GroupMenu {
    pub group: String,
    pub op: GroupMenuOp,
}

#[derive(Clone, PartialEq, Debug)]
pub enum GroupMenuOp {
    MuteNotifications,
    SnoozeNotifications(u32),
    UnmuteNotifications,
    Ungroup,
    CloseGroup,
    MoveToWindow(Option<EntityId>),
}

// (dev) Feature profiler report. Minimal mode (Cmd+Shift+M) is declared
// with the tab actions.
actions!(chau7, [ShowFeatureProfiler]);
