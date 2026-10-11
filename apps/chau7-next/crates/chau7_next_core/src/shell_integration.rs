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
//! (`CHAU7_NEXT_STARTUP_CMD`), and keeps `ANTHROPIC_CUSTOM_HEADERS`
//! (`X-Chau7-Session`, `X-Chau7-Tab`, `X-Chau7-Project`) up to date on every
//! directory change. The zsh wrapper also puts Volta image node toolchains
//! that ship `codex` ahead of `~/.volta/bin`.

use std::path::{Path, PathBuf};

/// Override Codex's supported base URL while keeping built-in provider/auth.
pub const CODEX_PROXY_WRAPPER: &str = include_str!("codex_proxy_wrapper.sh");

pub fn codex_wrapper_dir(dir: &Path) -> PathBuf {
    dir.join("bin")
}

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
if [ -n "$CHAU7_CTO_BIN_DIR" ] && [[ ${path[(Ie)$CHAU7_CTO_BIN_DIR]} -gt 0 ]]; then
  path=("$CHAU7_CTO_BIN_DIR" $path)
fi
if [ -n "$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR" ] && [ -x "$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR/codex" ]; then
  path=("$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR" $path)
fi
export CHAU7_TAB_ID=""
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
if [ "$CHAU7_NEXT_PROXY_CORRELATION_ENABLED" = "1" ]; then
 export CHAU7_NEXT_ANTHROPIC_HEADERS_BASE="${ANTHROPIC_CUSTOM_HEADERS:-}"
fi
_chau7_next_update_project() {
  local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  export CHAU7_NEXT_PROJECT="${git_root:-$PWD}"
  if [ "$CHAU7_NEXT_PROXY_CORRELATION_ENABLED" = "1" ]; then
    local headers="X-Chau7-Session: ${CHAU7_NEXT_SESSION_ID:-}
X-Chau7-Tab: ${CHAU7_NEXT_TAB_ID:-}
X-Chau7-Project: ${CHAU7_NEXT_PROJECT:-}"
    export ANTHROPIC_CUSTOM_HEADERS="${CHAU7_NEXT_ANTHROPIC_HEADERS_BASE:+$CHAU7_NEXT_ANTHROPIC_HEADERS_BASE
}$headers"
    if [ -z "${ENABLE_TOOL_SEARCH+x}" ]; then export ENABLE_TOOL_SEARCH=true; fi
  fi
  if [ -n "$CHAU7_NEXT_OPENAI_PROXY_BASE_URL" ]; then
    local project_token
    project_token=$(printf '%s' "$CHAU7_NEXT_PROJECT" | base64 | tr '+/' '-_' | tr -d '=\n')
    export OPENAI_BASE_URL="$CHAU7_NEXT_OPENAI_PROXY_BASE_URL/_chau7/project/$project_token/v1"
  fi
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
export CHAU7_TAB_ID=""
if [ -n "$CHAU7_CTO_BIN_DIR" ]; then
 case ":$PATH:" in *":$CHAU7_CTO_BIN_DIR:"*) export PATH="$CHAU7_CTO_BIN_DIR:$PATH" ;; esac
fi
if [ -n "$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR" ] && [ -x "$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR/codex" ]; then
 export PATH="$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR:$PATH"
fi
if [ -n "$CHAU7_NEXT_START_DIR" ] && [ -d "$CHAU7_NEXT_START_DIR" ]; then
  cd "$CHAU7_NEXT_START_DIR"
fi
unset CHAU7_NEXT_START_DIR
if [ "$CHAU7_NEXT_PROXY_CORRELATION_ENABLED" = "1" ]; then
 export CHAU7_NEXT_ANTHROPIC_HEADERS_BASE="${ANTHROPIC_CUSTOM_HEADERS:-}"
fi
_chau7_next_update_project() {
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  export CHAU7_NEXT_PROJECT="${git_root:-$PWD}"
  if [ "$CHAU7_NEXT_PROXY_CORRELATION_ENABLED" = "1" ]; then
    local headers="X-Chau7-Session: ${CHAU7_NEXT_SESSION_ID:-}
X-Chau7-Tab: ${CHAU7_NEXT_TAB_ID:-}
X-Chau7-Project: ${CHAU7_NEXT_PROJECT:-}"
    export ANTHROPIC_CUSTOM_HEADERS="${CHAU7_NEXT_ANTHROPIC_HEADERS_BASE:+$CHAU7_NEXT_ANTHROPIC_HEADERS_BASE
}$headers"
    if [ -z "${ENABLE_TOOL_SEARCH+x}" ]; then export ENABLE_TOOL_SEARCH=true; fi
  fi
  if [ -n "$CHAU7_NEXT_OPENAI_PROXY_BASE_URL" ]; then
    local project_token
    project_token=$(printf '%s' "$CHAU7_NEXT_PROJECT" | base64 | tr '+/' '-_' | tr -d '=\n')
    export OPENAI_BASE_URL="$CHAU7_NEXT_OPENAI_PROXY_BASE_URL/_chau7/project/$project_token/v1"
  fi
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
_chau7_next_update_project
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
set -gx CHAU7_TAB_ID ""
if test -n "$CHAU7_CTO_BIN_DIR"; and contains -- "$CHAU7_CTO_BIN_DIR" $PATH
 set -gx PATH "$CHAU7_CTO_BIN_DIR" $PATH
end
if test -n "$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR"; and test -x "$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR/codex"
 set -gx PATH "$CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR" $PATH
end
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
if test "$CHAU7_NEXT_PROXY_CORRELATION_ENABLED" = "1"
 set -gx CHAU7_NEXT_ANTHROPIC_HEADERS_BASE "$ANTHROPIC_CUSTOM_HEADERS"
end
function _chau7_next_update_project --on-variable PWD
  set -l git_root (git rev-parse --show-toplevel 2>/dev/null)
  if test -n "$git_root"
    set -gx CHAU7_NEXT_PROJECT $git_root
  else
    set -gx CHAU7_NEXT_PROJECT $PWD
  end
  if test "$CHAU7_NEXT_PROXY_CORRELATION_ENABLED" = "1"
    set -l headers "X-Chau7-Session: $CHAU7_NEXT_SESSION_ID
X-Chau7-Tab: $CHAU7_NEXT_TAB_ID
X-Chau7-Project: $CHAU7_NEXT_PROJECT"
    if test -n "$CHAU7_NEXT_ANTHROPIC_HEADERS_BASE"
      set -gx ANTHROPIC_CUSTOM_HEADERS "$CHAU7_NEXT_ANTHROPIC_HEADERS_BASE
$headers"
    else
      set -gx ANTHROPIC_CUSTOM_HEADERS "$headers"
    end
    if not set -q ENABLE_TOOL_SEARCH; set -gx ENABLE_TOOL_SEARCH true; end
  end
  if test -n "$CHAU7_NEXT_OPENAI_PROXY_BASE_URL"
    set -l project_token (printf '%s' "$CHAU7_NEXT_PROJECT" | base64 | tr '+/' '-_' | tr -d '=\n')
    set -gx OPENAI_BASE_URL "$CHAU7_NEXT_OPENAI_PROXY_BASE_URL/_chau7/project/$project_token/v1"
  end
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
    let bin = codex_wrapper_dir(dir);
    std::fs::create_dir_all(&bin)?;
    let wrapper = bin.join("codex");
    let temporary = bin.join(format!(".codex-{}", uuid::Uuid::new_v4()));
    std::fs::write(&temporary, CODEX_PROXY_WRAPPER)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o755))?;
    }
    let result = std::fs::rename(&temporary, wrapper);
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
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
            assert!(script.contains("ANTHROPIC_CUSTOM_HEADERS"), "{script}");
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

#[cfg(all(test, unix))]
mod codex_proxy_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    struct Fixture {
        dir: PathBuf,
        integration: PathBuf,
        real: PathBuf,
        local_ca: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let dir =
                std::env::temp_dir().join(format!("chau7-next-codex-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&dir).unwrap();
            let dir = std::fs::canonicalize(dir).unwrap();
            let integration = dir.join("owned shell");
            let real = dir.join("real tools");
            std::fs::create_dir_all(&real).unwrap();
            install(&integration).unwrap();
            let script = real.join("codex");
            std::fs::write(
                &script,
                r#"#!/bin/sh
printf '%s\0' "$@" > "$CAPTURE_DIR/args"
printf '%s' "$CODEX_CA_CERTIFICATE" > "$CAPTURE_DIR/ca"
printf '%s' "$PATH" > "$CAPTURE_DIR/path"
printf '%s' "$ANTHROPIC_CUSTOM_HEADERS" > "$CAPTURE_DIR/headers"
printf '%s' "$OPENAI_BASE_URL" > "$CAPTURE_DIR/base"
printf '%s' "$CHAU7_TAB_ID" > "$CAPTURE_DIR/legacy"
"#,
            )
            .unwrap();
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
            let local_ca = dir.join("local.pem");
            std::fs::write(&local_ca, "next-ca\n").unwrap();
            Self {
                dir,
                integration,
                real,
                local_ca,
            }
        }
        fn command(&self) -> std::process::Command {
            let mut c =
                std::process::Command::new(codex_wrapper_dir(&self.integration).join("codex"));
            c.env_clear()
                .current_dir(&self.dir)
                .env(
                    "PATH",
                    format!(
                        "{}:{}:/usr/bin:/bin",
                        codex_wrapper_dir(&self.integration).display(),
                        self.real.display()
                    ),
                )
                .env("CAPTURE_DIR", &self.dir)
                .env(
                    "CHAU7_NEXT_OPENAI_PROXY_BASE_URL",
                    "https://127.0.0.1:18091",
                )
                .env("CHAU7_NEXT_CODEX_CA_CERTIFICATE", &self.local_ca)
                .env("CHAU7_NEXT_TAB_ID", "../tab with/slashes");
            c
        }
        fn read(&self, name: &str) -> String {
            std::fs::read_to_string(self.dir.join(name)).unwrap()
        }
        fn args(&self) -> Vec<String> {
            self.read("args")
                .split('\0')
                .filter(|v| !v.is_empty())
                .map(str::to_string)
                .collect()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }
    #[test]
    fn native_shells_restore_wrapper_after_user_rc_and_update_correlation() {
        for shell in ["/bin/bash", "/bin/zsh"] {
            if !Path::new(shell).is_file() {
                continue;
            }
            let f = Fixture::new();
            let rc = format!(
                r#"export PATH="{}:/usr/bin:/bin"
export ANTHROPIC_CUSTOM_HEADERS='X-User: preserved'
export CHAU7_TAB_ID='legacy-owner'
"#,
                f.real.display()
            );
            std::fs::write(f.dir.join(".bashrc"), &rc).unwrap();
            std::fs::write(f.dir.join(".zshrc"), &rc).unwrap();
            let mut command = std::process::Command::new(shell);
            command
                .env_clear()
                .current_dir(&f.dir)
                .env("HOME", &f.dir)
                .env("CAPTURE_DIR", &f.dir)
                .env("PATH", "/usr/bin:/bin")
                .env("CHAU7_NEXT_USER_ZDOTDIR", &f.dir)
                .env("CHAU7_NEXT_PROXY_CORRELATION_ENABLED", "1")
                .env("CHAU7_NEXT_SESSION_ID", "session")
                .env("CHAU7_NEXT_TAB_ID", "tab")
                .env(
                    "CHAU7_NEXT_OPENAI_PROXY_BASE_URL",
                    "https://127.0.0.1:18091",
                )
                .env("CHAU7_NEXT_CODEX_CA_CERTIFICATE", &f.local_ca)
                .env(
                    "CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR",
                    codex_wrapper_dir(&f.integration),
                );
            if shell.ends_with("bash") {
                command
                    .args(["--noprofile", "--rcfile"])
                    .arg(bashrc_path(&f.integration));
            } else {
                command.env("ZDOTDIR", zsh_dir(&f.integration));
            }
            let out = command.args(["-i", "-c", "codex resume"]).output().unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            assert_eq!(f.args().len(), 3);
            assert_eq!(f.read("legacy"), "");
            assert_eq!(
                f.read("headers"),
                format!(
                    "X-User: preserved\nX-Chau7-Session: session\nX-Chau7-Tab: tab\nX-Chau7-Project: {}",
                    f.dir.display()
                )
            );
            assert_eq!(
                f.read("base"),
                format!(
                    "https://127.0.0.1:18091{}/v1",
                    crate::proxy::proxy_project_path(&f.dir.to_string_lossy())
                )
            );
            // A shell without enabled analytics leaves the user's headers alone.
            let out = command
                .env_remove("CHAU7_NEXT_PROXY_CORRELATION_ENABLED")
                .env_remove("CHAU7_NEXT_OPENAI_PROXY_BASE_URL")
                .env_remove("CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR")
                .output()
                .unwrap();
            assert!(out.status.success());
            assert_eq!(f.read("headers"), "X-User: preserved");
            assert_eq!(f.args(), ["resume"]);
        }
    }
    #[test]
    fn codex_wrapper_keeps_subscription_provider_and_literal_arguments() {
        let f = Fixture::new();
        let out = f
            .command()
            .args([
                "resume",
                "quoted \"prompt\"; $(literal)",
                "--model",
                "gpt-5",
            ])
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let args = f.args();
        assert_eq!(args[0], "-c");
        assert_eq!(
            args[1],
            format!(
                r#"openai_base_url="https://127.0.0.1:18091{}/v1""#,
                crate::proxy::proxy_project_path(&f.dir.to_string_lossy())
            )
        );
        assert_eq!(
            &args[2..],
            [
                "resume",
                "quoted \"prompt\"; $(literal)",
                "--model",
                "gpt-5"
            ]
        );
        assert_eq!(f.read("ca"), f.local_ca.to_string_lossy());
        assert!(
            !f.read("path").contains(
                &codex_wrapper_dir(&f.integration)
                    .to_string_lossy()
                    .to_string()
            )
        );
        assert!(
            !args
                .iter()
                .any(|arg| arg.contains("model_provider") || arg.contains("auth"))
        );
    }
    #[test]
    fn codex_wrapper_merges_user_ca_in_private_owned_bundle() {
        let f = Fixture::new();
        let user = f.dir.join("user.pem");
        std::fs::write(&user, "user-ca\n").unwrap();
        assert!(
            f.command()
                .env("CODEX_CA_CERTIFICATE", &user)
                .arg("login")
                .status()
                .unwrap()
                .success()
        );
        let combined = PathBuf::from(f.read("ca"));
        assert!(combined.starts_with(f.integration.join("codex-ca")));
        assert_eq!(
            std::fs::read_to_string(&combined).unwrap(),
            "user-ca\nnext-ca\n"
        );
        assert_eq!(
            std::fs::metadata(&combined).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(std::fs::read_to_string(user).unwrap(), "user-ca\n");
    }
    #[test]
    fn codex_wrapper_missing_ca_or_untrusted_route_passes_through_unchanged() {
        for route in [
            "https://remote.example:18091",
            "https://127.0.0.1:18091/evil",
            "https://127.0.0.1:1",
            "https://127.0.0.1:999999999999999999999999",
        ] {
            let f = Fixture::new();
            assert!(
                f.command()
                    .env("CHAU7_NEXT_OPENAI_PROXY_BASE_URL", route)
                    .args(["login", "--device-auth"])
                    .status()
                    .unwrap()
                    .success()
            );
            assert_eq!(f.args(), ["login", "--device-auth"]);
        }
        let f = Fixture::new();
        assert!(
            f.command()
                .env("CHAU7_NEXT_CODEX_CA_CERTIFICATE", f.dir.join("missing"))
                .arg("resume")
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(f.args(), ["resume"]);
        let f = Fixture::new();
        assert!(
            f.command()
                .env_remove("CHAU7_NEXT_OPENAI_PROXY_BASE_URL")
                .arg("--version")
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(f.args(), ["--version"]);
    }
    #[test]
    fn codex_wrapper_skips_canonical_alias_and_reports_missing_executable() {
        let f = Fixture::new();
        let alias = f.dir.join("alias");
        std::os::unix::fs::symlink(codex_wrapper_dir(&f.integration), &alias).unwrap();
        assert!(
            f.command()
                .env(
                    "PATH",
                    format!(
                        "{}:{}:{}:/usr/bin:/bin",
                        codex_wrapper_dir(&f.integration).display(),
                        alias.display(),
                        f.real.display()
                    )
                )
                .arg("--version")
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(f.args().len(), 3);
        let out = f
            .command()
            .env(
                "PATH",
                format!(
                    "{}:/usr/bin:/bin",
                    codex_wrapper_dir(&f.integration).display()
                ),
            )
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(127));
    }
}
