//! Token optimization (CTO): the wrapper folder, the per-session flag files,
//! the runtime monitor, the optimizer install and the savings statistics.
//!
//! Port of `CTOManager`, `CTOFlagManager` and `CTORuntimeMonitor`
//! (`TokenOptimization/`). The pure parts live in
//! `chau7_next_core::{token_optimization, cto_wrappers, cto_monitor}`; this
//! module owns the state and talks to the disk and to the optimizer process.
//!
//! The manager is a process-wide singleton behind a mutex, as in Swift
//! (`CTOManager.shared`), because terminal sessions report to it from
//! `Drop` and from places without an `App` context. The mode itself is a
//! setting (`Settings::cto`); [`settings_applied`] follows its changes.
//!
//! Chau7 Next uses its own wrapper folder (`DataRoot::cto_bin_dir`) and tells
//! the optimizer about it with `CHAU7_CTO_BIN_DIR`, so the Swift app and
//! Chau7 Next can run side by side: neither strips, writes or reads the
//! other's wrappers, flags, command log or savings database.

pub mod debug_source;
mod state_file;

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::Instant;

use chau7_next_core::cto_monitor::{CtoMonitor, Decision};
use chau7_next_core::cto_wrappers::{
    self as wrappers, CTO_BIN_DIR_ENV, CtoPaths, DailyGainResponse, OPTIMIZER_DB_ENV,
};
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::debug_console::CtoLogEntry;
use chau7_next_core::shell_env;
use chau7_next_core::token_optimization::{
    CTODecisionEvent, CTODecisionTrigger, CTOGainStats, CTORuntimeSnapshot, TabTokenOptOverride,
    TokenOptimizationMode, WrapperHealth, decision_reason,
};
use gpui::App;
use parking_lot::Mutex;

use crate::logging::log_cat;
use crate::settings::Settings;

/// Savings of the optimizer, as last fetched (the process runs in the
/// background, the screens read this).
#[derive(Debug, Clone, Default)]
pub struct GainCache {
    /// `gain --daily --format json`.
    pub response: Option<DailyGainResponse>,
    /// `gain --session-id <id> --format json` per session.
    pub sessions: HashMap<String, CTOGainStats>,
    /// A fetch is running.
    pub loading: bool,
    /// At least one fetch finished.
    pub loaded: bool,
}

#[derive(Debug)]
struct SessionCto {
    override_mode: TabTokenOptOverride,
    ai_active: bool,
    /// Flag creation waits for the first prompt, so shell init scripts (NVM,
    /// compinit) are never slowed by the optimizer.
    deferred: bool,
    deferred_at: Option<Instant>,
}

struct Manager {
    paths: CtoPaths,
    mode: TokenOptimizationMode,
    monitor: CtoMonitor,
    sessions: HashMap<String, SessionCto>,
    gain: GainCache,
    state_writer: Option<state_file::StateWriter>,
    shutting_down: bool,
}

static MANAGER: OnceLock<Mutex<Manager>> = OnceLock::new();

fn manager() -> Option<&'static Mutex<Manager>> {
    MANAGER.get()
}

fn with<R>(f: impl FnOnce(&mut Manager) -> R) -> Option<R> {
    manager().map(|m| f(&mut m.lock()))
}

fn mirror_locked(m: &mut Manager) {
    let Some(writer) = m.state_writer.as_ref() else {
        return;
    };
    if m.mode == TokenOptimizationMode::Off {
        writer.remove();
        return;
    }
    let mut overrides: Vec<_> = m
        .sessions
        .iter()
        .map(
            |(id, s)| chau7_next_core::cto_monitor::state::SessionOverrideInfo {
                session_id: id.clone(),
                override_mode: s.override_mode,
                is_ai_active: s.ai_active,
                active: wrappers::is_flag_active(&m.paths, id),
                deferred: s.deferred,
            },
        )
        .collect();
    overrides.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    writer.write(m.monitor.diagnostic_state(overrides, false));
}

/// Quit caller joins this worker on its existing background shutdown future.
pub fn shutdown_state_writer() -> Option<std::thread::JoinHandle<()>> {
    with(|m| {
        m.shutting_down = true;
        m.state_writer
            .take()
            .and_then(state_file::StateWriter::shutdown)
    })
    .flatten()
}

// ----- start ---------------------------------------------------------------------------------

/// Start the optimizer support at launch (`AppDelegate`: setup when the mode
/// is not off) and register its Debug Console source.
pub fn init(root: &DataRoot, settings: &Settings, cx: &mut App) {
    let paths = CtoPaths::from_root(root);
    let mode = settings.cto.mode;
    let mut monitor = CtoMonitor::new();
    monitor.set_initial_mode(mode);
    let state_writer =
        state_file::StateWriter::start(paths.clone(), crate::observability::timer_registry(cx));
    let _ = MANAGER.set(Mutex::new(Manager {
        paths,
        mode,
        monitor,
        sessions: HashMap::new(),
        gain: GainCache::default(),
        state_writer,
        shutting_down: false,
    }));
    if mode != TokenOptimizationMode::Off {
        setup(root);
        log::info!("CTO wrapper scripts installed");
        refresh_gain(cx);
    }
    if mode == TokenOptimizationMode::Off {
        with(mirror_locked);
    }
    // The actual gain poll is five minutes; health summaries are every thirty.
    let timer = crate::observability::register_timer(
        cx,
        "cto.gain_poll",
        "CTO gain refresh and health summary",
        "cto",
        300_000,
    );
    cx.spawn(async move |cx| {
        let _timer = timer;
        let mut ticks = 0u32;
        loop {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(300))
                .await;
            let alive = cx.update(|cx| {
                if with(|m| !m.shutting_down) != Some(true) {
                    return false;
                }
                if self::mode() != TokenOptimizationMode::Off {
                    refresh_gain(cx);
                    ticks += 1;
                    if ticks.is_multiple_of(6) {
                        with(emit_summary_locked);
                    }
                }
                true
            });
            if !alive {
                break;
            }
        }
    })
    .detach();
    debug_source::register(cx);
}

/// The paths of the optimizer files, once started.
pub fn paths() -> Option<CtoPaths> {
    with(|m| m.paths.clone())
}

/// The mode the manager works with (follows the settings).
pub fn mode() -> TokenOptimizationMode {
    with(|m| m.mode).unwrap_or_default()
}

// ----- setup and teardown --------------------------------------------------------------------

/// Where the real binaries are looked up: the path shells get.
fn lookup_path(root: &DataRoot) -> String {
    let home = root.home().to_string_lossy().to_string();
    shell_env::preferred_path(Some(&home), std::env::var("PATH").ok().as_deref())
}

/// Folders, wrapper scripts, bundled helper binaries, log rotation
/// (`CTOManager.setup`).
pub fn setup(root: &DataRoot) {
    let Some((paths, summary)) = with(|m| {
        let mode = m.mode;
        let summary = m.monitor.record_manager_setup(Some(mode));
        (m.paths.clone(), summary)
    }) else {
        return;
    };
    log_cat!(
        CTO,
        Info,
        "CTO manager setup observed mode={}",
        mode().raw_value()
    );
    if summary {
        with(emit_summary_locked);
    }
    if let Err(err) = wrappers::create_directories(&paths) {
        log::error!("CTOManager: cannot create folders: {err}");
    }
    let path_env = lookup_path(root);
    for (command, err) in wrappers::install_all_wrappers(&paths, &path_env) {
        log::error!("CTOManager: failed to install wrapper for {command}: {err}");
    }
    // The helper binaries ship next to the app binary.
    if let Some(dir) = bundled_helper_dir() {
        for name in ["chau7-md", "chau7-optim"] {
            let source = dir.join(name);
            if source.is_file() {
                install_helper(&paths, name, &source);
            }
        }
    }
    with(mirror_locked);
    if let Some(old) = wrappers::rotate_command_log(&paths) {
        log::info!("CTOManager: rotated command log (was {old} bytes)");
    }
}

/// Where the bundle keeps `chau7-optim` and `chau7-md`: next to the app
/// binary (`Contents/MacOS`).
pub fn bundled_helper_dir() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(PathBuf::from))
}

fn install_helper(paths: &CtoPaths, name: &str, source: &std::path::Path) -> bool {
    match wrappers::install_binary(paths, name, source) {
        Ok(dest) => {
            log::info!("CTOManager: installed {name} to {}", dest.display());
            true
        }
        Err(err) => {
            log::error!("CTOManager: failed to install {name}: {err}");
            false
        }
    }
}

/// "Reinstall from Bundle": copies `chau7-optim` (and `chau7-md`) from the
/// app bundle again. False when the bundle has no optimizer.
pub fn reinstall_optimizer() -> bool {
    let (Some(paths), Some(dir)) = (paths(), bundled_helper_dir()) else {
        return false;
    };
    let source = dir.join("chau7-optim");
    if !source.is_file() {
        log::warn!("CTO: no bundled optimizer at {}", source.display());
        return false;
    }
    let ok = install_helper(&paths, "chau7-optim", &source);
    let md = dir.join("chau7-md");
    if md.is_file() {
        install_helper(&paths, "chau7-md", &md);
    }
    ok
}

/// Removes every wrapper and flag file (`CTOManager.teardown`), on quit and
/// when the mode becomes off.
pub fn teardown() {
    let Some(paths) = with(|m| {
        m.monitor.record_manager_teardown();
        if let Some(writer) = &m.state_writer {
            writer.remove();
        }
        m.paths.clone()
    }) else {
        return;
    };
    let removed = wrappers::remove_all_flags(&paths);
    with(|m| m.monitor.record_manager_bulk_remove(removed as i64));
    if removed > 0 {
        log_cat!(
            CTO,
            Info,
            "CTO bulk flag cleanup removed={removed} scope=teardown/all"
        );
    }
    let wrappers_removed = wrappers::remove_all_wrappers(&paths);
    log::info!("CTOManager: removed {wrappers_removed} wrapper script(s)");
}

// ----- environment of a shell -------------------------------------------------------------------

/// The `PATH` and the variables a new shell gets when the mode is not off
/// (`launchPATHValue`, `buildEnvironment`). `path` is the shell's `PATH`
/// before the wrapper folder is put in front.
pub fn shell_environment(paths: &CtoPaths, path: &str, session_id: &str) -> Vec<(String, String)> {
    vec![
        ("PATH".into(), paths.prepended_path(path)),
        ("CHAU7_CTO_SESSION".into(), session_id.to_string()),
        (
            "CHAU7_CTO_LOG".into(),
            paths.command_log().to_string_lossy().to_string(),
        ),
        (CTO_BIN_DIR_ENV.into(), paths.bin_dir_env_value()),
        (
            OPTIMIZER_DB_ENV.into(),
            paths.gain_database().to_string_lossy().to_string(),
        ),
    ]
}

// ----- sessions ---------------------------------------------------------------------------------

/// A terminal session started. With the mode on, its flag waits for the
/// first prompt (`markCTOFlagDeferred`).
pub fn register_session(id: &str, override_mode: TabTokenOptOverride) {
    with(|m| register_session_locked(m, id, override_mode));
}

fn register_session_locked(m: &mut Manager, id: &str, override_mode: TabTokenOptOverride) {
    let deferred = m.mode != TokenOptimizationMode::Off;
    m.sessions.insert(
        id.to_string(),
        SessionCto {
            override_mode,
            ai_active: false,
            deferred,
            deferred_at: deferred.then(Instant::now),
        },
    );
    if deferred {
        let pending = m.monitor.record_deferred_set(id);
        log_cat!(
            CTO,
            Trace,
            "CTO deferred set session={id} mode={} pendingDeferred={pending}",
            m.mode.raw_value()
        );
    }
    mirror_locked(m);
}

/// A session closed: its flag goes away (also the last-tab replace path).
pub fn unregister_session(id: &str) {
    with(|m| unregister_session_locked(m, id));
}

fn unregister_session_locked(m: &mut Manager, id: &str) {
    if let Some(session) = m.sessions.remove(id)
        && session.deferred
    {
        let event = m.monitor.record_deferred_cancel(
            id,
            "session_closed_before_flush",
            m.mode,
            session.override_mode,
            session.ai_active,
        );
        log_event(&event);
    }
    wrappers::remove_flag(&m.paths, id);
    if m.monitor.untrack_session(id) {
        log_cat!(CTO, Trace, "CTO session untracked session={id}");
    }
    mirror_locked(m);
}

/// The shell showed its first prompt: create the deferred flag
/// (`createDeferredCTOFlag`).
pub fn prompt_detected(id: &str) {
    with(|m| prompt_detected_locked(m, id));
}

fn prompt_detected_locked(m: &mut Manager, id: &str) {
    let Some(session) = m.sessions.get_mut(id) else {
        return;
    };
    if !session.deferred {
        return;
    }
    session.deferred = false;
    let delay_ms = session
        .deferred_at
        .take()
        .map_or(0, |t| t.elapsed().as_millis() as i64);
    let (override_mode, ai) = (session.override_mode, session.ai_active);
    let mode = m.mode;
    if mode == TokenOptimizationMode::Off {
        let event = m
            .monitor
            .record_deferred_skip(id, "mode-off", mode, override_mode, ai);
        log_event(&event);
        mirror_locked(m);
        return;
    }
    let flag = wrappers::recalculate_flag(&m.paths, id, mode, override_mode, ai);
    if flag.next_state
        != chau7_next_core::token_optimization::should_be_active(mode, override_mode, ai)
    {
        log_cat!(
            CTO,
            Warn,
            "CTO flag mutation failed session={id} mode={} override={} observedActive={}",
            mode.raw_value(),
            override_mode.raw_value(),
            flag.next_state
        );
    }
    let reason = decision_reason(mode, override_mode, ai);
    let event = m.monitor.record_deferred_flush(
        id,
        delay_ms,
        Decision {
            mode,
            override_mode,
            is_ai_active: ai,
            previous_state: flag.previous_state,
            next_state: flag.next_state,
            changed: flag.changed,
            reason,
        },
        None,
    );
    log_event(&event);
    log_cat!(
        CTO,
        Trace,
        "CTO deferred flush session={id} delayMs={delay_ms}"
    );
    mirror_locked(m);
}

/// Correlate the wrapper session with the observed live agent and tool identity.
pub fn set_session_state(
    id: &str,
    active: bool,
    provider: Option<String>,
    tool_session_id: Option<String>,
) {
    with(|m| set_session_state_locked(m, id, active, provider, tool_session_id));
}

fn set_session_state_locked(
    m: &mut Manager,
    id: &str,
    active: bool,
    provider: Option<String>,
    tool_session_id: Option<String>,
) {
    let active_changed = if let Some(session) = m.sessions.get_mut(id) {
        let changed = session.ai_active != active;
        session.ai_active = active;
        changed
    } else {
        return;
    };
    let identity_changed = m
        .monitor
        .record_tool_session_identity(id, provider, tool_session_id);
    if active_changed {
        recalculate_locked(m, id);
    }
    if identity_changed || active_changed {
        mirror_locked(m);
    }
}

/// The tab's override changed. `recalculate` is false when a saved override
/// comes back at restore (the flag is created at the first prompt).
pub fn set_override(id: &str, value: TabTokenOptOverride, recalculate: bool) {
    with(|m| {
        if let Some(session) = m.sessions.get_mut(id) {
            session.override_mode = value;
        }
        if recalculate {
            recalculate_session_locked(m, id, CTODecisionTrigger::OverrideChanged);
            log::info!(
                "CTO toggle: session {id} override changed to {}",
                value.raw_value()
            );
        }
        mirror_locked(m);
    });
}

/// `recalculateCTOFlag()`: skipped while the mode is off or the session
/// waits for its first prompt.
fn recalculate_locked(m: &mut Manager, id: &str) {
    if m.mode == TokenOptimizationMode::Off {
        return;
    }
    if m.sessions.get(id).is_none_or(|s| s.deferred) {
        return;
    }
    recalculate_session_locked(m, id, CTODecisionTrigger::AiStateChanged);
}

/// Recalculate one session's flag and record the decision.
fn recalculate_session_locked(m: &mut Manager, id: &str, trigger: CTODecisionTrigger) {
    let mode = m.mode;
    if mode == TokenOptimizationMode::Off {
        return;
    }
    let Some(session) = m.sessions.get(id) else {
        return;
    };
    let (override_mode, ai) = (session.override_mode, session.ai_active);
    let flag = wrappers::recalculate_flag(&m.paths, id, mode, override_mode, ai);
    if flag.next_state
        != chau7_next_core::token_optimization::should_be_active(mode, override_mode, ai)
    {
        log_cat!(
            CTO,
            Warn,
            "CTO flag mutation failed session={id} mode={} override={} observedActive={}",
            mode.raw_value(),
            override_mode.raw_value(),
            flag.next_state
        );
    }
    let (event, summary) = m.monitor.record_decision_with_trigger(
        id,
        Decision {
            mode,
            override_mode,
            is_ai_active: ai,
            previous_state: flag.previous_state,
            next_state: flag.next_state,
            changed: flag.changed,
            reason: decision_reason(mode, override_mode, ai),
        },
        Some(trigger),
        None,
        None,
    );
    log_event(&event);
    if flag.changed {
        mirror_locked(m);
    }
    if summary {
        emit_summary_locked(m);
    }
}

/// The mode changed (`tokenOptimizationModeChanged`): recalculate every
/// session, then install the wrappers (on) or remove everything (off).
fn mode_changed(new: TokenOptimizationMode, root: &DataRoot) {
    let Some(previous) = with(|m| {
        let previous = m.mode;
        if previous == new {
            return None;
        }
        if m.monitor.record_mode_changed(previous, new) {
            log_cat!(
                CTO,
                Info,
                "CTO mode changed previousMode={} currentMode={} modeChanges={}",
                previous.raw_value(),
                new.raw_value(),
                m.monitor.snapshot().mode_change_count
            );
        }
        m.mode = new;
        recalculate_all_locked(m);
        Some(previous)
    })
    .flatten() else {
        return;
    };
    if new == TokenOptimizationMode::Off {
        teardown();
    } else {
        setup(root);
        if previous == TokenOptimizationMode::Off {
            log::info!("CTO wrapper scripts installed");
        }
    }
}

/// `recalculateAllCTOFlags`: every session that is past its first prompt.
fn recalculate_all_locked(m: &mut Manager) {
    let mode = m.mode;
    if mode == TokenOptimizationMode::Off {
        let removed = wrappers::remove_all_flags(&m.paths);
        m.monitor.record_manager_bulk_remove(removed as i64);
        return;
    }
    let ids: Vec<String> = m.sessions.keys().cloned().collect();
    for id in ids {
        let session = &m.sessions[&id];
        if session.deferred {
            let (o, ai) = (session.override_mode, session.ai_active);
            let event = m.monitor.record_deferred_cancel(
                &id,
                "mode-change-before-first-prompt",
                mode,
                o,
                ai,
            );
            log_event(&event);
            continue;
        }
        recalculate_session_locked(m, &id, CTODecisionTrigger::ModeChanged);
    }
}

/// Called after the settings changed (`config_files::apply`): follows the
/// mode.
pub fn settings_applied(cx: &mut App) {
    let new = Settings::get(cx).cto.mode;
    if manager().is_none() || new == mode() {
        return;
    }
    let root = cx.global::<crate::workspace::AppData>().root.clone();
    mode_changed(new, &root);
    if new != TokenOptimizationMode::Off {
        refresh_gain(cx);
    }
    cx.refresh_windows();
}

// ----- monitor ------------------------------------------------------------------------------------

fn log_event(event: &CTODecisionEvent) {
    let note = event
        .debug_note
        .as_deref()
        .map(|n| format!(" note={n}"))
        .unwrap_or_default();
    let delay = event
        .delay_to_activate_ms
        .map(|d| format!(" delayMs={d}"))
        .unwrap_or_default();
    let trigger = event
        .trigger
        .map(|t| format!(" trigger={t:?}"))
        .unwrap_or_default();
    let text = format!(
        "session={} mode={} override={} ai={} previousState={} nextState={} changed={} reason={:?} deferred={} eventId={}{delay}{note}{trigger}",
        event.session_id,
        event.mode,
        event.override_mode,
        event.is_ai_active,
        event.previous_state,
        event.next_state,
        event.changed,
        event.reason,
        event.deferred,
        event.id,
    );
    if event.changed {
        log_cat!(CTO, Info, "CTO decision {text}");
    } else {
        log_cat!(CTO, Trace, "CTO decision unchanged {text}");
    }
}

fn emit_summary_locked(m: &mut Manager) {
    let snapshot = m.monitor.snapshot();
    let transition = m.monitor.assessment_transition(snapshot.assessment());
    emit_summary(&snapshot);
    use chau7_next_core::token_optimization::CTOAssessmentTransition;
    match transition {
        Some(CTOAssessmentTransition::Initial {
            state,
            score,
            issues,
        }) => log_cat!(
            CTO,
            Info,
            "CTO runtime state initial state={state:?} score={score} issues={issues:?}"
        ),
        Some(CTOAssessmentTransition::Degraded { metadata }) => {
            log_cat!(CTO, Warn, "CTO runtime state degraded {metadata:?}")
        }
        Some(CTOAssessmentTransition::Recovered { metadata }) => {
            log_cat!(CTO, Info, "CTO runtime state recovered {metadata:?}")
        }
        None => {}
    }
}

fn emit_summary(snap: &CTORuntimeSnapshot) {
    let assessment = snap.assessment();
    let text = format!(
        "recalcCount={} created={} removed={} unchanged={} deferredSet={} deferredFlush={} deferredSkip={} changeRatePct={:.1} healthState={:?} healthScore={}",
        snap.recalc_count,
        snap.created_count,
        snap.removed_count,
        snap.unchanged_count,
        snap.deferred_set_count,
        snap.deferred_flush_count,
        snap.deferred_skip_count,
        snap.decisions_change_rate_percent(),
        assessment.state,
        assessment.score,
    );
    let text = format!(
        "{text} deferredCancel={}{}",
        snap.deferred_cancel_count,
        snap.gain_stats
            .as_ref()
            .map(|g| format!(
                " gainCommands={} gainSavedTokens={} gainSavingsPct={:.1}",
                g.commands, g.saved_tokens, g.savings_pct
            ))
            .unwrap_or_default()
    );
    match assessment.state {
        chau7_next_core::token_optimization::CTORuntimeHealthState::Healthy => {
            log_cat!(CTO, Info, "CTO runtime summary {text}");
        }
        _ => log_cat!(CTO, Warn, "CTO runtime summary {text}"),
    }
}

/// The runtime counters (settings and Debug Console).
pub fn runtime_snapshot() -> CTORuntimeSnapshot {
    with(|m| m.monitor.snapshot()).unwrap_or_default()
}

/// "Reset" in the telemetry panel.
pub fn reset_monitor() {
    with(|m| {
        m.monitor.reset();
        m.monitor.set_initial_mode(m.mode);
        mirror_locked(m);
    });
    log_cat!(CTO, Info, "cto monitor reset scope=manual");
}

// ----- health, log, statistics ---------------------------------------------------------------------

/// Installation status of every wrapper, the optimizer and the markdown
/// renderer.
#[derive(Debug, Clone, Default)]
pub struct Health {
    pub wrappers: Vec<WrapperHealth>,
    pub optimizer_installed: bool,
    pub optimizer_path: PathBuf,
    pub markdown_installed: bool,
}

pub fn health() -> Health {
    let Some(paths) = paths() else {
        return Health::default();
    };
    Health {
        wrappers: wrappers::check_installation(&paths),
        optimizer_installed: wrappers::is_optimizer_installed(&paths),
        optimizer_path: paths.optimizer(),
        markdown_installed: wrappers::is_markdown_renderer_installed(&paths),
    }
}

/// The last `limit` entries of the command log, oldest first.
pub fn command_log(limit: usize) -> Vec<CtoLogEntry> {
    paths().map_or_else(Vec::new, |p| wrappers::read_command_log(&p, limit))
}

pub fn gain_cache() -> GainCache {
    with(|m| m.gain.clone()).unwrap_or_default()
}

/// Runs `chau7-optim` with the arguments and returns its standard output.
fn run_optimizer(paths: &CtoPaths, args: &[&str]) -> Option<Vec<u8>> {
    if !wrappers::is_optimizer_installed(paths) {
        return None;
    }
    let output = Command::new(paths.optimizer())
        .args(args)
        .env(CTO_BIN_DIR_ENV, paths.bin_dir_env_value())
        .env(OPTIMIZER_DB_ENV, paths.gain_database())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    (output.status.success() && !output.stdout.is_empty()).then_some(output.stdout)
}

/// Fetch the savings in the background (`fetchDailyGainStats`, and the stats
/// of the sessions in the command log), then redraw.
pub fn refresh_gain(cx: &mut App) {
    let Some(paths) = with(|m| {
        if m.gain.loading {
            return None;
        }
        m.gain.loading = true;
        Some(m.paths.clone())
    })
    .flatten() else {
        return;
    };
    // Swift also asks for the tabs of the telemetry table.
    let tab_ids: Vec<String> = crate::telemetry::recorder(cx)
        .map(|r| {
            r.store()
                .token_usage_per_tab(None)
                .into_iter()
                .map(|t| t.tab_id)
                .collect()
        })
        .unwrap_or_default();
    cx.spawn(async move |cx| {
        let result = cx
            .background_executor()
            .spawn(async move { fetch_gain(&paths, &tab_ids) })
            .await;
        cx.update(|cx| {
            with(|m| {
                m.monitor
                    .record_gain_stats(result.0.as_ref().map(|r| r.summary.clone()));
                m.gain.response = result.0;
                m.gain.sessions = result.1;
                m.gain.loading = false;
                m.gain.loaded = true;
                mirror_locked(m);
            });
            cx.refresh_windows();
        });
    })
    .detach();
}

/// The daily savings and the savings of up to 30 recent sessions (from the
/// command log), plus the telemetry tabs (`extra_ids`).
fn fetch_gain(
    paths: &CtoPaths,
    extra_ids: &[String],
) -> (Option<DailyGainResponse>, HashMap<String, CTOGainStats>) {
    let response = run_optimizer(paths, &["gain", "--daily", "--format", "json"])
        .and_then(|out| wrappers::parse_gain(&out));
    let mut sessions = HashMap::new();
    let mut ids: Vec<String> = Vec::new();
    for entry in wrappers::read_command_log(paths, 5000).iter().rev() {
        if !entry.session_id.is_empty() && !ids.contains(&entry.session_id) {
            ids.push(entry.session_id.clone());
        }
        if ids.len() >= 30 {
            break;
        }
    }
    for id in extra_ids {
        if !id.is_empty() && !ids.contains(id) {
            ids.push(id.clone());
        }
    }
    for id in ids {
        if let Some(stats) =
            run_optimizer(paths, &["gain", "--session-id", &id, "--format", "json"])
                .and_then(|out| wrappers::parse_gain(&out))
        {
            sessions.insert(id, stats.summary);
        }
    }
    (response, sessions)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn isolated_manager(mode: TokenOptimizationMode) -> (PathBuf, Manager) {
        let home = std::env::temp_dir().join(format!("chau7-cto-manager-{}", uuid::Uuid::new_v4()));
        let paths = CtoPaths::from_root(&DataRoot::with_home(home.clone(), true));
        wrappers::create_directories(&paths).unwrap();
        let mut monitor = CtoMonitor::new();
        monitor.set_initial_mode(mode);
        (
            home,
            Manager {
                state_writer: state_file::StateWriter::start(paths.clone(), None),
                shutting_down: false,
                paths,
                mode,
                monitor,
                sessions: HashMap::new(),
                gain: GainCache::default(),
            },
        )
    }
    fn finish_fixture(home: PathBuf, mut m: Manager) {
        m.state_writer
            .take()
            .unwrap()
            .shutdown()
            .unwrap()
            .join()
            .unwrap();
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn deferred_first_prompt_live_identity_override_and_close_use_observed_flags() {
        let (home, mut m) = isolated_manager(TokenOptimizationMode::AiOnly);
        register_session_locked(&mut m, "A", TabTokenOptOverride::Default);
        set_session_state_locked(
            &mut m,
            "A",
            false,
            Some("claude".into()),
            Some("saved-tool".into()),
        );
        assert!(!wrappers::is_flag_active(&m.paths, "A"));
        assert_eq!(m.monitor.snapshot().recalc_count, 0);
        prompt_detected_locked(&mut m, "A");
        assert!(!wrappers::is_flag_active(&m.paths, "A"));
        assert_eq!(
            m.monitor.snapshot().trigger_breakdown["shellInitialized"],
            1
        );
        set_session_state_locked(
            &mut m,
            "A",
            true,
            Some("claude".into()),
            Some("live-tool".into()),
        );
        assert!(wrappers::is_flag_active(&m.paths, "A"));
        assert_eq!(m.monitor.snapshot().trigger_breakdown["aiStateChanged"], 1);
        let recalc = m.monitor.snapshot().recalc_count;
        set_session_state_locked(
            &mut m,
            "A",
            true,
            Some("claude".into()),
            Some("live-tool".into()),
        );
        assert_eq!(m.monitor.snapshot().recalc_count, recalc);
        m.sessions.get_mut("A").unwrap().override_mode = TabTokenOptOverride::ForceOff;
        recalculate_session_locked(&mut m, "A", CTODecisionTrigger::OverrideChanged);
        assert!(!wrappers::is_flag_active(&m.paths, "A"));
        assert_eq!(m.monitor.snapshot().trigger_breakdown["overrideChanged"], 1);
        unregister_session_locked(&mut m, "A");
        assert_eq!(m.monitor.snapshot().tracked_sessions, 0);
        assert!(
            m.monitor
                .diagnostic_state(Vec::new(), false)
                .tool_sessions
                .is_empty()
        );
        finish_fixture(home, m);
    }
    #[test]
    fn mode_and_close_cancel_pending_flags_without_counting_skips() {
        let (home, mut m) = isolated_manager(TokenOptimizationMode::AllTabs);
        register_session_locked(&mut m, "A", TabTokenOptOverride::Default);
        unregister_session_locked(&mut m, "A");
        assert_eq!(m.monitor.snapshot().deferred_cancel_count, 1);
        assert_eq!(m.monitor.snapshot().deferred_skip_count, 0);
        register_session_locked(&mut m, "B", TabTokenOptOverride::Default);
        m.mode = TokenOptimizationMode::AiOnly;
        m.monitor
            .record_mode_changed(TokenOptimizationMode::AllTabs, m.mode);
        recalculate_all_locked(&mut m);
        assert_eq!(m.monitor.snapshot().deferred_cancel_count, 2);
        assert!(m.sessions["B"].deferred);
        assert!(!wrappers::is_flag_active(&m.paths, "B"));
        prompt_detected_locked(&mut m, "B");
        assert_eq!(m.monitor.snapshot().deferred_flush_count, 1);
        assert!(!wrappers::is_flag_active(&m.paths, "B"));
        finish_fixture(home, m);
    }

    #[test]
    fn shell_environment_puts_the_wrapper_folder_first() {
        let root = DataRoot::with_home(PathBuf::from("/h"), false);
        let paths = CtoPaths::from_root(&root);
        let env = shell_environment(&paths, "/usr/bin:/bin", "SID");
        let get = |k: &str| {
            env.iter()
                .find(|(key, _)| key == k)
                .map(|(_, v)| v.as_str())
        };
        let config = PathBuf::from("/h").join(".chau7-next");
        let bin = config.join("cto_bin");
        let log = config.join("cto_data").join("commands.log");
        let database = config.join("cto_data").join("history.db");
        let expected_path = format!("{}:/usr/bin:/bin", bin.display());
        assert_eq!(get("PATH"), Some(expected_path.as_str()));
        assert_eq!(get("CHAU7_CTO_SESSION"), Some("SID"));
        assert_eq!(get("CHAU7_CTO_LOG"), log.to_str());
        assert_eq!(get(CTO_BIN_DIR_ENV), bin.to_str());
        assert_eq!(get(OPTIMIZER_DB_ENV), database.to_str());
    }
}
