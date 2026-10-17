//! Actions of the snippets, SSH and command guard features. Declared here,
//! not in `actions/mod.rs`, so those features can grow without touching the
//! shared action list (the palette's other commands are in `actions`). Handlers are in `workspace/pickers.rs` (and its
//! children); default keys are bound by [`bind_keys`].

use gpui::{KeyBinding, actions};

actions!(
    chau7_commands,
    [
        /// "Manage Snippets..." (the snippets manager window).
        ManageSnippets,
        /// "Migrate Snippets to Clean JSON".
        MigrateSnippets,
        /// "Reload Snippets".
        ReloadSnippets,
        /// "SSH Connections..." (the connection manager window).
        ShowSshManager,
        /// Run the command guard's choice "Execute" (confirmation dialog).
        GuardExecute,
        /// Command guard: "Cancel".
        GuardCancel,
        /// "Force Refresh Tab".
        ForceRefreshTab,
    ]
);

/// App-wide handlers: the windows these actions open.
pub fn register(cx: &mut gpui::App) {
    cx.on_action(|_: &ManageSnippets, cx| crate::snippets::manager::open(cx));
    cx.on_action(|_: &ShowSshManager, cx| crate::profiles::ssh_manager::open(cx));
}

/// Keys of the command guard dialog. Shift+Cmd+O (SSH manager) is in the
/// main keymap (`actions/keymap.rs`).
pub fn bind_keys(cx: &mut gpui::App) {
    cx.bind_keys([
        KeyBinding::new("enter", GuardExecute, Some("DangerGuard")),
        KeyBinding::new("escape", GuardCancel, Some("DangerGuard")),
    ]);
}
