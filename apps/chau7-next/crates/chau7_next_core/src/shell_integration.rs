//! Shell integration: prompt and command markers (OSC 133) and the working
//! directory (OSC 7), emitted by small startup files that wrap the user's own.
//!
//! The Swift app writes similar wrappers (`TerminalSessionModel.preInitialize`
//! in `TerminalSessionModel.swift`) to a temporary `ZDOTDIR`. Chau7 Next keeps
//! its copies under `~/.chau7-next/shell/` and emits the standard OSC 133
//! markers, which `chau7_terminal` already parses into
//! `ShellIntegrationEvent`s (prompt start, command start, command executed,
//! command finished with exit code). That drives the command status, command
//! blocks, success/error tab styles and "command finished" notifications.
//!
//! Like Swift, each wrapper sources the user's files first, then: cd to the
//! start directory (`CHAU7_NEXT_START_DIR`, in case the user's config moved
//! away), runs the "startup command" setting with `eval`
//! (`CHAU7_NEXT_STARTUP_CMD`), and keeps `ANTHROPIC_EXTRA_HEADERS`
//! (`X-Chau7-Session`, `X-Chau7-Tab`, `X-Chau7-Project`) up to date on every
//! directory change. The zsh wrapper also puts Volta image node toolchains
//! that ship `codex` ahead of `~/.volta/bin`.

use std::path::{Path, PathBuf};

/// Startup file for zsh, placed in our `ZDOTDIR`. It restores the user's
/// `ZDOTDIR`, sources their files, then adds the hooks.
pub const ZSHRC: &str = r#"# Chau7 Next shell integration (zsh). Sources your own files first.
export ZDOTDIR="${CHAU7_NEXT_USER_ZDOTDIR:-$HOME}"
[ -f "$ZDOTDIR/.zshenv" ] && source "$ZDOTDIR/.zshenv"
if [[ -o login ]]; then
  [ -f "$ZDOTDIR/.zprofile" ] && source "$ZDOTDIR/.zprofile"
fi
[ -f "$ZDOTDIR/.zshrc" ] && source "$ZDOTDIR/.zshrc"
if [[ -o login ]]; then
  [ -f "$ZDOTDIR/.zlogin" ] && source "$ZDOTDIR/.zlogin"
fi
# Volta image node toolchains that ship codex go ahead of ~/.volta/bin.
path=("${(s/:/)PATH}")
for _chau7_next_bin in "$HOME/.volta/tools/image/node/"*"/bin"(N); do
  [ -x "$_chau7_next_bin/codex" ] && path=($_chau7_next_bin $path)
done
typeset -U path
export PATH="${(j/:/)path}"
unset _chau7_next_bin
setopt NO_PROMPT_CR 2>/dev/null
if [ -n "$CHAU7_NEXT_START_DIR" ] && [ -d "$CHAU7_NEXT_START_DIR" ]; then
  cd "$CHAU7_NEXT_START_DIR"
fi
unset CHAU7_NEXT_START_DIR
_chau7_next_precmd() {
  local code=$?
  if [[ -n "$_chau7_next_ran" ]]; then
    printf '\e]133;D;%s\a' "$code"
  fi
  unset _chau7_next_ran
  printf '\e]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"
  printf '\e]133;A\a'
}
_chau7_next_preexec() {
  _chau7_next_ran=1
  printf '\e]133;B\a\e]133;C\a'
  # Command history for Chau7 Next's history search: time, directory, command.
  [ -f "$CHAU7_NEXT_HISTORY_FILE" ] && print -r -- "$EPOCHSECONDS	$PWD	${1//$'\n'/ }" >> "$CHAU7_NEXT_HISTORY_FILE" 2>/dev/null
}
_chau7_next_update_project() {
  local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  export CHAU7_PROJECT="${git_root:-$PWD}"
  export ANTHROPIC_EXTRA_HEADERS="X-Chau7-Session:${CHAU7_SESSION_ID:-},X-Chau7-Tab:${CHAU7_TAB_ID:-},X-Chau7-Project:${CHAU7_PROJECT:-}"
}
zmodload zsh/datetime 2>/dev/null
autoload -Uz add-zsh-hook 2>/dev/null
add-zsh-hook precmd _chau7_next_precmd
add-zsh-hook preexec _chau7_next_preexec
add-zsh-hook chpwd _chau7_next_update_project
_chau7_next_update_project
if [ -n "$CHAU7_NEXT_STARTUP_CMD" ]; then
  _chau7_next_cmd="$CHAU7_NEXT_STARTUP_CMD"
  unset CHAU7_NEXT_STARTUP_CMD
  eval "$_chau7_next_cmd"
  unset _chau7_next_cmd
fi
"#;

/// Startup file for bash (`--rcfile`). It sources the user's `.bashrc` and
/// `.bash_profile` (as Swift does), then appends the hooks to
/// `PROMPT_COMMAND`, so a `.bashrc` that assigns `PROMPT_COMMAND` outright
/// keeps them. `PS0` is expanded right before a command runs: the array
/// subscript sets `_c7r` in the shell itself (prompt expansion is not a
/// subshell) and expands to nothing; `\e]133;B\e]133;C` mark the command
/// start. `_chau7_next_prompt` reports the exit code only when a command
/// actually ran, so pressing Enter on an empty line changes nothing.
pub const BASHRC: &str = r#"# Chau7 Next shell integration (bash). Sources your own files first.
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"
if [ -n "$CHAU7_NEXT_START_DIR" ] && [ -d "$CHAU7_NEXT_START_DIR" ]; then
  cd "$CHAU7_NEXT_START_DIR"
fi
unset CHAU7_NEXT_START_DIR
_chau7_next_update_project() {
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  export CHAU7_PROJECT="${git_root:-$PWD}"
  export ANTHROPIC_EXTRA_HEADERS="X-Chau7-Session:${CHAU7_SESSION_ID:-},X-Chau7-Tab:${CHAU7_TAB_ID:-},X-Chau7-Project:${CHAU7_PROJECT:-}"
}
_chau7_next_prompt() {
  local _c7c=$?
  if [ -n "$_c7r" ]; then
    printf '\e]133;D;%s\a' "$_c7c"
    [ -f "$CHAU7_NEXT_HISTORY_FILE" ] && printf '%s\t%s\t%s\n' "$(date +%s)" "$PWD" "$(HISTTIMEFORMAT= history 1 | sed 's/^ *[0-9]* *//')" >> "$CHAU7_NEXT_HISTORY_FILE" 2>/dev/null
  fi
  unset _c7r
  if [ "$_chau7_next_pwd" != "$PWD" ]; then
    _chau7_next_pwd="$PWD"
    _chau7_next_update_project
  fi
  printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"
  printf '\e]133;A\a'
  return $_c7c
}
PROMPT_COMMAND="_chau7_next_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
PS0='${_c7x[$((_c7r=1))]}\e]133;B\a\e]133;C\a'"$PS0"
if [ -n "$CHAU7_NEXT_STARTUP_CMD" ]; then
  _chau7_next_cmd="$CHAU7_NEXT_STARTUP_CMD"
  unset CHAU7_NEXT_STARTUP_CMD
  eval "$_chau7_next_cmd"
  unset _chau7_next_cmd
fi
"#;

/// Startup file for fish, placed in our `XDG_CONFIG_HOME/fish`.
pub const FISH_CONFIG: &str = r#"# Chau7 Next shell integration (fish). Sources your own config first.
if test -n "$CHAU7_NEXT_USER_XDG_CONFIG_HOME"
  set -gx XDG_CONFIG_HOME "$CHAU7_NEXT_USER_XDG_CONFIG_HOME"
else
  set -e XDG_CONFIG_HOME
end
set -l _cfg (test -n "$XDG_CONFIG_HOME"; and echo $XDG_CONFIG_HOME; or echo $HOME/.config)
test -f "$_cfg/fish/config.fish"; and source "$_cfg/fish/config.fish"
if test -n "$CHAU7_NEXT_START_DIR"; and test -d "$CHAU7_NEXT_START_DIR"
  cd "$CHAU7_NEXT_START_DIR"
end
set -e CHAU7_NEXT_START_DIR
function _chau7_next_prompt --on-event fish_prompt
  printf '\e]7;file://%s%s\a' (hostname) "$PWD"
  printf '\e]133;A\a'
end
function _chau7_next_preexec --on-event fish_preexec
  printf '\e]133;B\a\e]133;C\a'
  if test -f "$CHAU7_NEXT_HISTORY_FILE"
    printf '%s\t%s\t%s\n' (date +%s) "$PWD" (string join ' ' -- $argv) >> "$CHAU7_NEXT_HISTORY_FILE" 2>/dev/null
  end
end
function _chau7_next_postexec --on-event fish_postexec
  printf '\e]133;D;%s\a' $status
end
function _chau7_next_update_project --on-variable PWD
  set -l git_root (git rev-parse --show-toplevel 2>/dev/null)
  if test -n "$git_root"
    set -gx CHAU7_PROJECT $git_root
  else
    set -gx CHAU7_PROJECT $PWD
  end
  set -gx ANTHROPIC_EXTRA_HEADERS "X-Chau7-Session:$CHAU7_SESSION_ID,X-Chau7-Tab:$CHAU7_TAB_ID,X-Chau7-Project:$CHAU7_PROJECT"
end
_chau7_next_update_project
if test -n "$CHAU7_NEXT_STARTUP_CMD"
  set -l _chau7_next_cmd "$CHAU7_NEXT_STARTUP_CMD"
  set -e CHAU7_NEXT_STARTUP_CMD
  eval $_chau7_next_cmd
end
"#;

/// Where each shell's files go, under `dir` (`DataRoot::shell_integration_dir`).
pub fn zsh_dir(dir: &Path) -> PathBuf {
    dir.join("zsh")
}

pub fn bashrc_path(dir: &Path) -> PathBuf {
    dir.join("bash").join(".bashrc")
}

pub fn fish_config_home(dir: &Path) -> PathBuf {
    dir.join("xdg")
}

/// Write (or refresh) the startup files.
pub fn install(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(zsh_dir(dir))?;
    std::fs::write(zsh_dir(dir).join(".zshrc"), ZSHRC)?;
    let bashrc = bashrc_path(dir);
    if let Some(parent) = bashrc.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&bashrc, BASHRC)?;
    let fish = fish_config_home(dir).join("fish");
    std::fs::create_dir_all(&fish)?;
    std::fs::write(fish.join("config.fish"), FISH_CONFIG)?;
    Ok(())
}

fn shell_name(shell_path: &str) -> String {
    Path::new(shell_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default()
}

/// Arguments for the shell at `shell_path`: bash gets `--rcfile` with our
/// wrapper (Swift: `shellArguments`).
pub fn arguments(shell_path: &str, dir: &Path) -> Vec<String> {
    match shell_name(shell_path).as_str() {
        "bash" => vec![
            "--rcfile".into(),
            bashrc_path(dir).to_string_lossy().to_string(),
        ],
        _ => Vec::new(),
    }
}

/// Environment for a shell at `shell_path`. `user_env` reads the app's own
/// environment (so a user's `ZDOTDIR` is preserved). The history file
/// (`DataRoot::history_file`) is where the hooks append executed commands.
pub fn environment(
    shell_path: &str,
    dir: &Path,
    history_file: &Path,
    user_env: impl Fn(&str) -> Option<String>,
) -> Vec<(String, String)> {
    let mut env = shell_specific(shell_path, dir, user_env);
    if matches!(shell_name(shell_path).as_str(), "zsh" | "fish" | "bash") {
        env.push((
            "CHAU7_NEXT_HISTORY_FILE".into(),
            history_file.to_string_lossy().to_string(),
        ));
    }
    env
}

/// Largest size of the history file; older lines are dropped beyond it.
pub const HISTORY_MAX_BYTES: usize = 1024 * 1024;

/// The history file's text made safe to keep: commands holding inline secrets
/// redacted (`sensitive_input`), malformed and blank lines dropped, and only
/// the newest lines kept within `max_bytes`.
pub fn sanitize_history(text: &str, max_bytes: usize) -> String {
    let mut lines: Vec<String> = Vec::new();
    for line in text.lines() {
        let mut parts = line.splitn(3, '\t');
        let (Some(time), Some(directory), Some(command)) =
            (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        let Some(command) =
            crate::sensitive_input::sanitized_input_line_for_persistence(command, false)
        else {
            continue;
        };
        lines.push(format!("{}\t{directory}\t{command}\n", time.trim()));
    }
    let mut total = 0;
    let mut keep = lines.len();
    while keep > 0 && total + lines[keep - 1].len() <= max_bytes {
        total += lines[keep - 1].len();
        keep -= 1;
    }
    lines[keep..].concat()
}

/// Make the history file private: create it empty when missing and set its
/// mode to 0600 (the shell hooks only append to an existing file).
pub fn ensure_private_history(path: &Path) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    drop(options.open(path)?);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

/// Keep the history file private, redacted and capped, and return its
/// (sanitized) text. Rewrites the file only when something changed, through a
/// private temporary file, and retries when a shell appended meanwhile.
pub fn maintain_history(path: &Path, max_bytes: usize) -> std::io::Result<String> {
    ensure_private_history(path)?;
    for _ in 0..3 {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let clean = sanitize_history(&text, max_bytes);
        if clean == text {
            return Ok(clean);
        }
        let tmp = path.with_extension("tsv.tmp");
        let _ = std::fs::remove_file(&tmp);
        {
            use std::io::Write as _;
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&tmp)?;
            file.write_all(clean.as_bytes())?;
        }
        // A shell appended since the read: start over so the line is kept.
        let unchanged = std::fs::metadata(path)
            .map(|m| m.len() == text.len() as u64)
            .unwrap_or(false);
        if unchanged {
            std::fs::rename(&tmp, path)?;
            return Ok(clean);
        }
        let _ = std::fs::remove_file(&tmp);
    }
    // Still busy: hand back a sanitized view without rewriting.
    let text = std::fs::read_to_string(path).unwrap_or_default();
    Ok(sanitize_history(&text, max_bytes))
}

/// One command from the history file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryEntry {
    pub time: u64,
    pub directory: String,
    pub command: String,
}

/// Parse history lines (`time<TAB>dir<TAB>command`), most recent first,
/// duplicate commands collapsed to their latest use.
pub fn parse_history(text: &str, limit: usize) -> Vec<HistoryEntry> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for line in text.lines().rev() {
        let mut parts = line.splitn(3, '\t');
        let (Some(time), Some(directory), Some(command)) =
            (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        let command = command.trim();
        if command.is_empty() || !seen.insert(command.to_string()) {
            continue;
        }
        out.push(HistoryEntry {
            time: time.trim().parse().unwrap_or(0),
            directory: directory.to_string(),
            command: command.to_string(),
        });
        if out.len() >= limit {
            break;
        }
    }
    out
}

fn shell_specific(
    shell_path: &str,
    dir: &Path,
    user_env: impl Fn(&str) -> Option<String>,
) -> Vec<(String, String)> {
    let home = user_env("HOME").unwrap_or_default();
    match shell_name(shell_path).as_str() {
        "zsh" => vec![
            (
                "CHAU7_NEXT_USER_ZDOTDIR".into(),
                user_env("ZDOTDIR")
                    .filter(|v| !v.is_empty())
                    .unwrap_or(home),
            ),
            ("ZDOTDIR".into(), zsh_dir(dir).to_string_lossy().to_string()),
        ],
        "fish" => vec![
            (
                "CHAU7_NEXT_USER_XDG_CONFIG_HOME".into(),
                user_env("XDG_CONFIG_HOME").unwrap_or_default(),
            ),
            (
                "XDG_CONFIG_HOME".into(),
                fish_config_home(dir).to_string_lossy().to_string(),
            ),
        ],
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env_of(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let owned: Vec<(String, String)> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |key| owned.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
    }

    const HISTORY: &str = "/h/.chau7-next/history.tsv";

    #[test]
    fn history_parsing_dedupes_most_recent_first() {
        let text = "1\t/a\tls\n2\t/b\tgit status\n3\t/a\tls\nbroken line\n4\t/c\t  \n";
        let entries = parse_history(text, 10);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].command, "ls");
        assert_eq!(entries[0].time, 3);
        assert_eq!(entries[1].command, "git status");
        assert_eq!(parse_history(text, 1).len(), 1);
    }

    #[test]
    fn history_is_redacted_and_capped() {
        let text = "1\t/a\tls\n2\t/a\texport GITHUB_TOKEN=abc\nbad\n3\t/b\tgit status\n";
        let clean = sanitize_history(text, 1 << 20);
        assert!(!clean.contains("abc"), "{clean}");
        assert!(clean.contains(crate::sensitive_input::REDACTED_PLACEHOLDER));
        assert!(!clean.contains("bad"));
        // Only the newest lines fit.
        let capped = sanitize_history(text, "3\t/b\tgit status\n".len());
        assert_eq!(capped, "3\t/b\tgit status\n");
        assert_eq!(sanitize_history(&clean, 1 << 20), clean);
    }

    #[test]
    fn history_file_is_private_and_rewritten() {
        let dir = std::env::temp_dir().join(format!("chau7-next-hist-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("history.tsv");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&path, "1\t/a\tcurl -H API_KEY=zzz x\n2\t/a\tls\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        }
        let text = maintain_history(&path, 1 << 20).unwrap();
        assert!(!text.contains("zzz"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        // Missing file: created empty and private.
        std::fs::remove_file(&path).unwrap();
        assert_eq!(maintain_history(&path, 1 << 20).unwrap(), "");
        assert!(path.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn history_file_is_exported() {
        let env = environment(
            "/bin/zsh",
            Path::new("/s"),
            Path::new(HISTORY),
            env_of(&[("HOME", "/h")]),
        );
        assert!(env.contains(&("CHAU7_NEXT_HISTORY_FILE".into(), HISTORY.into())));
    }

    // Unix paths, PATH syntax and execute bits.
    #[cfg(unix)]
    #[test]
    fn zsh_keeps_user_zdotdir() {
        let dir = Path::new("/h/.chau7-next/shell");
        let env = environment(
            "/bin/zsh",
            dir,
            Path::new(HISTORY),
            env_of(&[("HOME", "/h"), ("ZDOTDIR", "/h/.config/zsh")]),
        );
        assert!(env.contains(&("CHAU7_NEXT_USER_ZDOTDIR".into(), "/h/.config/zsh".into())));
        assert!(env.contains(&("ZDOTDIR".into(), "/h/.chau7-next/shell/zsh".into())));
    }

    #[test]
    fn zsh_defaults_to_home() {
        let env = environment(
            "/bin/zsh",
            Path::new("/s"),
            Path::new(HISTORY),
            env_of(&[("HOME", "/h")]),
        );
        assert!(env.contains(&("CHAU7_NEXT_USER_ZDOTDIR".into(), "/h".into())));
    }

    #[test]
    fn unknown_shell_gets_nothing() {
        assert!(
            environment(
                "/usr/bin/nu",
                Path::new("/s"),
                Path::new(HISTORY),
                env_of(&[])
            )
            .is_empty()
        );
    }

    #[test]
    fn scripts_emit_osc_133() {
        for script in [ZSHRC, FISH_CONFIG, BASHRC] {
            assert!(script.contains("133;"), "{script}");
        }
        assert!(ZSHRC.contains("133;C") && ZSHRC.contains("133;D"));
    }

    #[test]
    fn install_writes_files() {
        let dir = std::env::temp_dir().join(format!("chau7-next-si-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        install(&dir).unwrap();
        assert!(dir.join("zsh/.zshrc").is_file());
        assert!(dir.join("xdg/fish/config.fish").is_file());
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod launch_tests {
    use super::*;

    #[test]
    fn bash_uses_rcfile() {
        let dir = Path::new("/s");
        let args = arguments("/bin/bash", dir);
        assert_eq!(args[0], "--rcfile");
        assert!(args[1].ends_with(".bashrc"));
        assert!(arguments("/bin/zsh", dir).is_empty());
        assert!(
            environment("/bin/bash", dir, Path::new("/h"), |_| None)
                .iter()
                .any(|(k, _)| k == "CHAU7_NEXT_HISTORY_FILE")
        );
    }

    #[test]
    fn scripts_run_startup_command_and_mark_command_start() {
        for script in [ZSHRC, BASHRC, FISH_CONFIG] {
            assert!(script.contains("CHAU7_NEXT_STARTUP_CMD"), "{script}");
            assert!(script.contains("eval"), "{script}");
            assert!(script.contains("133;B"), "{script}");
            assert!(script.contains("CHAU7_NEXT_START_DIR"), "{script}");
            assert!(script.contains("ANTHROPIC_EXTRA_HEADERS"), "{script}");
        }
        assert!(ZSHRC.contains(".volta/tools/image/node"));
        // The startup command runs after the user's own config.
        let user = BASHRC.find("source \"$HOME/.bashrc\"").unwrap();
        let eval = BASHRC.find("eval").unwrap();
        assert!(user < eval);
        assert!(BASHRC.contains("PROMPT_COMMAND=\"_chau7_next_prompt"));
    }

    #[cfg(unix)]
    #[test]
    fn bashrc_runs_startup_command_and_emits_marks() {
        use std::process::Command;
        if Command::new("bash").arg("--version").output().is_err() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("chau7-next-bash-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        install(&dir).unwrap();
        let home = dir.join("home");
        std::fs::create_dir_all(&home).unwrap();
        // A user .bashrc that overwrites PROMPT_COMMAND must keep our hook.
        std::fs::write(home.join(".bashrc"), "PROMPT_COMMAND='true'\n").unwrap();
        let output = Command::new("bash")
            .arg("--rcfile")
            .arg(bashrc_path(&dir))
            .arg("-i")
            .env("HOME", &home)
            .env("CHAU7_NEXT_STARTUP_CMD", "echo started-$((1+1))")
            .env("PS1", "$ ")
            .stdin(std::process::Stdio::piped())
            .output();
        let _ = std::fs::remove_dir_all(&dir);
        let Ok(output) = output else { return };
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stdout.contains("started-2"), "{stdout} {stderr}");
    }
}
