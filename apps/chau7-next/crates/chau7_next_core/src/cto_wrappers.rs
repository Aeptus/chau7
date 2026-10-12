//! Token optimization (CTO) on disk: wrapper script generation, the per-session
//! flag files, installation health, the command log and the optimizer's gain
//! output.
//!
//! Port of `CTOManager.swift` and `CTOFlagManager.swift`. Every path comes
//! from [`CtoPaths`] (built from [`DataRoot`]), so Chau7 Next keeps its own
//! wrapper folder and never touches the Swift app's `cto_bin`, `cto_active`
//! or `cto_data`. The generated scripts contain absolute paths (the Swift
//! scripts use `$HOME/...`), and pass `CHAU7_CTO_BIN_DIR` to the optimizer so
//! that it strips Chau7 Next's folder from `PATH` (otherwise the optimizer
//! would run the wrapper it was called from).

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::data_root::DataRoot;
use crate::debug_console::CtoLogEntry;
use crate::token_optimization::{
    CTOFlagDecision, CTOGainStats, EXEC_ONLY_COMMANDS, PIPE_FILTER_COMMANDS, TabTokenOptOverride,
    TokenOptimizationMode, WrapperHealth, cto_rewrite, should_be_active, supported_commands,
};

/// Environment variable read by `chau7-optim`: extra wrapper folders to strip
/// from `PATH` (colon separated).
pub const CTO_BIN_DIR_ENV: &str = "CHAU7_CTO_BIN_DIR";

/// Environment variable of the optimizer's tracking database path.
pub const OPTIMIZER_DB_ENV: &str = "RTK_DB_PATH";

/// Where everything of the token optimizer lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CtoPaths {
    /// Wrapper scripts, prepended to `PATH` (`cto_bin`).
    pub wrapper_dir: PathBuf,
    /// Per-session flag files (`cto_active`).
    pub flag_dir: PathBuf,
    /// Helper binaries (`chau7-optim`, `chau7-md`).
    pub bin_dir: PathBuf,
    /// Command log and gain database (`cto_data`).
    pub data_dir: PathBuf,
    /// The Swift app's wrapper folder: never written, only removed from the
    /// `PATH` used to find the real binaries.
    pub swift_wrapper_dir: PathBuf,
}

impl CtoPaths {
    pub fn from_root(root: &DataRoot) -> Self {
        Self {
            wrapper_dir: root.cto_bin_dir(),
            flag_dir: root.cto_active_dir(),
            bin_dir: root.bin_dir(),
            data_dir: root.cto_data_dir(),
            swift_wrapper_dir: root.swift_cto_bin_dir(),
        }
    }

    /// Diagnostic mirror beside isolated Next CTO flags. Never used on the wrapper hot path.
    pub fn state_file(&self) -> PathBuf {
        self.flag_dir.with_file_name("cto_state.json")
    }

    pub fn optimizer(&self) -> PathBuf {
        self.bin_dir.join("chau7-optim")
    }

    pub fn markdown_renderer(&self) -> PathBuf {
        self.bin_dir.join("chau7-md")
    }

    pub fn command_log(&self) -> PathBuf {
        self.data_dir.join("commands.log")
    }

    /// The optimizer's tracking database (`RTK_DB_PATH`), separate from the
    /// Swift app's so each app's statistics stay its own.
    pub fn gain_database(&self) -> PathBuf {
        self.data_dir.join("history.db")
    }

    /// The wrapper folders to strip from `PATH` (`CHAU7_CTO_BIN_DIR`).
    pub fn bin_dir_env_value(&self) -> String {
        self.wrapper_dir.to_string_lossy().to_string()
    }

    /// `PATH` with the wrapper folder in front, once (`prependedPATH`).
    pub fn prepended_path(&self, original: &str) -> String {
        let wrapper = self.wrapper_dir.to_string_lossy();
        if original.split(':').any(|p| p == wrapper) {
            return original.to_string();
        }
        format!("{wrapper}:{original}")
    }
}

// ----- shell quoting -----------------------------------------------------------------

/// A path inside double quotes for sh (`$`, backtick, quote and backslash
/// escaped), so `$CHAU7_CTO_SESSION` can follow it in the same word.
fn dq(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        if matches!(c, '"' | '$' | '`' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// A value inside single quotes for sh.
fn sq(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

// ----- wrapper scripts ---------------------------------------------------------------

/// The real binary of `command`: the first executable named so in `path_env`,
/// skipping the wrapper folders (`resolveRealBinary`).
pub fn resolve_real_binary(command: &str, path_env: &str, skip: &[&Path]) -> Option<String> {
    for dir in path_env.split(':') {
        if dir.is_empty() || skip.iter().any(|s| s.to_string_lossy() == dir) {
            continue;
        }
        let candidate = Path::new(dir).join(command);
        if is_executable_file(&candidate) {
            return Some(candidate.to_string_lossy().to_string());
        }
    }
    None
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(meta) = fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// Generates the wrapper script of a command (`generateWrapperScript`).
pub fn wrapper_script(command: &str, real_bin: Option<&str>, paths: &CtoPaths) -> String {
    match command {
        "cat" => cat_script(real_bin, paths),
        "sed" => sed_script(real_bin, paths),
        _ => generic_script(command, real_bin, paths),
    }
}

/// `exec` prefix variables passed to the optimizer.
fn optim_env(paths: &CtoPaths) -> String {
    format!(
        "{CTO_BIN_DIR_ENV}={} {OPTIMIZER_DB_ENV}={}",
        sq(&paths.bin_dir_env_value()),
        sq(&paths.gain_database().to_string_lossy())
    )
}

/// Log line writers of the optimizer block. `$_rc` is the optimizer's exit.
fn log_block(command: &str) -> String {
    format!(
        r#"if [ $_rc -ne 2 ] && [ $_rc -ne 3 ]; then
        [ -n "$CHAU7_CTO_LOG" ] && echo "$(date +%s)|$CHAU7_CTO_SESSION|{command}|$_rc|optimized" >>"$CHAU7_CTO_LOG"
        exit $_rc
    fi
    if [ -n "$CHAU7_CTO_LOG" ]; then
        if [ $_rc -eq 3 ]; then
            echo "$(date +%s)|$CHAU7_CTO_SESSION|{command}|$_rc|skipped" >>"$CHAU7_CTO_LOG"
        else
            echo "$(date +%s)|$CHAU7_CTO_SESSION|{command}|$_rc|fallthrough" >>"$CHAU7_CTO_LOG"
        fi
    fi"#
    )
}

/// The lines that find the real binary at run time when none was found at
/// generation time, and that check the flag.
fn runtime_scan(command: &str, paths: &CtoPaths) -> String {
    format!(
        r#"_CTO_REAL_BIN=""
_OLD_IFS="$IFS"; IFS=':'
for _dir in $PATH; do
    [ "$_dir" = {own} ] && continue
    [ "$_dir" = {swift} ] && continue
    if [ -x "$_dir/{command}" ]; then _CTO_REAL_BIN="$_dir/{command}"; break; fi
done
IFS="$_OLD_IFS"

if [ -z "$_CTO_REAL_BIN" ]; then
    echo "chau7: could not find real {command} binary" >&2
    exit 127
fi
"#,
        own = dq(&paths.wrapper_dir.to_string_lossy()),
        swift = dq(&paths.swift_wrapper_dir.to_string_lossy()),
    )
}

fn flag_test(paths: &CtoPaths) -> String {
    format!(
        r#"[ -n "$CHAU7_CTO_OPTIM_ACTIVE" ] || [ -z "$CHAU7_CTO_SESSION" ] || [ ! -f {} ]"#,
        flag_path_word(paths)
    )
}

/// `"<flag dir>/$CHAU7_CTO_SESSION"`, as one double quoted word.
fn flag_path_word(paths: &CtoPaths) -> String {
    let dir = dq(&paths.flag_dir.to_string_lossy());
    // dq ends with a quote: put the separator and the variable inside it.
    format!("{}/$CHAU7_CTO_SESSION\"", &dir[..dir.len() - 1])
}

/// Generic wrapper (`generateGenericWrapperScript`): a fast path of two tests
/// and an `exec` when no flag exists; with the flag, run the optimizer and
/// fall through to the real binary on exit 2 (cannot parse) or 3 (skip).
fn generic_script(command: &str, real_bin: Option<&str>, paths: &CtoPaths) -> String {
    let optimizer_block = match cto_rewrite(command) {
        Some(sub) => format!(
            r#"_CHAU7_OPTIM={optim}
if [ -x "$_CHAU7_OPTIM" ]; then
    {env} "$_CHAU7_OPTIM" {sub} "$@" 2>/dev/null
    _rc=$?
    {log}
fi"#,
            optim = dq(&paths.optimizer().to_string_lossy()),
            env = optim_env(paths),
            log = log_block(command),
        ),
        None => String::new(),
    };
    let is_pipe_filter = PIPE_FILTER_COMMANDS.contains(&command);
    let bin = real_bin.map_or_else(|| "\"$_CTO_REAL_BIN\"".to_string(), dq);
    let pipe_block = if is_pipe_filter {
        format!(
            "\n# Pipe-filter bypass: stdin is piped, so skip the optimizer.\nif [ ! -t 0 ]; then\n    exec {bin} \"$@\"\nfi\n"
        )
    } else {
        String::new()
    };
    let setup = match real_bin {
        Some(_) => String::new(),
        None => runtime_scan(command, paths),
    };
    format!(
        r#"#!/bin/bash
# CTO wrapper for {command}, generated by Chau7 Next

{setup}# Fast path: no active CTO session, exec the binary at once.
if {flag}; then
    exec {bin} "$@"
fi
{pipe_block}
# Command exclusion: skip the optimizer for commands in CHAU7_CTO_EXCLUDE.
case " $CHAU7_CTO_EXCLUDE " in *" {command} "*)
    exec {bin} "$@"
;; esac

# CTO is active: try the optimizer, fall through to the real binary.
{optimizer_block}
exec {bin} "$@"
"#,
        flag = flag_test(paths),
    )
}

/// `cat`: markdown files go to `chau7-md` (stdout is a terminal, no flags),
/// other files to `chau7-optim read` (`generateCatWrapperScript`).
fn cat_script(real_bin: Option<&str>, paths: &CtoPaths) -> String {
    let bin = real_bin.map_or_else(|| "\"$_CTO_REAL_BIN\"".to_string(), dq);
    let setup = match real_bin {
        Some(path) => format!("_CTO_REAL_BIN={}\n", dq(path)),
        None => runtime_scan("cat", paths),
    };
    format!(
        r#"#!/bin/bash
# CTO wrapper for cat, generated by Chau7 Next
# Renders markdown files with chau7-md, routes others through chau7-optim read.

{setup}
# Fast path: no active CTO session.
if {flag}; then
    exec {bin} "$@"
fi

# Command exclusion: skip the optimizer if cat is in the exclusion list.
case " $CHAU7_CTO_EXCLUDE " in *" cat "*)
    exec {bin} "$@"
;; esac

# Cat with no args may read from stdin (pipes): avoid the read optimizer.
if [ "$#" -eq 0 ]; then
    exec {bin} "$@"
fi

# Markdown: chau7-md when stdout is a terminal, no flags, all .md/.markdown.
_CHAU7_MD={md}

if [ -x "$_CHAU7_MD" ] && [ -t 1 ]; then
    _ALL_MD=true
    _HAS_FILES=false
    for _arg in "$@"; do
        case "$_arg" in
            -*)
                _ALL_MD=false
                break
                ;;
            *)
                _HAS_FILES=true
                _ext="${{_arg##*.}}"
                _ext_lower="$(printf '%s' "$_ext" | tr '[:upper:]' '[:lower:]')"
                case "$_ext_lower" in
                    md|markdown) ;;
                    *) _ALL_MD=false; break ;;
                esac
                ;;
        esac
    done

    if [ "$_HAS_FILES" = true ] && [ "$_ALL_MD" = true ]; then
        _CTO_EXIT=0
        for _arg in "$@"; do
            "$_CHAU7_MD" "$_arg"
            [ $? -ne 0 ] && _CTO_EXIT=1
        done
        exit $_CTO_EXIT
    fi
fi

# Other files: the optimizer.
_CHAU7_OPTIM={optim}
if [ -x "$_CHAU7_OPTIM" ]; then
    {env} "$_CHAU7_OPTIM" read "$@" 2>/dev/null
    _rc=$?
    {log}
fi

exec {bin} "$@"
"#,
        flag = flag_test(paths),
        md = dq(&paths.markdown_renderer().to_string_lossy()),
        optim = dq(&paths.optimizer().to_string_lossy()),
        env = optim_env(paths),
        log = log_block("cat"),
    )
}

/// `sed -n 'a,bp' file` and `sed -n 'np' file` (Codex's file read) become
/// `chau7-optim read file --start-line a --max-lines n`; everything else is
/// the real sed (`generateSedWrapperScript`).
fn sed_script(real_bin: Option<&str>, paths: &CtoPaths) -> String {
    let bin = real_bin.map_or_else(|| "\"$_CTO_REAL_BIN\"".to_string(), dq);
    let setup = match real_bin {
        Some(_) => String::new(),
        None => runtime_scan("sed", paths),
    };
    format!(
        r#"#!/bin/bash
# CTO wrapper for sed, generated by Chau7 Next
# Detects the file-read pattern: sed -n '<range>p' <file>
# and routes it through chau7-optim read.

{setup}# Fast path: no active CTO session.
if {flag}; then
    exec {bin} "$@"
fi

# Pipe-filter bypass: stdin is piped, so skip the optimizer.
if [ ! -t 0 ]; then
    exec {bin} "$@"
fi

# Command exclusion: skip the optimizer if sed is in the exclusion list.
case " $CHAU7_CTO_EXCLUDE " in *" sed "*)
    exec {bin} "$@"
;; esac

# Detect: sed -n '<start>,<end>p' <file>  or  sed -n '<line>p' <file>
if [ "$1" = "-n" ] && [ $# -eq 3 ]; then
    _RANGE="$2"
    _FILE="$3"
    case "$_RANGE" in
        *p)
            _RANGE_BODY="${{_RANGE%p}}"
            case "$_RANGE_BODY" in
                *,*)
                    _START="${{_RANGE_BODY%,*}}"
                    _END="${{_RANGE_BODY#*,}}"
                    ;;
                *)
                    _START="$_RANGE_BODY"
                    _END="$_RANGE_BODY"
                    ;;
            esac
            case "$_START" in ''|0|*[!0-9]*) _START="" ;; esac
            case "$_END" in ''|0|*[!0-9]*) _END="" ;; esac
            if [ -n "$_START" ] && [ -n "$_END" ] && [ -f "$_FILE" ]; then
                _COUNT=$(( _END - _START + 1 ))
                if [ $_COUNT -gt 0 ]; then
                    _CHAU7_OPTIM={optim}
                    if [ -x "$_CHAU7_OPTIM" ]; then
                        {env} "$_CHAU7_OPTIM" read "$_FILE" --start-line "$_START" --max-lines "$_COUNT" 2>/dev/null
                        _rc=$?
                        {log}
                    fi
                fi
            fi
            ;;
    esac
fi

# Everything else is the real sed.
exec {bin} "$@"
"#,
        flag = flag_test(paths),
        optim = dq(&paths.optimizer().to_string_lossy()),
        env = optim_env(paths),
        log = log_block("sed"),
    )
}

// ----- install and remove --------------------------------------------------------------

/// Creates the folders (`setup`, first part).
pub fn create_directories(paths: &CtoPaths) -> std::io::Result<()> {
    for dir in [
        &paths.wrapper_dir,
        &paths.bin_dir,
        &paths.data_dir,
        &paths.flag_dir,
    ] {
        fs::create_dir_all(dir)?;
    }
    Ok(())
}

/// Writes one wrapper script (chmod 755). `path_env` is the `PATH` the real
/// binary is looked up in. Returns the real binary found, if any.
pub fn install_wrapper(
    command: &str,
    paths: &CtoPaths,
    path_env: &str,
) -> std::io::Result<Option<String>> {
    let real = resolve_real_binary(
        command,
        path_env,
        &[&paths.wrapper_dir, &paths.swift_wrapper_dir],
    );
    let script = wrapper_script(command, real.as_deref(), paths);
    let target = paths.wrapper_dir.join(command);
    write_executable(&target, script.as_bytes())?;
    Ok(real)
}

/// Installs the wrapper of every supported command. Returns the commands
/// that failed.
pub fn install_all_wrappers(paths: &CtoPaths, path_env: &str) -> Vec<(String, String)> {
    let mut failed = Vec::new();
    for command in supported_commands() {
        if let Err(err) = install_wrapper(command, paths, path_env) {
            failed.push((command.to_string(), err.to_string()));
        }
    }
    failed
}

fn write_executable(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    // Write beside the target and rename, so a running wrapper never sees a
    // half written script.
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755))?;
    }
    fs::rename(&tmp, path)
}

/// Copies a helper binary into the bin folder (chmod 755), replacing the old
/// one (`installBinary`).
pub fn install_binary(paths: &CtoPaths, name: &str, source: &Path) -> std::io::Result<PathBuf> {
    fs::create_dir_all(&paths.bin_dir)?;
    let dest = paths.bin_dir.join(name);
    let bytes = fs::read(source)?;
    write_executable(&dest, &bytes)?;
    Ok(dest)
}

pub fn is_optimizer_installed(paths: &CtoPaths) -> bool {
    is_executable_file(&paths.optimizer())
}

pub fn is_markdown_renderer_installed(paths: &CtoPaths) -> bool {
    is_executable_file(&paths.markdown_renderer())
}

/// Removes every wrapper script (`teardown`, second part). Returns how many.
pub fn remove_all_wrappers(paths: &CtoPaths) -> usize {
    let Ok(entries) = fs::read_dir(&paths.wrapper_dir) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|e| fs::remove_file(e.path()).is_ok())
        .count()
}

// ----- health ----------------------------------------------------------------------------

/// Installation status of every wrapper (`checkInstallation`).
pub fn check_installation(paths: &CtoPaths) -> Vec<WrapperHealth> {
    supported_commands()
        .into_iter()
        .map(|command| {
            let path = paths.wrapper_dir.join(command);
            let exists = path.exists();
            WrapperHealth {
                command: command.to_string(),
                is_installed: exists,
                is_executable: exists && is_executable_file(&path),
                has_cto_route: cto_rewrite(command).is_some(),
            }
        })
        .collect()
}

/// Every wrapper installed and executable (`isFullyInstalled`).
pub fn is_fully_installed(health: &[WrapperHealth]) -> bool {
    !health.is_empty() && health.iter().all(|h| h.is_installed && h.is_executable)
}

/// Whether the wrapper of `command` is exec-only.
pub fn is_exec_only(command: &str) -> bool {
    EXEC_ONLY_COMMANDS.contains(&command)
}

// ----- flag files -------------------------------------------------------------------------

/// Creates the flag file of a session. True when it was created now.
pub fn create_flag(paths: &CtoPaths, session_id: &str) -> bool {
    if !is_safe_name(session_id) {
        return false;
    }
    let path = paths.flag_dir.join(session_id);
    if path.exists() {
        return false;
    }
    let _ = fs::create_dir_all(&paths.flag_dir);
    fs::File::create(path).is_ok()
}

/// Removes the flag file of a session. True when it existed.
pub fn remove_flag(paths: &CtoPaths, session_id: &str) -> bool {
    if !is_safe_name(session_id) {
        return false;
    }
    fs::remove_file(paths.flag_dir.join(session_id)).is_ok()
}

/// Removes every flag file. Returns how many.
pub fn remove_all_flags(paths: &CtoPaths) -> usize {
    let Ok(entries) = fs::read_dir(&paths.flag_dir) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|e| fs::remove_file(e.path()).is_ok())
        .count()
}

pub fn is_flag_active(paths: &CtoPaths, session_id: &str) -> bool {
    is_safe_name(session_id) && paths.flag_dir.join(session_id).exists()
}

/// Creates or removes the flag of a session from the decision matrix
/// (`CTOFlagManager.recalculate`).
pub fn recalculate_flag(
    paths: &CtoPaths,
    session_id: &str,
    mode: TokenOptimizationMode,
    override_mode: TabTokenOptOverride,
    is_ai_active: bool,
) -> CTOFlagDecision {
    let active = should_be_active(mode, override_mode, is_ai_active);
    let previous = is_flag_active(paths, session_id);
    if active {
        create_flag(paths, session_id);
    } else {
        remove_flag(paths, session_id);
    }
    // Failed disk mutations must not turn the desired state into observed evidence.
    let observed = is_flag_active(paths, session_id);
    CTOFlagDecision {
        previous_state: previous,
        next_state: observed,
        changed: previous != observed,
    }
}

/// A session id is one path component.
fn is_safe_name(name: &str) -> bool {
    !name.is_empty() && !name.contains(['/', '\\']) && name != "." && name != ".."
}

// ----- command log -------------------------------------------------------------------------

/// Parses one log line: `epoch|session|command|exit|outcome`.
pub fn parse_log_line(line: &str) -> Option<CtoLogEntry> {
    let mut parts = line.splitn(5, '|');
    let timestamp = parts.next()?.parse::<f64>().ok()?;
    let session_id = parts.next()?.to_string();
    let command = parts.next()?.to_string();
    let exit_code = parts.next()?.parse::<i64>().ok()?;
    let outcome = parts.next()?.to_string();
    Some(CtoLogEntry {
        timestamp,
        session_id,
        command,
        exit_code,
        outcome,
    })
}

/// The last `limit` entries of the command log, oldest first
/// (`readCommandLog`).
pub fn read_command_log(paths: &CtoPaths, limit: usize) -> Vec<CtoLogEntry> {
    let Ok(text) = fs::read_to_string(paths.command_log()) else {
        return Vec::new();
    };
    parse_log(&text, limit)
}

pub fn parse_log(text: &str, limit: usize) -> Vec<CtoLogEntry> {
    let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
    let start = lines.len().saturating_sub(limit);
    lines[start..]
        .iter()
        .filter_map(|l| parse_log_line(l))
        .collect()
}

/// Optimized share of the log, skipped commands excluded
/// (`commandSuccessRate`).
pub fn command_success_rate(entries: &[CtoLogEntry]) -> Option<f64> {
    let meaningful: Vec<&CtoLogEntry> = entries.iter().filter(|e| e.outcome != "skipped").collect();
    if meaningful.is_empty() {
        return None;
    }
    let optimized = meaningful
        .iter()
        .filter(|e| e.outcome == "optimized")
        .count();
    Some(optimized as f64 / meaningful.len() as f64 * 100.0)
}

/// Keeps the last 500 lines when the log is over 1 MB (`rotateCommandLogIfNeeded`).
/// Returns the old size when it rotated.
pub fn rotate_command_log(paths: &CtoPaths) -> Option<u64> {
    let path = paths.command_log();
    let size = fs::metadata(&path).ok()?.len();
    if size <= 1_048_576 {
        return None;
    }
    let text = fs::read_to_string(&path).ok()?;
    let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
    let start = lines.len().saturating_sub(500);
    let mut kept = lines[start..].join("\n");
    kept.push('\n');
    let mut file = fs::File::create(&path).ok()?;
    file.write_all(kept.as_bytes()).ok()?;
    Some(size)
}

// ----- gain statistics -----------------------------------------------------------------------

/// Daily token savings entry of `chau7-optim gain --daily --format json`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct DailyGainEntry {
    pub date: String,
    pub commands: i64,
    #[serde(rename = "input_tokens")]
    pub input_tokens: i64,
    #[serde(rename = "output_tokens")]
    pub output_tokens: i64,
    #[serde(rename = "saved_tokens")]
    pub saved_tokens: i64,
    #[serde(rename = "savings_pct")]
    pub savings_pct: f64,
}

/// Full answer of `chau7-optim gain --daily --format json`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct DailyGainResponse {
    pub summary: CTOGainStats,
    #[serde(default)]
    pub daily: Option<Vec<DailyGainEntry>>,
}

/// Parses the optimizer's gain output.
pub fn parse_gain(output: &[u8]) -> Option<DailyGainResponse> {
    serde_json::from_slice(output).ok()
}

/// Sums the daily entries on or after `cutoff` (`yyyy-MM-dd`, local day) into
/// one stats value (`aggregateDailyStats`).
pub fn aggregate_daily_stats(daily: &[DailyGainEntry], cutoff_day: &str) -> CTOGainStats {
    let filtered: Vec<&DailyGainEntry> = daily
        .iter()
        .filter(|e| e.date.as_str() >= cutoff_day)
        .collect();
    let input: i64 = filtered.iter().map(|e| e.input_tokens).sum();
    let saved: i64 = filtered.iter().map(|e| e.saved_tokens).sum();
    CTOGainStats {
        commands: filtered.iter().map(|e| e.commands).sum(),
        input_tokens: input,
        output_tokens: filtered.iter().map(|e| e.output_tokens).sum(),
        saved_tokens: saved,
        savings_pct: if input > 0 {
            saved as f64 / input as f64 * 100.0
        } else {
            0.0
        },
        total_time_ms: 0,
        avg_time_ms: 0,
    }
}

// ----- input prefix --------------------------------------------------------------------------

/// The command line with the CTO input prefix in front (`applyCTOPrefixIfNeeded`).
pub fn apply_input_prefix(line: &str, prefix: &str) -> String {
    let prefix = prefix.trim();
    if prefix.is_empty() || line.is_empty() || line.starts_with(prefix) {
        return line.to_string();
    }
    let needs_separator = !prefix.ends_with(' ') && !line.starts_with(' ');
    if needs_separator {
        format!("{prefix} {line}")
    } else {
        format!("{prefix}{line}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-cto-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn paths_in(dir: &Path) -> CtoPaths {
        let root = DataRoot::with_home(dir.to_path_buf(), true);
        CtoPaths::from_root(&root)
    }

    // Shell generation uses POSIX paths even when its pure tests run on Windows.
    fn posix_paths() -> CtoPaths {
        CtoPaths {
            wrapper_dir: PathBuf::from("/h/.chau7-next/cto_bin"),
            flag_dir: PathBuf::from("/h/.chau7-next/cto_active"),
            bin_dir: PathBuf::from("/h/.chau7-next/bin"),
            data_dir: PathBuf::from("/h/.chau7-next/cto_data"),
            swift_wrapper_dir: PathBuf::from("/swift/cto_bin"),
        }
    }

    #[test]
    fn failed_flag_mutation_reports_observed_not_desired_activation() {
        let home =
            std::env::temp_dir().join(format!("chau7-cto-failed-flag-{}", uuid::Uuid::new_v4()));
        let paths = CtoPaths::from_root(&DataRoot::with_home(home.clone(), true));
        std::fs::create_dir_all(paths.flag_dir.parent().unwrap()).unwrap();
        std::fs::write(&paths.flag_dir, b"not a directory").unwrap();
        let result = recalculate_flag(
            &paths,
            "S",
            TokenOptimizationMode::AllTabs,
            TabTokenOptOverride::Default,
            false,
        );
        assert!(!result.next_state);
        assert!(!result.changed);
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn paths_are_chau7_next_folders() {
        let root = DataRoot::with_home(PathBuf::from("/Users/me"), false);
        let paths = CtoPaths::from_root(&root);
        assert_eq!(
            paths.wrapper_dir,
            PathBuf::from("/Users/me/.chau7-next/cto_bin")
        );
        assert_eq!(
            paths.flag_dir,
            PathBuf::from("/Users/me/.chau7-next/cto_active")
        );
        assert_eq!(
            paths.command_log(),
            PathBuf::from("/Users/me/.chau7-next/cto_data/commands.log")
        );
        assert_eq!(
            paths.optimizer(),
            PathBuf::from("/Users/me/.chau7-next/bin/chau7-optim")
        );
        assert_ne!(paths.wrapper_dir, paths.swift_wrapper_dir);
    }

    #[test]
    fn prepended_path_adds_the_folder_once() {
        let root = DataRoot::with_home(PathBuf::from("/h"), false);
        let paths = CtoPaths::from_root(&root);
        let once = paths.prepended_path("/usr/bin:/bin");
        let wrapper = PathBuf::from("/h").join(".chau7-next").join("cto_bin");
        assert_eq!(once, format!("{}:/usr/bin:/bin", wrapper.display()));
        assert_eq!(paths.prepended_path(&once), once);
    }

    #[test]
    fn quoting_escapes_shell_characters() {
        assert_eq!(dq("/a b/$c"), "\"/a b/\\$c\"");
        assert_eq!(sq("it's"), "'it'\\''s'");
    }

    #[test]
    fn generic_script_routes_through_the_optimizer() {
        let paths = posix_paths();
        let script = wrapper_script("ls", Some("/bin/ls"), &paths);
        assert!(script.starts_with("#!/bin/bash"));
        assert!(script.contains("\"/h/.chau7-next/cto_active/$CHAU7_CTO_SESSION\""));
        assert!(script.contains("exec \"/bin/ls\" \"$@\""));
        assert!(script.contains("\"$_CHAU7_OPTIM\" ls \"$@\""));
        assert!(script.contains("CHAU7_CTO_BIN_DIR='/h/.chau7-next/cto_bin'"));
        let database = paths.data_dir.join("history.db");
        assert!(script.contains(&format!("RTK_DB_PATH={}", sq(&database.to_string_lossy()))));
        assert!(script.contains("|ls|$_rc|optimized"));
        assert!(!script.contains("[ ! -t 0 ]"));
    }

    #[test]
    fn exec_only_commands_have_no_optimizer_block() {
        let paths = paths_in(Path::new("/h"));
        for command in EXEC_ONLY_COMMANDS {
            let script = wrapper_script(command, Some("/usr/bin/x"), &paths);
            assert!(!script.contains("_CHAU7_OPTIM"), "{command}");
        }
    }

    #[test]
    fn pipe_filters_skip_the_optimizer_when_stdin_is_piped() {
        let paths = paths_in(Path::new("/h"));
        for command in ["grep", "rg", "diff"] {
            let script = wrapper_script(command, Some("/usr/bin/x"), &paths);
            assert!(script.contains("if [ ! -t 0 ]; then"), "{command}");
        }
        assert!(wrapper_script("sed", Some("/usr/bin/sed"), &paths).contains("[ ! -t 0 ]"));
        assert!(!wrapper_script("git", Some("/usr/bin/git"), &paths).contains("[ ! -t 0 ]"));
    }

    #[test]
    fn runtime_scan_skips_both_wrapper_folders() {
        let paths = posix_paths();
        let script = wrapper_script("git", None, &paths);
        assert!(script.contains("[ \"$_dir\" = \"/h/.chau7-next/cto_bin\" ] && continue"));
        let swift = format!(
            "[ \"$_dir\" = \"{}\" ] && continue",
            paths.swift_wrapper_dir.display()
        );
        assert!(script.contains(&swift));
        assert!(script.contains("could not find real git binary"));
        assert!(script.contains("exit 127"));
    }

    #[test]
    fn cat_script_renders_markdown_and_routes_reads() {
        let paths = posix_paths();
        let script = wrapper_script("cat", Some("/bin/cat"), &paths);
        let renderer = paths.bin_dir.join("chau7-md");
        assert!(script.contains(&format!("_CHAU7_MD={}", dq(&renderer.to_string_lossy()))));
        assert!(script.contains("\"$_CHAU7_OPTIM\" read \"$@\""));
        assert!(script.contains("[ \"$#\" -eq 0 ]"));
        assert!(script.contains("md|markdown"));
    }

    #[test]
    fn sed_script_converts_ranges_to_reads() {
        let paths = paths_in(Path::new("/h"));
        let script = wrapper_script("sed", Some("/usr/bin/sed"), &paths);
        assert!(script.contains("--start-line \"$_START\" --max-lines \"$_COUNT\""));
        assert!(script.contains("[ \"$1\" = \"-n\" ] && [ $# -eq 3 ]"));
    }

    #[test]
    fn install_creates_executable_wrappers_and_health_sees_them() {
        let dir = temp_dir("install");
        let paths = paths_in(&dir);
        create_directories(&paths).unwrap();
        let failed = install_all_wrappers(&paths, "/usr/bin:/bin");
        assert!(failed.is_empty(), "{failed:?}");
        let health = check_installation(&paths);
        assert_eq!(health.len(), supported_commands().len());
        assert!(is_fully_installed(&health));
        assert!(
            health
                .iter()
                .find(|h| h.command == "head")
                .is_some_and(|h| !h.has_cto_route)
        );
        assert!(
            health
                .iter()
                .find(|h| h.command == "git")
                .unwrap()
                .has_cto_route
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(paths.wrapper_dir.join("git"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o755);
            // A wrapper that lost its execute bit is reported.
            fs::set_permissions(
                paths.wrapper_dir.join("git"),
                fs::Permissions::from_mode(0o644),
            )
            .unwrap();
            let health = check_installation(&paths);
            let git = health.iter().find(|h| h.command == "git").unwrap();
            assert!(git.is_installed && !git.is_executable);
            assert!(!is_fully_installed(&health));
        }
        fs::remove_file(paths.wrapper_dir.join("ls")).unwrap();
        let health = check_installation(&paths);
        assert!(
            !health
                .iter()
                .find(|h| h.command == "ls")
                .unwrap()
                .is_installed
        );
        assert!(remove_all_wrappers(&paths) > 0);
        assert!(check_installation(&paths).iter().all(|h| !h.is_installed));
        let _ = fs::remove_dir_all(dir);
    }

    // The resolver consumes a POSIX PATH and executable shell files.
    #[cfg(unix)]
    #[test]
    fn real_binary_lookup_skips_wrapper_folders() {
        let dir = temp_dir("resolve");
        let wrapper = dir.join("wrap");
        let real = dir.join("real");
        fs::create_dir_all(&wrapper).unwrap();
        fs::create_dir_all(&real).unwrap();
        for d in [&wrapper, &real] {
            write_executable(&d.join("tool"), b"#!/bin/sh\n").unwrap();
        }
        let path = format!("{}:{}", wrapper.display(), real.display());
        let found = resolve_real_binary("tool", &path, &[&wrapper]).unwrap();
        assert_eq!(found, real.join("tool").to_string_lossy());
        assert!(resolve_real_binary("tool", &path, &[&wrapper, &real]).is_none());
        assert!(resolve_real_binary("nothing", &path, &[]).is_none());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn flag_files_are_created_and_removed() {
        let dir = temp_dir("flags");
        let paths = paths_in(&dir);
        create_directories(&paths).unwrap();
        assert!(!is_flag_active(&paths, "S1"));
        assert!(create_flag(&paths, "S1"));
        assert!(!create_flag(&paths, "S1"));
        assert!(is_flag_active(&paths, "S1"));
        assert!(create_flag(&paths, "S2"));
        assert!(remove_flag(&paths, "S1"));
        assert!(!remove_flag(&paths, "S1"));
        assert_eq!(remove_all_flags(&paths), 1);
        assert!(!create_flag(&paths, "../escape"));
        assert!(!create_flag(&paths, ""));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn recalculating_creates_and_removes_the_flag() {
        use TabTokenOptOverride as O;
        use TokenOptimizationMode as M;
        let dir = temp_dir("recalc");
        let paths = paths_in(&dir);
        create_directories(&paths).unwrap();
        let on = recalculate_flag(&paths, "S", M::AllTabs, O::Default, false);
        assert!(!on.previous_state && on.next_state && on.changed);
        assert!(is_flag_active(&paths, "S"));
        let same = recalculate_flag(&paths, "S", M::AllTabs, O::Default, false);
        assert!(same.previous_state && same.next_state && !same.changed);
        let off = recalculate_flag(&paths, "S", M::AllTabs, O::ForceOff, false);
        assert!(off.previous_state && !off.next_state && off.changed);
        let ai = recalculate_flag(&paths, "S", M::AiOnly, O::Default, true);
        assert!(ai.next_state && ai.changed);
        let gone = recalculate_flag(&paths, "S", M::Off, O::ForceOn, true);
        assert!(!gone.next_state && gone.changed);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn log_lines_parse_and_the_rate_skips_skipped_commands() {
        let text = "1700000000|S1|git|0|optimized\n\
                    1700000001|S1|cat|2|fallthrough\n\
                    1700000002|S1|grep|3|skipped\n\
                    bad line\n\
                    1700000003|S2|ls|1|optimized\n";
        let entries = parse_log(text, 5000);
        assert_eq!(entries.len(), 4);
        assert_eq!(entries[0].command, "git");
        assert_eq!(entries[3].session_id, "S2");
        assert!(entries[2].is_intentional_skip());
        let rate = command_success_rate(&entries).unwrap();
        assert!((rate - 66.666).abs() < 0.01);
        assert_eq!(
            parse_log(text, 2).len(),
            1,
            "the last two lines hold one valid entry"
        );
        assert!(command_success_rate(&[]).is_none());
    }

    #[test]
    fn the_log_is_trimmed_when_over_one_megabyte() {
        let dir = temp_dir("rotate");
        let paths = paths_in(&dir);
        create_directories(&paths).unwrap();
        assert!(rotate_command_log(&paths).is_none());
        let line = "1700000000|S1|git|0|optimized\n";
        fs::write(paths.command_log(), line.repeat(40_000)).unwrap();
        let old = rotate_command_log(&paths).unwrap();
        assert!(old > 1_048_576);
        let text = fs::read_to_string(paths.command_log()).unwrap();
        assert_eq!(text.lines().count(), 500);
        assert!(rotate_command_log(&paths).is_none());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn gain_output_parses_and_aggregates_by_day() {
        let json = br#"{
            "summary": {"total_commands": 3, "total_input": 1000, "total_output": 400,
                        "total_saved": 600, "avg_savings_pct": 60.0,
                        "total_time_ms": 30, "avg_time_ms": 10},
            "daily": [
                {"date": "2026-10-08", "commands": 1, "input_tokens": 100, "output_tokens": 50, "saved_tokens": 50, "savings_pct": 50.0},
                {"date": "2026-10-09", "commands": 2, "input_tokens": 900, "output_tokens": 350, "saved_tokens": 550, "savings_pct": 61.0}
            ]}"#;
        let response = parse_gain(json).unwrap();
        assert_eq!(response.summary.commands, 3);
        let daily = response.daily.unwrap();
        let all = aggregate_daily_stats(&daily, "2026-10-01");
        assert_eq!((all.commands, all.saved_tokens), (3, 600));
        assert!((all.savings_pct - 60.0).abs() < 1e-9);
        let recent = aggregate_daily_stats(&daily, "2026-10-09");
        assert_eq!((recent.commands, recent.input_tokens), (2, 900));
        assert_eq!(aggregate_daily_stats(&daily, "2027-01-01").savings_pct, 0.0);
        assert!(parse_gain(b"not json").is_none());
        // `daily` is optional (a plain `gain --format json`).
        let plain = br#"{"summary": {"total_commands": 0, "total_input": 0, "total_output": 0, "total_saved": 0, "avg_savings_pct": 0.0, "total_time_ms": 0, "avg_time_ms": 0}}"#;
        assert!(parse_gain(plain).unwrap().daily.is_none());
    }

    #[test]
    fn input_prefix_matches_swift() {
        assert_eq!(apply_input_prefix("ls", "/think"), "/think ls");
        assert_eq!(apply_input_prefix("ls", "/think "), "/think ls");
        assert_eq!(apply_input_prefix(" ls", "/think"), "/think ls");
        assert_eq!(apply_input_prefix("/think ls", "/think"), "/think ls");
        assert_eq!(apply_input_prefix("", "/think"), "");
        assert_eq!(apply_input_prefix("ls", "  "), "ls");
    }

    #[cfg(unix)]
    mod run {
        use super::*;
        use std::process::Command;

        /// A fake optimizer prints its arguments and exits with `$FAKE_RC`.
        fn setup(name: &str) -> (PathBuf, CtoPaths, PathBuf) {
            let dir = temp_dir(name);
            let paths = paths_in(&dir);
            create_directories(&paths).unwrap();
            let real_dir = dir.join("realbin");
            fs::create_dir_all(&real_dir).unwrap();
            write_executable(&real_dir.join("git"), b"#!/bin/sh\necho real-git \"$@\"\n").unwrap();
            write_executable(
                &paths.optimizer(),
                b"#!/bin/sh\necho optim \"$@\" bin=$CHAU7_CTO_BIN_DIR\nexit ${FAKE_RC:-0}\n",
            )
            .unwrap();
            let path = format!("{}:/usr/bin:/bin", real_dir.display());
            install_wrapper("git", &paths, &path).unwrap();
            (dir, paths, real_dir)
        }

        fn run(paths: &CtoPaths, dir: &Path, session: Option<&str>, rc: &str) -> (String, String) {
            let log = paths.command_log();
            let mut cmd = Command::new(paths.wrapper_dir.join("git"));
            cmd.arg("status")
                .env_clear()
                .env("PATH", "/usr/bin:/bin")
                .env("FAKE_RC", rc)
                .env("CHAU7_CTO_LOG", &log)
                .current_dir(dir);
            if let Some(session) = session {
                cmd.env("CHAU7_CTO_SESSION", session);
            }
            let out = cmd.output().unwrap();
            (
                String::from_utf8_lossy(&out.stdout).trim().to_string(),
                fs::read_to_string(&log).unwrap_or_default(),
            )
        }

        #[test]
        fn optimizer_recursion_sentinel_bypasses_every_wrapper() {
            let (dir, paths, real_dir) = setup("run-sentinel");
            create_flag(&paths, "S1");
            for command in ["git", "cat", "sed"] {
                // Forks from parallel tests may temporarily inherit a newly
                // written script's descriptor on Linux. This fixture tests the
                // generated wrapper's bypass, using a stable real executable.
                let real = real_dir.join(command);
                if real.exists() {
                    fs::remove_file(&real).unwrap();
                }
                std::os::unix::fs::symlink("/bin/echo", &real).unwrap();
                let path = format!("{}:/usr/bin:/bin", real_dir.display());
                install_wrapper(command, &paths, &path).unwrap();
                // The generated source is still executed by its actual Bash
                // interpreter. Wrapper execute permissions are tested above.
                let out = Command::new("/bin/bash")
                    .arg(paths.wrapper_dir.join(command))
                    .args(["real", "file.md"])
                    .env_clear()
                    .env("PATH", path)
                    .env("CHAU7_CTO_SESSION", "S1")
                    .env("CHAU7_CTO_OPTIM_ACTIVE", "1")
                    .env("CHAU7_CTO_LOG", paths.command_log())
                    .output()
                    .unwrap();
                assert!(
                    out.status.success(),
                    "{command}: status={} stdout={:?} stderr={:?}",
                    out.status,
                    String::from_utf8_lossy(&out.stdout),
                    String::from_utf8_lossy(&out.stderr)
                );
                assert_eq!(
                    String::from_utf8_lossy(&out.stdout).trim(),
                    "real file.md",
                    "{command}"
                );
            }
            assert!(!paths.command_log().exists());
            let _ = fs::remove_dir_all(dir);
        }

        #[test]
        fn wrapper_runs_the_real_binary_without_a_flag() {
            let (dir, paths, _) = setup("run-noflag");
            let (out, log) = run(&paths, &dir, Some("S1"), "0");
            assert_eq!(out, "real-git status");
            assert!(log.is_empty());
            let (out, _) = run(&paths, &dir, None, "0");
            assert_eq!(out, "real-git status");
            let _ = fs::remove_dir_all(dir);
        }

        #[test]
        fn wrapper_uses_the_optimizer_with_a_flag_and_logs() {
            let (dir, paths, _) = setup("run-flag");
            assert!(create_flag(&paths, "S1"));
            let (out, log) = run(&paths, &dir, Some("S1"), "0");
            assert!(out.starts_with("optim git status bin="), "{out}");
            assert!(out.ends_with(&paths.wrapper_dir.to_string_lossy().to_string()));
            let entries = parse_log(&log, 10);
            assert_eq!(entries.len(), 1);
            assert_eq!(entries[0].outcome, "optimized");
            assert_eq!(entries[0].command, "git");
            // Any other exit code is the result and is logged as optimized.
            let (out, log) = run(&paths, &dir, Some("S1"), "1");
            assert!(out.starts_with("optim"));
            assert_eq!(parse_log(&log, 10).len(), 2);
            let _ = fs::remove_dir_all(dir);
        }

        #[test]
        fn exit_two_and_three_fall_through_to_the_real_binary() {
            let (dir, paths, _) = setup("run-fall");
            create_flag(&paths, "S1");
            let (out, log) = run(&paths, &dir, Some("S1"), "2");
            assert!(out.contains("real-git status"), "{out}");
            assert_eq!(parse_log(&log, 10)[0].outcome, "fallthrough");
            let (_, log) = run(&paths, &dir, Some("S1"), "3");
            assert_eq!(parse_log(&log, 10)[1].outcome, "skipped");
            let _ = fs::remove_dir_all(dir);
        }

        #[test]
        fn excluded_commands_skip_the_optimizer() {
            let (dir, paths, _) = setup("run-exclude");
            create_flag(&paths, "S1");
            let out = Command::new(paths.wrapper_dir.join("git"))
                .arg("status")
                .env_clear()
                .env("PATH", "/usr/bin:/bin")
                .env("CHAU7_CTO_SESSION", "S1")
                .env("CHAU7_CTO_EXCLUDE", "ls git")
                .output()
                .unwrap();
            assert_eq!(
                String::from_utf8_lossy(&out.stdout).trim(),
                "real-git status"
            );
            let _ = fs::remove_dir_all(dir);
        }

        #[test]
        fn sed_range_reads_go_to_the_optimizer() {
            let dir = temp_dir("run-sed");
            let paths = paths_in(&dir);
            create_directories(&paths).unwrap();
            write_executable(&paths.optimizer(), b"#!/bin/sh\necho optim \"$@\"\n").unwrap();
            install_wrapper("sed", &paths, "/usr/bin:/bin").unwrap();
            create_flag(&paths, "S1");
            let file = dir.join("f.txt");
            fs::write(&file, "a\nb\nc\nd\n").unwrap();
            let sed = |args: &[&str]| {
                // stdin must be a terminal for the optimizer path, which a
                // test cannot provide: only the bypass is checked here.
                let out = Command::new(paths.wrapper_dir.join("sed"))
                    .args(args)
                    .env_clear()
                    .env("PATH", "/usr/bin:/bin")
                    .env("CHAU7_CTO_SESSION", "S1")
                    .stdin(std::process::Stdio::null())
                    .output()
                    .unwrap();
                String::from_utf8_lossy(&out.stdout).to_string()
            };
            let file = file.to_string_lossy().to_string();
            assert_eq!(sed(&["-n", "2,3p", &file]), "b\nc\n");
            let _ = fs::remove_dir_all(dir);
        }
    }
}
