//! Settings profiles and SSH connections: the app-wide state and the
//! operations the settings window, the SSH manager and the terminal tabs use
//! (`FeatureSettings` profile management, `ProfileAutoSwitcher`).

pub mod ssh_config_sync;
pub mod ssh_manager;

use std::collections::HashMap;

use chau7_next_core::profile_rules::ProfileSwitchTrigger;
use chau7_next_core::settings_profiles::{AutoSwitcher, ProfileStore, RuleContext, SwitchAction};
use chau7_next_core::ssh_connections::SshConnections;
use gpui::{App, Global};

use crate::settings::Settings;
use crate::settings_window;
use crate::workspace::AppData;

/// Saved profiles, rules and the auto-switcher.
pub struct ProfilesState {
    pub store: ProfileStore,
    pub switcher: AutoSwitcher,
}

impl Global for ProfilesState {}

/// The saved SSH connections.
pub struct SshState(pub SshConnections);

impl Global for SshState {}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Load the saved profiles. Call once at startup, after `AppData` is set.
pub fn init(cx: &mut App) {
    let path = cx.global::<AppData>().root.profiles_file();
    let mut store = ProfileStore::load(&path);
    let existed = !store.profiles.is_empty();
    store.ensure_default(&Settings::get(cx).to_profile_text(), now());
    if !existed {
        save_store(&store, cx);
    }
    let ssh = SshConnections::load(&cx.global::<AppData>().root.ssh_connections_file());
    cx.set_global(SshState(ssh));
    cx.set_global(ProfilesState {
        store,
        switcher: AutoSwitcher::default(),
    });
    ssh_config_sync::start(cx);
}

fn save_store(store: &ProfileStore, cx: &App) {
    let path = cx.global::<AppData>().root.profiles_file();
    if let Err(err) = store.save(&path) {
        log::warn!("saving profiles: {err}");
    }
}

/// Save the profiles and redraw the windows that show them.
pub fn commit(cx: &mut App) {
    save_store(&cx.global::<ProfilesState>().store, cx);
    cx.refresh_windows();
}

/// Change the store (profiles, rules, the switch), then save it.
pub fn edit(cx: &mut App, change: impl FnOnce(&mut ProfileStore)) {
    change(&mut cx.global_mut::<ProfilesState>().store);
    commit(cx);
}

pub fn active_name(cx: &App) -> Option<String> {
    cx.try_global::<ProfilesState>()
        .and_then(|s| s.store.active_profile())
        .map(|p| p.name.clone())
}

/// Apply a profile's settings and make it the active one.
pub fn load_profile(id: &str, cx: &mut App) -> bool {
    let Some(profile) = cx.global::<ProfilesState>().store.by_id(id).cloned() else {
        return false;
    };
    let loaded = Settings::from_profile_text_local(&profile.config, Settings::get(cx));
    settings_window::update(cx, |s| *s = loaded);
    edit(cx, |store| store.active = Some(profile.id.clone()));
    log::info!("profiles: loaded '{}'", profile.name);
    true
}

/// "Create New Profile...": save the current settings under a name and use it.
pub fn create_profile(name: &str, icon: &str, cx: &mut App) -> Option<String> {
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    let config = Settings::get(cx).to_profile_text();
    let mut id = String::new();
    edit(cx, |store| {
        id = store.create(name, icon, config, now());
        store.active = Some(id.clone());
    });
    Some(id)
}

/// "Save Current": copy the settings into the active profile.
pub fn save_current(cx: &mut App) {
    let config = Settings::get(cx).to_profile_text();
    edit(cx, |store| {
        if let Some(id) = store.active.clone() {
            store.save_current(&id, config);
        }
    });
}

pub fn delete_profile(id: &str, cx: &mut App) {
    let id = id.to_string();
    edit(cx, |store| store.delete(&id));
}

/// "Deactivate Profile": keep the settings, forget which profile they came from.
pub fn deactivate(cx: &mut App) {
    edit(cx, |store| store.active = None);
}

/// Turn automatic switching on or off; off goes back to the previous profile.
pub fn set_auto_switch(enabled: bool, cx: &mut App) {
    edit(cx, |store| store.auto_switch = enabled);
    if !enabled {
        restore_previous(cx);
    }
}

fn run(action: SwitchAction, cx: &mut App) {
    let (SwitchAction::Load(name) | SwitchAction::Restore(name)) = action else {
        return;
    };
    let id = cx
        .global::<ProfilesState>()
        .store
        .by_name(&name)
        .map(|p| p.id.clone());
    if let Some(id) = id {
        load_profile(&id, cx);
    }
}

/// A tab changed directory or what runs in it: check the rules
/// (`ProfileAutoSwitcher.evaluateRules`). `shell_pid` is the tab's shell:
/// the programs it runs give the "running process" names, the SSH host (an
/// `ssh` among them) and the environment (the shell's, overridden by its
/// programs'), read in the background and only when a rule looks at them.
pub fn evaluate(directory: Option<String>, shell_pid: Option<u32>, cx: &mut App) {
    if cx.try_global::<ProfilesState>().is_none() || !cx.global::<ProfilesState>().store.auto_switch
    {
        return;
    }
    let needs_processes = cx.global::<ProfilesState>().store.rules.iter().any(|rule| {
        rule.is_enabled
            && matches!(
                rule.trigger,
                ProfileSwitchTrigger::SshHost { .. }
                    | ProfileSwitchTrigger::ProcessRunning { .. }
                    | ProfileSwitchTrigger::EnvironmentVariable { .. }
            )
    });
    let shell_pid = shell_pid.filter(|pid| needs_processes && *pid != 0);
    let home = cx
        .global::<AppData>()
        .root
        .home()
        .to_string_lossy()
        .into_owned();
    cx.spawn(async move |cx| {
        let context = cx
            .background_executor()
            .spawn(async move { rule_context(directory, shell_pid, home) })
            .await;
        cx.update(|cx| apply_rules(context, cx));
    })
    .detach();
}

/// What the rules look at for a tab whose shell is `shell_pid` (none: only
/// the directory).
fn rule_context(directory: Option<String>, shell_pid: Option<u32>, home: String) -> RuleContext {
    use crate::platform::process;
    let Some(shell_pid) = shell_pid else {
        return RuleContext {
            directory,
            home: Some(home),
            ..RuleContext::default()
        };
    };
    let tree = process::process_tree(shell_pid);
    let mut processes = Vec::new();
    let mut ssh_host = None;
    let mut environment = HashMap::new();
    for (index, pid) in tree.iter().enumerate() {
        if index > 0
            && let Some(name) = process::process_name(*pid)
        {
            processes.push(name);
        }
        if let Some((args, env)) = process::process_args_env(*pid) {
            if ssh_host.is_none() && index > 0 {
                ssh_host = chau7_next_core::procargs::ssh_host_from_args(&args);
            }
            environment.extend(env);
        }
    }
    RuleContext {
        directory,
        ssh_host,
        processes: Some(processes),
        environment: (!environment.is_empty()).then_some(environment),
        home: Some(home),
    }
}

fn apply_rules(context: RuleContext, cx: &mut App) {
    if cx.try_global::<ProfilesState>().is_none() {
        return;
    }
    let active = active_name(cx);
    let state = cx.global_mut::<ProfilesState>();
    let action = state
        .switcher
        .evaluate(&state.store, &context, active.as_deref());
    run(action, cx);
    cx.refresh_windows();
}

/// Keychain service of the saved SSH passwords (`com.chau7.ssh` in Swift;
/// Chau7 Next keeps its own items, see `platform::secrets`).
const SSH_PASSWORD_SERVICE: &str = "ssh";

/// Store the password of a connection in the Keychain. API only, as in Swift:
/// nothing in the interface asks for a password.
#[allow(dead_code)]
pub fn store_ssh_password(connection_id: &str, password: &str) -> crate::platform::Result<()> {
    crate::platform::secrets::current().set(SSH_PASSWORD_SERVICE, connection_id, password)
}

/// The stored password of a connection.
#[allow(dead_code)]
pub fn ssh_password(connection_id: &str) -> crate::platform::Result<Option<String>> {
    crate::platform::secrets::current().get(SSH_PASSWORD_SERVICE, connection_id)
}

/// Forget the stored password of a connection.
#[allow(dead_code)]
pub fn remove_ssh_password(connection_id: &str) -> crate::platform::Result<()> {
    crate::platform::secrets::current().delete(SSH_PASSWORD_SERVICE, connection_id)
}

/// "Restore" in the auto-switch banner.
pub fn restore_previous(cx: &mut App) {
    let state = cx.global_mut::<ProfilesState>();
    let action = state.switcher.restore(&state.store);
    run(action, cx);
    cx.refresh_windows();
}

/// Change the SSH connections, save them and redraw.
pub fn ssh_edit(cx: &mut App, change: impl FnOnce(&mut SshConnections)) {
    change(&mut cx.global_mut::<SshState>().0);
    let path = cx.global::<AppData>().root.ssh_connections_file();
    if let Err(err) = cx.global::<SshState>().0.save(&path) {
        log::warn!("saving SSH connections: {err}");
    }
    cx.refresh_windows();
}

/// The window and workspace in front, for opening a tab from another window.
pub fn frontmost_workspace(
    cx: &App,
) -> Option<(
    gpui::AnyWindowHandle,
    gpui::Entity<crate::workspace::Workspace>,
)> {
    let live = AppData::live(cx);
    for handle in cx.window_stack().unwrap_or_default() {
        if let Some(found) = live.iter().find(|(h, _)| *h == handle) {
            return Some(found.clone());
        }
    }
    live.into_iter().next()
}

/// Open a new tab in the front window and type `command` (Swift `connect`).
pub fn run_in_new_tab(command: String, cx: &mut App) -> bool {
    let Some((handle, ws)) = frontmost_workspace(cx) else {
        return false;
    };
    handle
        .update(cx, |_, window, cx| {
            ws.update(cx, |ws, cx| ws.run_in_new_tab(&command, None, window, cx))
        })
        .is_ok()
}

/// `ssh ...` for a saved connection, and record the time.
pub fn connect(id: &str, cx: &mut App) -> bool {
    let Some(connection) = cx.global::<SshState>().0.get(id).cloned() else {
        return false;
    };
    let home = cx
        .global::<AppData>()
        .root
        .home()
        .to_string_lossy()
        .into_owned();
    let command = format!("{}\r", connection.ssh_command(&home));
    let id = id.to_string();
    ssh_edit(cx, |ssh| ssh.mark_connected(&id, now()));
    run_in_new_tab(command, cx)
}
