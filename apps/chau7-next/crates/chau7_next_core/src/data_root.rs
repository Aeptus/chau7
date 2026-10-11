//! Every path Chau7 Next reads or writes on disk.
//!
//! Chau7 Next ships side by side with the Swift app (see
//! `docs/rust-port/DUAL-SHIP.md`). The two must never write to each other's
//! files or bind each other's sockets, so no other module builds a path by
//! hand: everything goes through [`DataRoot`]. A test in this module scans the
//! workspace sources and fails if a path belonging to the Swift app shows up
//! anywhere else.
//!
//! Layout (macOS, defaults):
//!
//! | Purpose | Chau7 (Swift) | Chau7 Next |
//! |---|---|---|
//! | Config, snippets, sockets | `~/.chau7/` | `~/.chau7-next/` |
//! | App state (tabs, windows) | UserDefaults `com.chau7.app` | `~/Library/Application Support/Chau7 Next/` |
//!
//! `CHAU7_NEXT_HOME_ROOT` overrides the home directory, mirroring
//! `CHAU7_HOME_ROOT` in `Chau7Core/RuntimeIsolation.swift`. Tests and CI use it
//! to prove nothing is written outside a temporary directory.

use std::path::{Path, PathBuf};

/// Environment variable that redirects the home directory (tests, CI).
pub const HOME_ROOT_ENV: &str = "CHAU7_NEXT_HOME_ROOT";

/// Bundle identifier of the macOS app bundle.
pub const BUNDLE_ID: &str = "com.chau7.next";

/// Name shown to users and used for the per-OS application data folder.
pub const APP_NAME: &str = "Chau7 Next";

/// Server name Chau7 Next uses when it registers itself with AI CLIs.
/// The Swift app registers `chau7`; Chau7 Next must never touch that entry.
pub const MCP_SERVER_NAME: &str = "chau7-next";

/// Read-only Swift hook identity for coexistence checks and exact ownership fixtures.
pub const SWIFT_CLAUDE_HOOK_HELPER: &str = "chau7-claude-hook";

/// Folder of a repository's snippets (one JSON per snippet), relative to the
/// git root. The repo belongs to the user, so both apps share it.
pub const DEFAULT_REPO_SNIPPET_PATH: &str = ".chau7/snippets";

/// Resolved locations for one run of the app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataRoot {
    home: PathBuf,
    config_dir: PathBuf,
    state_dir: PathBuf,
}

/// Per-repo folder shared with the Swift app on purpose: it belongs to the
/// user's project, not to either app's data.
const REPO_FOLDER: &str = ".chau7";

/// `{directory}/.chau7/config.toml`: the per-repo config of a project.
pub fn repo_config_path(directory: &Path) -> PathBuf {
    directory.join(REPO_FOLDER).join("config.toml")
}

/// The per-repo snippets folder, relative to a repo (`repoSnippetPath` default).
pub fn default_repo_snippet_path() -> String {
    format!("{REPO_FOLDER}/snippets")
}

impl DataRoot {
    /// Resolve paths from the real environment.
    pub fn from_env() -> Self {
        let home = std::env::var_os(HOME_ROOT_ENV)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(home_dir)
            .unwrap_or_else(std::env::temp_dir);
        let overridden = std::env::var_os(HOME_ROOT_ENV).is_some_and(|v| !v.is_empty());
        Self::with_home(home, overridden)
    }

    /// Resolve paths for a given home directory. When `isolated` is true the
    /// per-OS state folder is also placed under `home`, so a test never
    /// touches the real user profile.
    pub fn with_home(home: PathBuf, isolated: bool) -> Self {
        let config_dir = home.join(".chau7-next");
        let state_dir = if isolated {
            home.join(".chau7-next-state")
        } else {
            platform_state_dir(&home)
        };
        Self {
            home,
            config_dir,
            state_dir,
        }
    }

    /// The home directory every other path is derived from.
    pub fn home(&self) -> &Path {
        &self.home
    }

    /// `~/.chau7-next`: config, snippets, helper binaries.
    pub fn config_dir(&self) -> &Path {
        &self.config_dir
    }

    /// Per-OS application state folder (window and tab restore, logs).
    pub fn state_dir(&self) -> &Path {
        &self.state_dir
    }

    pub fn config_file(&self) -> PathBuf {
        self.config_dir.join("config.toml")
    }

    /// User repository skill sources are shared project inputs and read only.
    pub fn repo_skills_source(repo_root: &Path) -> PathBuf {
        repo_root.join(REPO_FOLDER).join("skills")
    }

    /// Read-only ownership check: Next must preserve production skill installations.
    pub fn swift_skill_manifest_path(skill_directory: &Path) -> PathBuf {
        skill_directory.join(".chau7-skill.json")
    }

    pub fn skill_staging_dir(&self) -> PathBuf {
        self.config_dir.join("tmp").join("skills")
    }

    pub fn skill_backups_dir(&self) -> PathBuf {
        self.config_dir.join("backups").join("skills")
    }

    pub fn snippets_file(&self) -> PathBuf {
        self.config_dir.join("snippets.json")
    }

    /// The command guard's allow, block and per-directory lists.
    pub fn dangerous_guard_file(&self) -> PathBuf {
        self.config_dir.join("dangerous_guard.json")
    }

    /// Saved settings profiles (`settings.profiles`).
    pub fn profiles_file(&self) -> PathBuf {
        self.config_dir.join("profiles.json")
    }

    /// SSH connections of the connection manager.
    pub fn ssh_connections_file(&self) -> PathBuf {
        self.config_dir.join("ssh_connections.json")
    }

    /// Notification installation belongs to Next; provider and Swift files are read only.
    pub fn notification_hooks_dir(&self) -> PathBuf {
        self.config_dir.join("notification-hooks")
    }

    pub fn claude_hook_overlay(&self) -> PathBuf {
        self.notification_hooks_dir().join("claude-settings.json")
    }

    pub fn next_claude_hook_events_file(&self) -> PathBuf {
        self.state_dir.join("claude-events.jsonl")
    }

    pub fn bin_dir(&self) -> PathBuf {
        self.config_dir.join("bin")
    }

    /// Startup files for shell integration (see `shell_integration`).
    pub fn shell_integration_dir(&self) -> PathBuf {
        self.config_dir.join("shell")
    }

    /// Reloadable per-tab zsh/bash history, always owned by Next.
    pub fn shell_histories_dir(&self) -> PathBuf {
        self.config_dir.join("history")
    }

    /// Commands run in Chau7 Next shells (written by the shell integration).
    pub fn history_file(&self) -> PathBuf {
        self.config_dir.join("history.tsv")
    }

    pub fn mcp_socket(&self) -> PathBuf {
        self.config_dir.join("mcp.sock")
    }

    pub fn session_file(&self) -> PathBuf {
        self.state_dir.join("session.json")
    }

    pub fn log_file(&self) -> PathBuf {
        self.state_dir.join("chau7-next.log")
    }

    /// A repository's own snippets file. It belongs to the user's repo and
    /// the Swift app migrates it; Chau7 Next only reads it.
    pub fn repo_snippets_file(repo_root: &Path) -> PathBuf {
        repo_root.join(".chau7").join("snippets.json")
    }

    /// User snippets: one JSON file per snippet.
    pub fn user_snippets_dir(&self) -> PathBuf {
        self.config_dir.join("snippets").join("global")
    }

    /// Profile snippets: one JSON file per snippet.
    pub fn profile_snippets_dir(&self) -> PathBuf {
        self.config_dir.join("snippets").join("default")
    }

    /// The Swift app's snippet folders (`global`, `default`), read once to
    /// import and never written. Returned as `(source, destination)`.
    pub fn importable_snippet_dirs(&self) -> Vec<(PathBuf, PathBuf)> {
        let base = swift_support_dir(&self.home).join("snippets");
        vec![
            (base.join("global"), self.user_snippets_dir()),
            (base.join("default"), self.profile_snippets_dir()),
        ]
    }

    /// The Swift app's pre-split single files (`snippets/global.json`,
    /// `snippets/default.json`), which Swift splits into the folders above
    /// the next time it runs. Read once to import (like the folders) and
    /// never written. Returned as `(source, destination folder)`.
    pub fn importable_legacy_snippet_files(&self) -> Vec<(PathBuf, PathBuf)> {
        let base = swift_support_dir(&self.home).join("snippets");
        vec![
            (base.join("global.json"), self.user_snippets_dir()),
            (base.join("default.json"), self.profile_snippets_dir()),
        ]
    }

    /// Files of the Swift app that Chau7 Next may read once, to import, and
    /// must never write. Returned as `(source in Swift layout, destination)`.
    pub fn importable_files(&self) -> Vec<(PathBuf, PathBuf)> {
        let legacy = self.home.join(".chau7");
        vec![(legacy.join("config.toml"), self.config_file())]
    }

    /// Create the folders Chau7 Next owns.
    pub fn ensure_dirs(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.config_dir)?;
        std::fs::create_dir_all(&self.state_dir)?;
        Ok(())
    }

    /// Copy the Swift app's config and snippets on first launch. Copy only:
    /// sources are opened read-only and destinations that already exist are
    /// left alone. Returns the destinations that were created.
    pub fn import_from_swift_app(&self) -> std::io::Result<Vec<PathBuf>> {
        self.ensure_dirs()?;
        let mut imported = Vec::new();
        for (source, destination) in self.importable_files() {
            if destination.exists() || !source.is_file() {
                continue;
            }
            let bytes = std::fs::read(&source)?;
            std::fs::write(&destination, bytes)?;
            imported.push(destination);
        }
        // Snippet folders and their pre-split single files: copy when the
        // destination does not exist yet. Like Swift's migration, a snippet of
        // the single file wins over a folder file with the same id.
        let legacy_files = self.importable_legacy_snippet_files();
        for (source, destination) in self.importable_snippet_dirs() {
            let legacy = legacy_files
                .iter()
                .find(|(_, d)| *d == destination)
                .map(|(f, _)| f.as_path())
                .filter(|f| f.is_file());
            let read = std::fs::read_dir(&source).ok();
            if destination.exists() || (read.is_none() && legacy.is_none()) {
                continue;
            }
            std::fs::create_dir_all(&destination)?;
            for file in read.into_iter().flatten().flatten() {
                let path = file.path();
                if path.extension().is_some_and(|e| e == "json") && path.is_file() {
                    let target = destination.join(file.file_name());
                    std::fs::write(&target, std::fs::read(&path)?)?;
                    imported.push(target);
                }
            }
            for snippet in legacy
                .map(crate::snippet_store::load_legacy_file)
                .unwrap_or_default()
            {
                if crate::snippet_store::save_snippet(&destination, &snippet).is_ok() {
                    let target = destination.join(format!("{}.json", snippet.id));
                    if !imported.contains(&target) {
                        imported.push(target);
                    }
                }
            }
        }
        Ok(imported)
    }

    /// Clipboard history (Swift keeps it in UserDefaults `clipboard.history`).
    pub fn clipboard_history_file(&self) -> PathBuf {
        self.state_dir.join("clipboard-history.json")
    }

    /// (dev) Raw PTY output capture (`CHAU7_NEXT_PTY_DUMP=1`; Swift:
    /// `<Logs>/Chau7/pty-capture.log`).
    pub fn pty_capture_file(&self) -> PathBuf {
        self.state_dir.join("pty-capture.log")
    }

    /// Logs of AI tool sessions (Swift: `<Logs>/Chau7/<tool>-pty.log`).
    pub fn ai_logs_dir(&self) -> PathBuf {
        self.state_dir.join("ai-logs")
    }

    /// AI run start and finish lines (Swift: `~/.ai-events.log`).
    pub fn ai_events_log(&self) -> PathBuf {
        self.state_dir.join("ai-events.log")
    }

    /// Crash-safe copies of the window and tab state (`TabStateBackups` in
    /// Swift): `latest.json` plus an `archive/` folder.
    pub fn tab_state_backups_dir(&self) -> PathBuf {
        self.state_dir.join("TabStateBackups")
    }

    /// The 20 most recent repositories (`feature.recentRepoRoots`).
    pub fn recent_repos_file(&self) -> PathBuf {
        self.state_dir.join("recent-repos.json")
    }

    /// Confirmed repository roots and branch evidence, isolated from Swift defaults.
    pub fn known_repo_identities_file(&self) -> PathBuf {
        self.state_dir.join("known-repo-identities.json")
    }

    /// A repository's metadata (description, labels, favorite files). It
    /// lives in the user's repo and belongs to the Swift app, which migrates
    /// it: Chau7 Next only reads it and keeps its own edits in
    /// [`DataRoot::repo_overlay_dir`] (DUAL-SHIP phase 1).
    pub fn repo_metadata_file(repo_root: &Path) -> PathBuf {
        repo_root.join(".chau7").join("metadata.json")
    }

    /// Saved terminal text of each pane, replayed after a restore
    /// (`<pane id>.txt`, plus short-lived `restore-*.txt` copies).
    pub fn scrollback_dir(&self) -> PathBuf {
        self.state_dir.join("scrollback")
    }

    /// Ordered durable events owned by Chau7 Next, independent of Swift's journal.
    pub fn event_journal_file(&self) -> PathBuf {
        self.config_dir.join("events").join("spine-journal.db")
    }

    /// Local bug reports (`chau7-bug-report-<ts>.md`; Swift: `~/.chau7/reports`).
    pub fn reports_dir(&self) -> PathBuf {
        self.config_dir.join("reports")
    }

    /// Independent lifetime lock for the Next application, retained after exit.
    pub fn instance_lock_file(&self) -> PathBuf {
        self.state_dir.join("app-instance.lock")
    }
    /// Launch marker distinguishes clean termination from an abrupt exit.
    pub fn launch_continuity_file(&self) -> PathBuf {
        self.state_dir.join("launch-continuity.json")
    }

    /// Bounded local incident evidence owned by Next.
    pub fn incidents_dir(&self) -> PathBuf {
        self.config_dir.join("incidents")
    }

    /// State snapshots (`chau7-snapshot-<ts>.json`; Swift: `~/.chau7/snapshots`).
    pub fn snapshots_dir(&self) -> PathBuf {
        self.config_dir.join("snapshots")
    }

    /// AI events log that AI CLI hooks (and the Swift app) append to
    /// (`~/.ai-events.log`). Chau7 Next only reads it, never truncates or
    /// rotates it (DUAL-SHIP.md section 3).
    pub fn shared_ai_events_log(&self) -> PathBuf {
        self.home.join(".ai-events.log")
    }

    /// Claude Code hook events written by the hook scripts
    /// (`~/.chau7/claude-events.jsonl`). Read only.
    pub fn claude_hook_events_file(&self) -> PathBuf {
        self.home.join(".chau7").join("claude-events.jsonl")
    }

    /// Claude Code's prompt history (`~/.claude/history.jsonl`). Read only.
    pub fn claude_history_file(&self) -> PathBuf {
        self.home.join(".claude").join("history.jsonl")
    }

    /// Codex's prompt history (`~/.codex/history.jsonl`). Read only.
    pub fn codex_history_file(&self) -> PathBuf {
        self.home.join(".codex").join("history.jsonl")
    }

    /// Command history (SQLite; Swift: `<Application Support>/Chau7/history.db`).
    pub fn history_db(&self) -> PathBuf {
        self.state_dir.join("history.db")
    }

    /// Session recordings (`<uuid>.bin` frames plus `<uuid>.json` metadata;
    /// Swift: `<Application Support>/Chau7/recordings`).
    pub fn recordings_dir(&self) -> PathBuf {
        self.state_dir.join("recordings")
    }

    /// Unix socket the remote control agent connects to (Swift: `remote.sock`
    /// in its own Application Support folder). The agent's working folder is
    /// [`Self::state_dir`].
    pub fn remote_socket(&self) -> PathBuf {
        self.state_dir.join("remote.sock")
    }

    /// Installed copy of the `chau7-remote` agent binary.
    pub fn remote_agent_binary(&self) -> PathBuf {
        self.state_dir.join("chau7-remote")
    }

    /// The agent's state (device ID, keys, paired devices), passed to it as
    /// `CHAU7_REMOTE_STATE`. Without it the agent would use the Swift app's
    /// file and both apps would share one pairing.
    pub fn remote_state_file(&self) -> PathBuf {
        self.config_dir.join("remote").join("state.json")
    }

    /// The agent's relay credentials (`chau7-remote provision` output),
    /// passed to it as `CHAU7_REMOTE_CREDENTIALS`. The agent's default is
    /// beside the state file, but an inherited value could point at the
    /// Swift app's file, so it is always passed explicitly.
    pub fn remote_credentials_file(&self) -> PathBuf {
        self.config_dir.join("remote").join("credentials.json")
    }

    /// Global prompt injection rules of the API analytics proxy, passed as
    /// `CHAU7_INJECTION_RULES` (the proxy's default is the Swift app's
    /// `prompt-rules.json`).
    pub fn proxy_injection_rules_file(&self) -> PathBuf {
        self.config_dir.join("prompt-rules.json")
    }

    /// Security-scoped bookmarks of the protected folders the user granted
    /// (Swift: UserDefaults `protectedPathPolicy.securityScopedBookmarksByRoot.v1`).
    pub fn protected_folder_bookmarks_file(&self) -> PathBuf {
        self.state_dir.join("protected-folder-bookmarks.json")
    }

    /// Where the floating panels were dragged, per workspace and panel
    /// (Swift: UserDefaults `overlay.positions.map`).
    pub fn panel_positions_file(&self) -> PathBuf {
        self.state_dir.join("panel-positions.json")
    }

    /// `~/x` with this root's home (`RuntimeIsolation.expandTilde`), so an
    /// isolated run (`CHAU7_NEXT_HOME_ROOT`) expands into its own folder.
    /// Other paths come back unchanged.
    pub fn expand_tilde(&self, path: &str) -> String {
        match path.strip_prefix("~/") {
            Some(rest) => self.home.join(rest).to_string_lossy().into_owned(),
            None => path.to_string(),
        }
    }

    /// Socket of the scripting API (Swift: `scripting.sock` in its own
    /// Application Support folder, never started there).
    pub fn scripting_socket(&self) -> PathBuf {
        self.state_dir.join("scripting.sock")
    }

    /// Claude Code transcripts (`~/.claude/projects`). Read only.
    pub fn claude_projects_dir(&self) -> PathBuf {
        self.home.join(".claude").join("projects")
    }

    /// The API analytics proxy's folder (Swift: `<Application Support>/Chau7/Proxy`):
    /// its database, IPC socket and TLS certificate.
    pub fn proxy_dir(&self) -> PathBuf {
        self.state_dir.join("Proxy")
    }

    /// Proxy database (`analytics.db`), written by the `chau7-proxy` process.
    pub fn proxy_db(&self) -> PathBuf {
        self.proxy_dir().join("analytics.db")
    }

    /// Socket the proxy reports API calls and task events on.
    pub fn proxy_socket(&self) -> PathBuf {
        self.proxy_dir().join("proxy.sock")
    }

    /// The proxy's self-signed TLS certificate (PEM).
    pub fn proxy_tls_cert(&self) -> PathBuf {
        self.proxy_dir().join("proxy-cert.pem")
    }

    /// The proxy's TLS private key (PEM, mode 0600).
    pub fn proxy_tls_key(&self) -> PathBuf {
        self.proxy_dir().join("proxy-key.pem")
    }

    /// Development builds of the proxy (`go build` from the checkout) go here.
    pub fn proxy_dev_binary(&self) -> PathBuf {
        self.proxy_dir().join("chau7-proxy")
    }

    /// AI run telemetry (SQLite; Swift: `~/.chau7/telemetry/runs.db`).
    pub fn telemetry_db(&self) -> PathBuf {
        self.config_dir.join("telemetry").join("runs.db")
    }

    /// Token optimizer wrapper scripts, put in front of `PATH` (Swift:
    /// `~/.chau7/cto_bin`). Chau7 Next has its own folder, and the optimizer
    /// is told about it with `CHAU7_CTO_BIN_DIR`.
    pub fn cto_bin_dir(&self) -> PathBuf {
        self.config_dir.join("cto_bin")
    }

    /// Per-session flag files of the token optimizer (Swift: `cto_active`).
    pub fn cto_active_dir(&self) -> PathBuf {
        self.config_dir.join("cto_active")
    }

    /// Command log and savings database of the token optimizer (Swift:
    /// `cto_data`).
    pub fn cto_data_dir(&self) -> PathBuf {
        self.config_dir.join("cto_data")
    }

    /// The Swift app's wrapper folder. Never written: it only gets removed
    /// from the `PATH` used to find the real binaries, because a Chau7 Next
    /// started from a Chau7 tab inherits it.
    pub fn swift_cto_bin_dir(&self) -> PathBuf {
        self.home.join(".chau7").join("cto_bin")
    }

    /// What the Swift app's shells point variables at, for
    /// `shell_env::inherited_cleanup` (a Chau7 Next started from a Chau7 tab
    /// inherits them). Never written.
    pub fn swift_shell_paths(&self) -> crate::shell_env::SwiftShellPaths {
        crate::shell_env::SwiftShellPaths {
            cto_bin: self.swift_cto_bin_dir(),
            history_dir: self.home.join(".chau7").join("history"),
            integration_dir_name: SWIFT_SHELL_INTEGRATION_DIR_NAME,
        }
    }

    /// Marker file of the welcome screen (`app.hasShownWelcome`): present once
    /// the first-launch welcome was shown. Kept next to the app defaults key
    /// so the screen also stays away where there are no app defaults.
    pub fn welcome_shown_file(&self) -> PathBuf {
        self.state_dir.join("welcome-shown")
    }

    /// Chau7 Next's edits of repositories' data (metadata, repo snippets),
    /// one folder per repository ([`repo_overlay_key`]). The repo's own files
    /// are read only; these edits are merged over them on read.
    pub fn repo_overlays_dir(&self) -> PathBuf {
        self.state_dir.join("repo-overlays")
    }

    /// The overlay folder of one repository.
    pub fn repo_overlay_dir(&self, repo_root: &Path) -> PathBuf {
        self.repo_overlays_dir().join(repo_overlay_key(repo_root))
    }

    /// Chau7 Next's copy of a repository's metadata (see
    /// [`DataRoot::repo_metadata_file`]).
    pub fn repo_metadata_overlay_file(&self, repo_root: &Path) -> PathBuf {
        self.repo_overlay_dir(repo_root).join("metadata.json")
    }
}

/// The Swift app's temporary shell integration folder (`$TMPDIR/smartoverlay`,
/// `ShellLaunchConfigurator.integrationDirectoryPath`). Chau7 Next writes its
/// own files to [`DataRoot::shell_integration_dir`].
pub const SWIFT_SHELL_INTEGRATION_DIR_NAME: &str = "smartoverlay";

/// Variable that turns on isolated test mode (`CHAU7_ISOLATED_TEST_MODE` in
/// Swift): login items and other system-wide changes are skipped.
pub const ISOLATED_TEST_MODE_ENV: &str = "CHAU7_NEXT_ISOLATED_TEST_MODE";

/// Variable that prefixes Keychain service names, so an isolated run never
/// reads or writes the user's items (`CHAU7_KEYCHAIN_SERVICE_PREFIX` in Swift).
pub const KEYCHAIN_PREFIX_ENV: &str = "CHAU7_NEXT_KEYCHAIN_SERVICE_PREFIX";

/// `RuntimeIsolation.isIsolatedTestMode` for a raw value: `1` or `true`
/// (any case), surrounding spaces ignored.
pub fn is_isolated_test_mode_value(raw: Option<&str>) -> bool {
    let raw = raw.map(str::trim).unwrap_or("");
    raw == "1" || raw.eq_ignore_ascii_case("true")
}

/// Whether this run is in isolated test mode ([`ISOLATED_TEST_MODE_ENV`]).
pub fn is_isolated_test_mode() -> bool {
    is_isolated_test_mode_value(std::env::var(ISOLATED_TEST_MODE_ENV).ok().as_deref())
}

/// `RuntimeIsolation.keychainServiceName`: `<prefix>.<base>` when a prefix
/// is set (blank counts as unset), else `base`.
pub fn keychain_service_name(base: &str, prefix: Option<&str>) -> String {
    match prefix.map(str::trim).filter(|p| !p.is_empty()) {
        Some(prefix) => format!("{prefix}.{base}"),
        None => base.to_string(),
    }
}

/// [`keychain_service_name`] with the prefix from [`KEYCHAIN_PREFIX_ENV`].
pub fn keychain_service_name_from_env(base: &str) -> String {
    keychain_service_name(base, std::env::var(KEYCHAIN_PREFIX_ENV).ok().as_deref())
}

fn home_dir() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        std::env::var_os("USERPROFILE").map(PathBuf::from)
    }
    #[cfg(not(windows))]
    {
        std::env::var_os("HOME").map(PathBuf::from)
    }
}

/// Where the Swift app keeps its application support folder.
fn swift_support_dir(home: &Path) -> PathBuf {
    home.join("Library")
        .join("Application Support")
        .join("Chau7")
}

fn platform_state_dir(home: &Path) -> PathBuf {
    if cfg!(target_os = "macos") {
        home.join("Library")
            .join("Application Support")
            .join(APP_NAME)
    } else if cfg!(windows) {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("AppData").join("Roaming"))
            .join(APP_NAME)
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local").join("share"))
            .join("chau7-next")
    }
}

/// Folder name of a repository's overlay: its last path component (for
/// people looking at the folder) and a hash of the full path, so two repos
/// with the same name never share one.
pub fn repo_overlay_key(repo_root: &Path) -> String {
    let full = repo_root.to_string_lossy();
    let full = full.trim_end_matches('/');
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in full.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let name: String = Path::new(full)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .take(40)
        .collect();
    let name = if name.is_empty() {
        "repo".to_string()
    } else {
        name
    };
    format!("{name}-{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-test-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    // Ports of `RuntimeIsolationTests`.

    #[test]
    fn home_directory_uses_override_when_configured() {
        let root = DataRoot::with_home(PathBuf::from("/tmp/chau7-isolated-home"), true);
        assert_eq!(root.home(), Path::new("/tmp/chau7-isolated-home"));
        assert_eq!(
            root.config_dir(),
            Path::new("/tmp/chau7-isolated-home/.chau7-next")
        );
        assert!(root.state_dir().starts_with("/tmp/chau7-isolated-home"));
    }

    #[test]
    fn expand_tilde_uses_override_root() {
        let root = DataRoot::with_home(PathBuf::from("/tmp/chau7-isolated-home"), true);
        assert_eq!(
            root.expand_tilde("~/project"),
            PathBuf::from("/tmp/chau7-isolated-home")
                .join("project")
                .to_string_lossy()
        );
        assert_eq!(root.expand_tilde("/abs/path"), "/abs/path");
        assert_eq!(root.expand_tilde("~user/x"), "~user/x");
    }

    #[test]
    fn isolated_test_mode_recognizes_true_values() {
        assert!(is_isolated_test_mode_value(Some("1")));
        assert!(is_isolated_test_mode_value(Some("true")));
        assert!(is_isolated_test_mode_value(Some(" TRUE ")));
        assert!(!is_isolated_test_mode_value(Some("yes")));
        assert!(!is_isolated_test_mode_value(None));
    }

    #[test]
    fn keychain_service_uses_prefix_when_set() {
        assert_eq!(
            keychain_service_name("llm.anthropic", Some("com.chau7.isolated")),
            "com.chau7.isolated.llm.anthropic"
        );
        assert_eq!(
            keychain_service_name("llm.anthropic", Some("  ")),
            "llm.anthropic"
        );
        assert_eq!(
            keychain_service_name("llm.anthropic", None),
            "llm.anthropic"
        );
    }

    #[test]
    fn paths_never_point_into_swift_app_folders() {
        let root = DataRoot::with_home(PathBuf::from("/Users/me"), false);
        for path in [
            root.config_file(),
            root.snippets_file(),
            root.bin_dir(),
            root.mcp_socket(),
            root.session_file(),
            root.log_file(),
            root.reports_dir(),
            root.snapshots_dir(),
            root.remote_state_file(),
            root.remote_credentials_file(),
            root.remote_socket(),
            root.proxy_injection_rules_file(),
            root.proxy_socket(),
            root.cto_bin_dir(),
            root.shell_integration_dir(),
            root.history_db(),
        ] {
            let text = path.to_string_lossy().to_string();
            assert!(!text.contains("/.chau7/"), "{text}");
            assert!(!text.ends_with("/.chau7"), "{text}");
            assert!(!text.contains("Application Support/Chau7/"), "{text}");
        }
    }

    #[test]
    fn isolated_root_keeps_everything_under_home() {
        let home = PathBuf::from("/tmp/x");
        let root = DataRoot::with_home(home.clone(), true);
        assert!(root.config_dir().starts_with(&home));
        assert!(root.state_dir().starts_with(&home));
    }

    #[test]
    fn import_copies_once_and_never_writes_sources() {
        let home = temp_home("import");
        let legacy = home.join(".chau7");
        std::fs::create_dir_all(&legacy).unwrap();
        std::fs::write(
            legacy.join("config.toml"),
            "[general]\nshell = \"/bin/zsh\"\n",
        )
        .unwrap();
        let source_before = std::fs::metadata(legacy.join("config.toml"))
            .unwrap()
            .modified()
            .unwrap();

        let root = DataRoot::with_home(home.clone(), true);
        let imported = root.import_from_swift_app().unwrap();
        assert_eq!(imported, vec![root.config_file()]);
        assert_eq!(
            std::fs::read_to_string(root.config_file()).unwrap(),
            "[general]\nshell = \"/bin/zsh\"\n"
        );

        // Second run: destination exists, nothing imported, source untouched.
        std::fs::write(root.config_file(), "edited").unwrap();
        assert!(root.import_from_swift_app().unwrap().is_empty());
        assert_eq!(
            std::fs::read_to_string(root.config_file()).unwrap(),
            "edited"
        );
        let source_after = std::fs::metadata(legacy.join("config.toml"))
            .unwrap()
            .modified()
            .unwrap();
        assert_eq!(source_before, source_after);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn swift_single_file_snippets_are_imported_read_only() {
        let home = temp_home("import-legacy-snippets");
        let root = DataRoot::with_home(home.clone(), true);
        let (legacy, _) = root.importable_legacy_snippet_files()[0].clone();
        let (folder, _) = root.importable_snippet_dirs()[0].clone();
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(
            folder.join("a.json"),
            r#"{"id":"a","title":"Folder","body":"f"}"#,
        )
        .unwrap();
        std::fs::write(
            &legacy,
            r#"{"version":1,"snippets":[{"id":"a","title":"File","body":"x"},{"id":"b","title":"B","body":"b"}]}"#,
        )
        .unwrap();
        let before = std::fs::read(&legacy).unwrap();
        root.import_from_swift_app().unwrap();
        let mut ids: Vec<_> = crate::snippet_store::load_dir(&root.user_snippets_dir())
            .into_iter()
            .map(|s| (s.id, s.title))
            .collect();
        ids.sort();
        assert_eq!(
            ids,
            vec![("a".into(), "File".into()), ("b".into(), "B".into())]
        );
        // Profile: only a single file, no folder.
        assert!(!root.profile_snippets_dir().exists());
        assert_eq!(std::fs::read(&legacy).unwrap(), before);
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Guards the coexistence rule: outside this file, no source in the
    /// Chau7 Next workspace may mention a path or identifier owned by the
    /// Swift app.
    #[test]
    fn no_swift_app_paths_outside_data_root() {
        let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let forbidden = [
            "\".chau7/",
            "\".chau7\"",
            "Application Support/Chau7/",
            "com.chau7.app",
            "remote.sock",
            "proxy.sock",
            "/.chau7/",
            "/.chau7\"",
            ".join(\"Chau7\")",
            ".join(\".chau7\")",
            "Logs/Chau7",
            "\"com.chau7\"",
            // Added since April 2026 (see docs/rust-port/REBASE-ON-AEPTUS.md):
            // the Swift app's temporary shell folder, its skill install
            // markers and the helpers it installs into AI CLI configs.
            "smartoverlay",
            ".chau7-skill",
            ".chau7-backups",
            "chau7-claude-hook",
            "chau7-claude-statusline",
            "chau7-codex-notify",
            "credentials.json",
        ];
        let mut offenders = Vec::new();
        let mut check = |path: &Path, text: &str| {
            if path.ends_with("data_root.rs") {
                return;
            }
            for (number, line) in text.lines().enumerate() {
                let trimmed = line.trim_start();
                if trimmed.starts_with("//") || trimmed.starts_with('#') {
                    continue;
                }
                // Per-repo `.chau7/` folders are the user's project files, shared on purpose.
                let line = line
                    .replace("<repo>/.chau7/", "")
                    .replace("<git root>/.chau7/", "");
                for needle in forbidden {
                    if line.contains(needle) {
                        offenders.push(format!(
                            "{}:{} contains {needle}",
                            path.display(),
                            number + 1
                        ));
                    }
                }
            }
        };
        visit_files(&workspace.join("crates"), &["rs"], &mut check);
        visit_files(&workspace.join("scripts"), &["sh", "rs", "py"], &mut check);
        assert!(offenders.is_empty(), "{offenders:#?}");
    }

    fn visit_files(dir: &Path, extensions: &[&str], f: &mut dyn FnMut(&Path, &str)) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if path.file_name().is_some_and(|n| n == "target") {
                    continue;
                }
                visit_files(&path, extensions, f);
            } else if path
                .extension()
                .is_some_and(|e| extensions.iter().any(|x| e == *x))
                && let Ok(text) = std::fs::read_to_string(&path)
            {
                f(&path, &text);
            }
        }
    }
}
