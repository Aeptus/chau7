//! Environment for shells launched by Chau7 Next.
//!
//! `preferred_path` ports `ShellLaunchEnvironment.preferredPATH` from
//! `apps/chau7-macos/Sources/Chau7Core/ShellLaunchEnvironment.swift`: apps
//! started from Finder get a minimal `PATH`, so common tool folders are added
//! in front of the inherited one, then the system folders, de-duplicated.

use std::collections::{HashMap, HashSet};
use std::path::Path;

/// Build the `PATH` for a new shell.
pub fn preferred_path(home: Option<&str>, inherited: Option<&str>) -> String {
    let separator = if cfg!(windows) { ';' } else { ':' };
    if cfg!(windows) {
        return inherited.unwrap_or_default().to_string();
    }
    let mut entries: Vec<String> = Vec::new();
    if let Some(home) = home.map(str::trim).filter(|h| !h.is_empty()) {
        for sub in ["bin", ".local/bin", ".volta/bin", ".cargo/bin", ".bun/bin"] {
            entries.push(format!("{home}/{sub}"));
        }
    }
    entries.push("/opt/homebrew/bin".into());
    entries.push("/opt/homebrew/sbin".into());
    entries.extend(
        inherited
            .unwrap_or_default()
            .split(separator)
            .map(str::trim)
            .filter(|e| !e.is_empty())
            .map(String::from),
    );
    for system in ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
        entries.push(system.into());
    }
    let mut seen = HashSet::new();
    entries.retain(|e| seen.insert(e.clone()));
    entries.join(&separator.to_string())
}

fn normalized(raw: Option<&String>) -> Option<&str> {
    raw.map(|v| crate::escape_sanitizer::trim_whitespaces_and_newlines(v))
        .filter(|v| !v.is_empty())
}

/// The user's home folder (`ShellLaunchEnvironment.userHome`): `HOME` when it
/// is set and not blank, otherwise `fallback_home` (Swift asks
/// `RuntimeIsolation.homePath`; the caller supplies the platform home here).
pub fn user_home(environment: &HashMap<String, String>, fallback_home: &str) -> String {
    normalized(environment.get("HOME"))
        .unwrap_or(fallback_home)
        .to_string()
}

/// The user's `ZDOTDIR` (`userZdotdir`): the variable when set and not blank,
/// otherwise the home folder.
pub fn user_zdotdir(environment: &HashMap<String, String>, fallback_home: &str) -> String {
    normalized(environment.get("ZDOTDIR"))
        .map(str::to_string)
        .unwrap_or_else(|| user_home(environment, fallback_home))
}

/// The user's `XDG_CONFIG_HOME` (`userXDGConfigHome`): the variable when set
/// and not blank, otherwise `<home>/.config`.
pub fn user_xdg_config_home(environment: &HashMap<String, String>, fallback_home: &str) -> String {
    if let Some(xdg) = normalized(environment.get("XDG_CONFIG_HOME")) {
        return xdg.to_string();
    }
    let home = user_home(environment, fallback_home);
    let home = home.trim_end_matches('/');
    format!("{home}/.config")
}

/// [`preferred_path`] reading `HOME` and `PATH` from an environment map
/// (`ShellLaunchEnvironment.preferredPATH(environment:)`).
pub fn preferred_path_from_env(
    environment: &HashMap<String, String>,
    fallback_home: &str,
) -> String {
    let home = user_home(environment, fallback_home);
    preferred_path(Some(&home), normalized(environment.get("PATH")))
}

/// Environment variables added to every shell Chau7 Next starts.
/// `TERM` and `COLORTERM` are set by `chau7_terminal` itself.
pub fn shell_environment(
    home: Option<&str>,
    inherited_path: Option<&str>,
) -> Vec<(String, String)> {
    vec![
        ("PATH".into(), preferred_path(home, inherited_path)),
        ("TERM_PROGRAM".into(), "Chau7Next".into()),
        (
            "TERM_PROGRAM_VERSION".into(),
            env!("CARGO_PKG_VERSION").into(),
        ),
    ]
}

/// Shell choice setting (`ShellType` in `FeatureSettings.swift`). The raw
/// values are the Swift ones (`terminal.shellType`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ShellType {
    /// The login shell of the user's passwd entry.
    #[default]
    System,
    Zsh,
    Bash,
    /// Homebrew on Apple Silicon, then the Intel path, else zsh.
    Fish,
    FishIntel,
    /// The custom path, else the system shell.
    Custom,
}

impl ShellType {
    pub const ALL: [ShellType; 6] = [
        Self::System,
        Self::Zsh,
        Self::Bash,
        Self::Fish,
        Self::FishIntel,
        Self::Custom,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Zsh => "/bin/zsh",
            Self::Bash => "/bin/bash",
            Self::Fish => "/opt/homebrew/bin/fish",
            Self::FishIntel => "/usr/local/bin/fish",
            Self::Custom => "custom",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|t| t.raw_value() == raw)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::System => "System Default",
            Self::Zsh => "Zsh",
            Self::Bash => "Bash",
            Self::Fish => "Fish (Apple Silicon)",
            Self::FishIntel => "Fish (Intel)",
            Self::Custom => "Custom...",
        }
    }
}

/// The shell to start (`defaultShell()`): `exists` tells whether a file
/// exists, `system_shell` is the passwd login shell.
pub fn resolve_shell(
    shell_type: ShellType,
    custom_path: &str,
    exists: impl Fn(&str) -> bool,
    system_shell: impl Fn() -> String,
) -> String {
    match shell_type {
        ShellType::System => system_shell(),
        ShellType::Zsh => "/bin/zsh".into(),
        ShellType::Bash => "/bin/bash".into(),
        ShellType::Fish => ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .into_iter()
            .find(|p| exists(p))
            .unwrap_or("/bin/zsh")
            .into(),
        ShellType::FishIntel => {
            if exists("/usr/local/bin/fish") {
                "/usr/local/bin/fish".into()
            } else {
                "/bin/zsh".into()
            }
        }
        ShellType::Custom => {
            let custom = custom_path.trim();
            if !custom.is_empty() && exists(custom) {
                custom.into()
            } else {
                system_shell()
            }
        }
    }
}

/// Default start directory setting to a path (`resolveStartDirectory`):
/// blank is home, `~` expanded, relative paths are relative to home, then
/// standardized.
pub fn resolve_start_directory(raw: &str, home: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return home.to_string();
    }
    let expanded = if trimmed == "~" {
        home.to_string()
    } else if let Some(rest) = trimmed.strip_prefix("~/") {
        format!("{}/{rest}", home.trim_end_matches('/'))
    } else {
        trimmed.to_string()
    };
    let resolved = if expanded.starts_with('/') {
        expanded
    } else {
        format!("{}/{expanded}", home.trim_end_matches('/'))
    };
    crate::shell_session::standardize_path(&resolved)
}

/// `LSCOLORS` set when the "ls colors" setting is on (`defaultLsColors`).
pub const DEFAULT_LSCOLORS: &str = "exfxcxdxbxegedabagacad";

/// Per-session variables (`buildEnvironment`): `TERM_SESSION_ID`, `SHELL`,
/// `SHELL_SESSIONS_DISABLE=1` (no macOS "Restored session" banner),
/// `CLICOLOR`/`LSCOLORS` when `ls_colors`, and for the startup files the
/// start directory and the startup command (run with `eval` after the
/// user's own config).
pub fn session_environment(
    shell_path: &str,
    session_id: &str,
    start_dir: &str,
    startup_command: &str,
    ls_colors: bool,
) -> Vec<(String, String)> {
    let mut env = vec![
        ("TERM_SESSION_ID".to_string(), session_id.to_string()),
        ("SHELL".to_string(), shell_path.to_string()),
        ("SHELL_SESSIONS_DISABLE".to_string(), "1".to_string()),
        ("CHAU7_NEXT_START_DIR".to_string(), start_dir.to_string()),
    ];
    if ls_colors {
        env.push(("CLICOLOR".into(), "1".into()));
        env.push(("LSCOLORS".into(), DEFAULT_LSCOLORS.into()));
    }
    let startup = startup_command.trim();
    if !startup.is_empty() {
        env.push(("CHAU7_NEXT_STARTUP_CMD".into(), startup.into()));
    }
    env
}

/// A change to the app's own environment, decided by [`inherited_cleanup`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnvChange {
    Remove(String),
    Set(String, String),
}

/// Variables the Swift app sets for its shells that must not leak into
/// Chau7 Next's shells when Chau7 Next is started from a Chau7 tab
/// (`open -a "Chau7 Next"` or `cargo run`). Without this, shells in Chau7 Next
/// would report events to Chau7's sockets and logs, and route API calls
/// through Chau7's analytics proxy. `swift_cto_bin` (the Swift app's token
/// optimizer wrappers, `DataRoot::swift_cto_bin_dir`) is dropped from `PATH`,
/// so commands in Chau7 Next never go through Chau7's wrappers.
pub fn inherited_cleanup(vars: &[(String, String)], swift_cto_bin: &Path) -> Vec<EnvChange> {
    let get = |key: &str| vars.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str());
    let mut changes = Vec::new();
    if let Some(path) = get("PATH") {
        let wrapper = swift_cto_bin.to_string_lossy();
        let wrapper = wrapper.trim_end_matches('/');
        let kept: Vec<&str> = path
            .split(':')
            .filter(|entry| entry.trim_end_matches('/') != wrapper)
            .collect();
        let cleaned = kept.join(":");
        if cleaned != path {
            changes.push(EnvChange::Set("PATH".into(), cleaned));
        }
    }
    for (key, _) in vars {
        if key.starts_with("CHAU7_")
            && !key.starts_with("CHAU7_NEXT_")
            && key != "CHAU7_USER_ZDOTDIR"
        {
            changes.push(EnvChange::Remove(key.clone()));
        }
    }
    // Launched from a Claude Code session (`AppDelegate`: unsetenv("CLAUDECODE")):
    // the variable would stop Claude Code from starting inside our tabs.
    if get("CLAUDECODE").is_some() {
        changes.push(EnvChange::Remove("CLAUDECODE".into()));
    }
    if get("TERM_PROGRAM") != Some("Chau7") {
        return changes;
    }
    // The Swift app points ZDOTDIR at its own temporary folder and keeps the
    // user's value in CHAU7_USER_ZDOTDIR.
    if let Some(user) = get("CHAU7_USER_ZDOTDIR") {
        changes.push(EnvChange::Remove("CHAU7_USER_ZDOTDIR".into()));
        if user.is_empty() {
            changes.push(EnvChange::Remove("ZDOTDIR".into()));
        } else {
            changes.push(EnvChange::Set("ZDOTDIR".into(), user.into()));
        }
    }
    for key in [
        "ANTHROPIC_BASE_URL",
        "OPENAI_BASE_URL",
        "GOOGLE_GEMINI_BASE_URL",
    ] {
        if get(key).is_some_and(is_local_proxy) {
            changes.push(EnvChange::Remove(key.into()));
        }
    }
    for key in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID"] {
        if get(key).is_some() {
            changes.push(EnvChange::Remove(key.into()));
        }
    }
    changes
}

fn is_local_proxy(url: &str) -> bool {
    [
        "http://127.0.0.1:",
        "https://127.0.0.1:",
        "http://localhost:",
        "https://localhost:",
    ]
    .iter()
    .any(|prefix| url.starts_with(prefix))
}

#[cfg(all(test, not(windows)))]
mod tests {
    use super::*;

    #[test]
    fn home_tools_then_homebrew_then_inherited_then_system() {
        let path = preferred_path(Some("/Users/me"), Some("/usr/bin:/custom/bin"));
        let parts: Vec<_> = path.split(':').collect();
        assert_eq!(parts[0], "/Users/me/bin");
        assert_eq!(parts[5], "/opt/homebrew/bin");
        assert!(parts.contains(&"/custom/bin"));
        assert_eq!(parts.last(), Some(&"/sbin"));
        // /usr/bin appears once (deduplicated, first occurrence kept).
        assert_eq!(parts.iter().filter(|p| **p == "/usr/bin").count(), 1);
    }

    #[test]
    fn shell_resolution() {
        let none = |_: &str| false;
        let all = |_: &str| true;
        let sys = || "/bin/sh".to_string();
        assert_eq!(resolve_shell(ShellType::System, "", none, sys), "/bin/sh");
        assert_eq!(resolve_shell(ShellType::Zsh, "", none, sys), "/bin/zsh");
        assert_eq!(resolve_shell(ShellType::Bash, "", none, sys), "/bin/bash");
        assert_eq!(resolve_shell(ShellType::Fish, "", none, sys), "/bin/zsh");
        assert_eq!(
            resolve_shell(ShellType::Fish, "", |p| p == "/usr/local/bin/fish", sys),
            "/usr/local/bin/fish"
        );
        assert_eq!(
            resolve_shell(ShellType::Fish, "", all, sys),
            "/opt/homebrew/bin/fish"
        );
        assert_eq!(
            resolve_shell(ShellType::FishIntel, "", none, sys),
            "/bin/zsh"
        );
        assert_eq!(
            resolve_shell(ShellType::Custom, " /x/nu ", all, sys),
            "/x/nu"
        );
        assert_eq!(
            resolve_shell(ShellType::Custom, "/x/nu", none, sys),
            "/bin/sh"
        );
        assert_eq!(resolve_shell(ShellType::Custom, "", all, sys), "/bin/sh");
        for t in ShellType::ALL {
            assert_eq!(ShellType::from_raw(t.raw_value()), Some(t));
        }
    }

    #[test]
    fn start_directory_resolution() {
        assert_eq!(resolve_start_directory("", "/Users/me"), "/Users/me");
        assert_eq!(resolve_start_directory(" ~ ", "/Users/me"), "/Users/me");
        assert_eq!(
            resolve_start_directory("~/code/", "/Users/me"),
            "/Users/me/code"
        );
        assert_eq!(
            resolve_start_directory("code/../src", "/Users/me"),
            "/Users/me/src"
        );
        assert_eq!(resolve_start_directory("/tmp/./x", "/Users/me"), "/tmp/x");
    }

    #[test]
    fn session_environment_values() {
        let env = session_environment("/bin/zsh", "ID", "/tmp", " echo hi ", true);
        let get = |k: &str| {
            env.iter()
                .find(|(key, _)| key == k)
                .map(|(_, v)| v.as_str())
        };
        assert_eq!(get("SHELL_SESSIONS_DISABLE"), Some("1"));
        assert_eq!(get("LSCOLORS"), Some(DEFAULT_LSCOLORS));
        assert_eq!(get("CLICOLOR"), Some("1"));
        assert_eq!(get("CHAU7_NEXT_STARTUP_CMD"), Some("echo hi"));
        assert_eq!(get("SHELL"), Some("/bin/zsh"));
        assert_eq!(get("TERM_SESSION_ID"), Some("ID"));
        let env = session_environment("/bin/zsh", "ID", "/tmp", "  ", false);
        assert!(
            !env.iter()
                .any(|(k, _)| k == "CLICOLOR" || k == "CHAU7_NEXT_STARTUP_CMD")
        );
    }

    #[test]
    fn missing_home_and_path() {
        let path = preferred_path(None, None);
        assert!(path.starts_with("/opt/homebrew/bin:"));
    }

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn preferred_path_prepends_common_user_bins() {
        let result = preferred_path_from_env(
            &env(&[("HOME", "/Users/tester"), ("PATH", "/usr/bin:/bin")]),
            "/fallback",
        );
        assert_eq!(
            result,
            "/Users/tester/bin:/Users/tester/.local/bin:/Users/tester/.volta/bin:/Users/tester/.cargo/bin:/Users/tester/.bun/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin"
        );
    }

    #[test]
    fn preferred_path_falls_back_when_path_missing() {
        let result = preferred_path_from_env(&env(&[("HOME", "/Users/tester")]), "/fallback");
        assert!(result.contains("/opt/homebrew/bin"));
        assert!(result.contains("/usr/bin"));
        assert!(result.contains("/Users/tester/.volta/bin"));
    }

    #[test]
    fn user_zdotdir_prefers_explicit_environment() {
        let environment = env(&[
            ("HOME", "/Users/tester"),
            ("ZDOTDIR", "/Users/tester/.config/zsh"),
        ]);
        assert_eq!(
            user_zdotdir(&environment, "/fallback"),
            "/Users/tester/.config/zsh"
        );
    }

    #[test]
    fn user_xdg_config_home_falls_back_to_home_config() {
        let environment = env(&[("HOME", "/Users/tester")]);
        assert_eq!(
            user_xdg_config_home(&environment, "/fallback"),
            "/Users/tester/.config"
        );
    }

    // Branches without a Swift test.

    #[test]
    fn blank_values_fall_back() {
        let environment = env(&[("HOME", "  "), ("ZDOTDIR", ""), ("XDG_CONFIG_HOME", " \n")]);
        assert_eq!(user_home(&environment, "/fallback"), "/fallback");
        assert_eq!(user_zdotdir(&environment, "/fallback"), "/fallback");
        assert_eq!(
            user_xdg_config_home(&environment, "/fallback"),
            "/fallback/.config"
        );
        let set = env(&[("HOME", "/h/"), ("XDG_CONFIG_HOME", " /x ")]);
        assert_eq!(user_xdg_config_home(&set, "/fallback"), "/x");
        assert_eq!(
            user_xdg_config_home(&env(&[("HOME", "/h/")]), "/f"),
            "/h/.config"
        );
    }

    fn vars(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    fn cto() -> &'static Path {
        Path::new("/h/sw/cto_bin")
    }

    #[test]
    fn cleanup_outside_chau7_only_drops_swift_variables() {
        let changes = inherited_cleanup(
            &vars(&[
                ("CHAU7_TAB_ID", "3"),
                ("CHAU7_NEXT_HOME_ROOT", "/tmp/x"),
                ("ANTHROPIC_BASE_URL", "http://127.0.0.1:18080"),
                ("ZDOTDIR", "/h/.config/zsh"),
            ]),
            cto(),
        );
        assert_eq!(changes, vec![EnvChange::Remove("CHAU7_TAB_ID".into())]);
    }

    #[test]
    fn cleanup_removes_claudecode() {
        let changes = inherited_cleanup(&vars(&[("CLAUDECODE", "1"), ("HOME", "/h")]), cto());
        assert_eq!(changes, vec![EnvChange::Remove("CLAUDECODE".into())]);
        assert!(inherited_cleanup(&vars(&[("HOME", "/h")]), cto()).is_empty());
    }

    #[test]
    fn cleanup_inside_chau7_restores_user_zdotdir_and_drops_proxy() {
        let changes = inherited_cleanup(
            &vars(&[
                ("TERM_PROGRAM", "Chau7"),
                ("CHAU7_SESSION_ID", "s"),
                ("CHAU7_USER_ZDOTDIR", "/h/.config/zsh"),
                ("ZDOTDIR", "/tmp/chau7-zsh"),
                ("ANTHROPIC_BASE_URL", "http://127.0.0.1:18080"),
                ("OPENAI_BASE_URL", "https://api.example.com/v1"),
            ]),
            cto(),
        );
        assert!(changes.contains(&EnvChange::Remove("CHAU7_SESSION_ID".into())));
        assert!(changes.contains(&EnvChange::Remove("CHAU7_USER_ZDOTDIR".into())));
        assert!(changes.contains(&EnvChange::Set("ZDOTDIR".into(), "/h/.config/zsh".into())));
        assert!(changes.contains(&EnvChange::Remove("ANTHROPIC_BASE_URL".into())));
        assert!(!changes.contains(&EnvChange::Remove("OPENAI_BASE_URL".into())));
        assert!(changes.contains(&EnvChange::Remove("TERM_PROGRAM".into())));
    }

    #[test]
    fn cleanup_inside_chau7_without_user_zdotdir_unsets_it() {
        let changes = inherited_cleanup(
            &vars(&[
                ("TERM_PROGRAM", "Chau7"),
                ("CHAU7_USER_ZDOTDIR", ""),
                ("ZDOTDIR", "/tmp/chau7-zsh"),
            ]),
            cto(),
        );
        assert!(changes.contains(&EnvChange::Remove("ZDOTDIR".into())));
    }

    #[test]
    fn cleanup_drops_the_swift_wrapper_folder_from_path() {
        let changes = inherited_cleanup(
            &vars(&[("PATH", "/h/sw/cto_bin:/usr/bin:/h/sw/cto_bin/:/bin")]),
            cto(),
        );
        assert_eq!(
            changes,
            vec![EnvChange::Set("PATH".into(), "/usr/bin:/bin".into())]
        );
        assert!(inherited_cleanup(&vars(&[("PATH", "/usr/bin")]), cto()).is_empty());
    }
}
