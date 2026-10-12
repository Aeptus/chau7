//! Pull-only, Next-owned adapter for Aethyme's durable delivery outbox.
//! Broker owns authorization, deduplication and retries. We resolve an exact
//! local recipient and acknowledge its generation after terminal acceptance.
use crate::mcp::{MainThread, windows};
use chau7_next_core::{
    aethyme_delivery::{
        self as delivery, ClaimReport, Envelope, Readiness, TabSnapshot, Target, Watch,
    },
    subprocess,
};
use gpui::{App, AppContext, Global, Task};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    process::Command,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

struct Monitor {
    stopped: Arc<AtomicBool>,
    _task: Task<()>,
}
impl Global for Monitor {}
pub fn start(cx: &mut App) {
    if cx.has_global::<Monitor>() {
        return;
    }
    let stopped = Arc::new(AtomicBool::new(false));
    let cancel = stopped.clone();
    let main = MainThread::start(cx);
    let executor = cx.background_executor().clone();
    let timer = crate::observability::register_background_timer(
        cx,
        "monitor.aethyme_delivery",
        "Aethyme Next delivery polling",
        "monitoring",
        30_000,
    );
    let task = cx.background_spawn(async move {
        let _timer = timer;
        executor.timer(Duration::from_secs(15)).await;
        let mut runner = Runner::new(cancel.clone());
        while !cancel.load(Ordering::Acquire) {
            if !runner.backing_off() {
                if let Some(executable) = resolve_executable() {
                    runner.executable = executable;
                    let snapshots = main.read(live_snapshots).unwrap_or_default();
                    // All filesystem resolution happens on this background worker.
                    let roots: HashMap<_, _> = snapshots
                        .iter()
                        .filter_map(|snapshot| snapshot.repository_root.as_ref())
                        .map(|raw| (raw.clone(), canonical(raw)))
                        .collect();
                    let mut repos: Vec<_> = roots.values().cloned().collect();
                    repos.sort();
                    repos.dedup();
                    let mut accepted = HashSet::new();
                    for root in repos {
                        if runner.backing_off() || cancel.load(Ordering::Acquire) {
                            break;
                        }
                        runner.run_root(&root, |target, prompt| {
                            if accepted.contains(&(target.tab_id, target.ai_session_id.clone())) {
                                return Readiness::Retry("target_tab_busy");
                            }
                            // A tab may have appeared or changed repository during
                            // CLI polling. Resolve its current cached identity before
                            // background canonicalization, then revalidate at write.
                            let tab_id = target.tab_id;
                            let latest = main.read(move |cx| {
                                live_snapshots(cx).into_iter().find(|s| s.tab_id == tab_id)
                            });
                            let initial = match latest {
                                Ok(Some(snapshot)) => snapshot.repository_root,
                                Ok(None) => return Readiness::Retry("target_tab_missing"),
                                Err(_) => return Readiness::Retry("main_thread_unresponsive"),
                            };
                            let expected = initial.as_ref().map(|raw| canonical(raw));
                            let target = target.clone();
                            let prompt = prompt.to_string();
                            let root = root.clone();
                            let cancel = cancel.clone();
                            // Mutations are never timed out and retried: a late accepted
                            // write must not be reported as retry. Teardown closes the loop.
                            let key = (target.tab_id, target.ai_session_id.clone());
                            let readiness = main
                                .call(move |cx| {
                                    deliver(
                                        cx,
                                        &target,
                                        &prompt,
                                        &root,
                                        initial.as_deref(),
                                        expected.as_deref(),
                                        &cancel,
                                    )
                                })
                                .unwrap_or(Readiness::Retry("application_stopping"));
                            if readiness == Readiness::Ready {
                                accepted.insert(key);
                            }
                            readiness
                        });
                    }
                } else {
                    runner
                        .log_unavailable("Aethyme Next delivery inactive: executable unavailable");
                }
            }
            executor.timer(Duration::from_secs(30)).await;
        }
    });
    cx.set_global(Monitor {
        stopped,
        _task: task,
    });
}
pub fn stop(cx: &mut App) {
    if cx.has_global::<Monitor>() {
        let monitor = cx.remove_global::<Monitor>();
        monitor.stopped.store(true, Ordering::Release);
    }
}
fn live_snapshots(cx: &mut App) -> Vec<TabSnapshot> {
    let mut snapshots = Vec::new();
    for window in windows::windows(cx) {
        let workspace = window.workspace.read(cx);
        for uuid in workspace.mcp_tab_uuids() {
            if let Some(id) = workspace.mcp_find(uuid)
                && let Some(session) = workspace.mcp_session(id, cx)
            {
                let summary = workspace.mcp_readiness_summary(id, cx);
                let session = session.read(cx);
                snapshots.push(TabSnapshot {
                    tab_id: uuid,
                    ai_session_id: session.shell().ai_session_id().map(str::to_string),
                    ai_provider: session.shell().effective_provider(),
                    repository_root: session
                        .git_root
                        .as_ref()
                        .map(|p| p.to_string_lossy().into_owned()),
                    status: summary
                        .get("status")
                        .and_then(|v| v.as_str())
                        .unwrap_or("unknown")
                        .into(),
                    is_at_prompt: summary
                        .get("is_at_prompt")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false),
                    has_pending_input: session.has_pending_automation_input()
                        || session.is_loading()
                        || session.is_echo_disabled(),
                });
            }
        }
    }
    snapshots
}
fn deliver(
    cx: &mut App,
    target: &Target,
    prompt: &str,
    root: &str,
    initial_raw: Option<&str>,
    initial_canonical: Option<&str>,
    stopped: &AtomicBool,
) -> Readiness {
    if stopped.load(Ordering::Acquire) {
        return Readiness::Retry("application_stopping");
    }
    let Some(tab) = windows::find_tab(&target.tab_id.to_string(), cx) else {
        return Readiness::Retry("target_tab_missing");
    };
    let workspace = tab.window.workspace.read(cx);
    let Some(session) = workspace.mcp_session(tab.tab, cx) else {
        return Readiness::Retry("target_agent_unavailable");
    };
    let summary = workspace.mcp_readiness_summary(tab.tab, cx);
    let current = session.read(cx);
    let raw = current
        .git_root
        .as_ref()
        .map(|p| p.to_string_lossy().into_owned());
    // Revalidate cached root on the UI thread; no canonicalize/stat/git here.
    if raw.as_deref() != initial_raw {
        return Readiness::Failed("target_repository_mismatch");
    }
    let snapshot = TabSnapshot {
        tab_id: target.tab_id,
        ai_session_id: current.shell().ai_session_id().map(str::to_string),
        ai_provider: current.shell().effective_provider(),
        repository_root: initial_canonical.map(str::to_string),
        status: summary
            .get("status")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .into(),
        is_at_prompt: summary
            .get("is_at_prompt")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        has_pending_input: current.has_pending_automation_input()
            || current.is_loading()
            || current.is_echo_disabled(),
    };
    let readiness = delivery::evaluate(target, Some(&snapshot), root);
    if readiness == Readiness::Ready {
        current.write_input(format!("{prompt}\n").as_bytes());
    }
    readiness
}
fn canonical(raw: &str) -> String {
    std::fs::canonicalize(raw)
        .unwrap_or_else(|_| PathBuf::from(raw))
        .to_string_lossy()
        .into_owned()
}
fn resolve_executable() -> Option<PathBuf> {
    let mut candidates = vec![
        PathBuf::from("/opt/homebrew/bin/aethyme"),
        PathBuf::from("/usr/local/bin/aethyme"),
    ];
    if let Some(home) = std::env::var_os("HOME") {
        candidates.push(PathBuf::from(home).join(".cargo/bin/aethyme"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|p| {
            p.join(if cfg!(windows) {
                "aethyme.exe"
            } else {
                "aethyme"
            })
        }));
    }
    candidates.into_iter().find(|path| {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            path.metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        }
        #[cfg(not(unix))]
        {
            path.is_file()
        }
    })
}
#[derive(Clone, Copy)]
enum CaptureKind {
    List,
    Poll,
    Claim,
    Complete,
}
impl CaptureKind {
    fn caller(self) -> &'static str {
        match self {
            Self::List => "monitor.aethyme_delivery.list",
            Self::Poll => "monitor.aethyme_delivery.poll",
            Self::Claim => "monitor.aethyme_delivery.claim",
            Self::Complete => "monitor.aethyme_delivery.complete",
        }
    }
}

struct Runner {
    executable: PathBuf,
    worker: String,
    stopped: Arc<AtomicBool>,
    backoff: Option<Instant>,
    logged_unavailable: bool,
    incomplete_failures: [u32; 4],
}
impl Runner {
    fn new(stopped: Arc<AtomicBool>) -> Self {
        Self {
            executable: PathBuf::new(),
            worker: format!("chau7-next-{}", std::process::id()),
            stopped,
            backoff: None,
            logged_unavailable: false,
            incomplete_failures: [0; 4],
        }
    }
    fn backing_off(&self) -> bool {
        self.backoff.is_some_and(|until| until > Instant::now())
    }
    fn log_unavailable(&mut self, message: &str) {
        if !self.logged_unavailable {
            self.logged_unavailable = true;
            log::info!("{message}");
        }
    }
    // Consecutive incomplete captures are one outage. Never retry an uncertain
    // claim immediately or flood the operational log; successful capture resets.
    fn incomplete_capture(&mut self, kind: CaptureKind, now: Instant) -> bool {
        if self.stopped.load(Ordering::Acquire) {
            return false;
        }
        let failures = &mut self.incomplete_failures[kind as usize];
        let first = *failures == 0;
        let exponent = (*failures).min(4);
        let delay = Duration::from_secs((30_u64 << exponent).min(300));
        *failures = failures.saturating_add(1);
        self.backoff = Some(now + delay);
        first
    }
    fn completion_warning_required(&self) -> bool {
        !self.stopped.load(Ordering::Acquire) && !self.backing_off()
    }
    fn run(
        &mut self,
        root: &str,
        args: Vec<String>,
        kind: CaptureKind,
    ) -> Option<subprocess::CaptureResult> {
        if self.backing_off() || self.stopped.load(Ordering::Acquire) {
            return None;
        }
        let mut work =
            chau7_next_core::work_profiler::begin(chau7_next_core::work_profiler::Key::work(
                "aethyme.delivery",
                "subprocess_capture_wall",
                "application",
                kind.caller(),
                chau7_next_core::work_profiler::Queue::Background,
            ));
        work.items(1);
        work.idle(false);
        let result = subprocess::capture_unless(
            Command::new(&self.executable)
                .args(args)
                .current_dir(root)
                .env("GH_PROMPT_DISABLED", "1")
                .env("GIT_TERMINAL_PROMPT", "0")
                .env("NO_COLOR", "1"),
            Duration::from_secs(15),
            4 * 1024 * 1024,
            || self.stopped.load(Ordering::Acquire),
        );
        if let Ok(output) = &result {
            work.bytes(output.stdout.len().saturating_add(output.stderr.len()));
        }
        // This phase includes actual subprocess execution/wait, never the
        // enclosing executor timer, logging or later recipient delivery.
        drop(work);
        let Ok(result) = result else {
            self.log_unavailable("Aethyme Next delivery could not launch its executable");
            return None;
        };
        if !result.completed() {
            if self.incomplete_capture(kind, Instant::now()) {
                log::warn!("Aethyme capture incomplete; leaving any uncertain claim to expire");
            }
            return None;
        }
        if result.status != Some(0) {
            let message = String::from_utf8_lossy(&result.stderr).to_ascii_lowercase();
            if ["unknown", "upgrade", "schema", "removed"]
                .iter()
                .any(|word| message.contains(word))
            {
                self.backoff = Some(Instant::now() + Duration::from_secs(600));
                self.log_unavailable("Aethyme Next delivery requires a compatible deployment");
            }
            return None;
        }
        self.incomplete_failures[kind as usize] = 0;
        self.logged_unavailable = false;
        self.backoff = None;
        Some(result)
    }
    fn run_root(&mut self, root: &str, mut deliver: impl FnMut(&Target, &str) -> Readiness) {
        let Some(watches) = self
            .run(root, delivery::list_watches(), CaptureKind::List)
            .and_then(|r| serde_json::from_slice::<Vec<Watch>>(&r.stdout).ok())
        else {
            return;
        };
        let now = chrono::Utc::now().timestamp_millis();
        for watch in watches
            .into_iter()
            .filter(|w| w.id > 0 && w.status == "active" && w.next_poll_at.unwrap_or(0) <= now)
            .take(4)
        {
            let _ = self.run(root, delivery::poll_watch(watch.id), CaptureKind::Poll);
        }
        for _ in 0..4 {
            let Some(result) = self.run(root, delivery::claim(&self.worker), CaptureKind::Claim)
            else {
                return;
            };
            let envelope = serde_json::from_slice::<ClaimReport>(&result.stdout)
                .ok()
                .and_then(|report| report.validated(&self.worker).ok());
            let Some(Some(envelope)) = envelope else {
                return;
            };
            let readiness = match Target::parse(&envelope.subscription.target) {
                Some(target) => deliver(
                    &target,
                    &format!(
                        "[Aethyme delivery #{}]\n{}",
                        envelope.item.id, envelope.prompt
                    ),
                ),
                None => Readiness::Failed("invalid_chau7_next_target"),
            };
            self.complete(root, &envelope, &readiness);
            if matches!(readiness, Readiness::Retry(_)) {
                return;
            }
        }
    }
    fn complete(&mut self, root: &str, envelope: &Envelope, readiness: &Readiness) {
        if self
            .run(
                root,
                delivery::complete(&envelope.item, &self.worker, readiness),
                CaptureKind::Complete,
            )
            .is_none()
            && self.completion_warning_required()
        {
            log::warn!("Aethyme completion failed; its fenced claim will expire safely");
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use serde_json::json;
    use std::os::unix::fs::PermissionsExt;
    struct Fixture {
        root: PathBuf,
        runner: Runner,
        target: Target,
    }
    impl Fixture {
        fn new(target_scheme: &str, claim_contents: Option<&str>, unsupported: bool) -> Self {
            let root = std::env::temp_dir().join(format!(
                "chau7-next-delivery-fixture-{}",
                uuid::Uuid::new_v4()
            ));
            std::fs::create_dir_all(&root).unwrap();
            let mut runner = Runner::new(Arc::new(AtomicBool::new(false)));
            runner.executable = root.join("fake-aethyme");
            let target = Target {
                tab_id: uuid::Uuid::new_v4(),
                ai_session_id: "own-native-session".into(),
            };
            let report = json!({"adapter":delivery::ADAPTER,"worker":runner.worker,"delivery":{"item":{"id":7,"generation":11},"subscription":{"id":5,"target":target.opaque_value().replacen("chau7-next:",target_scheme,1),"policy":"resume"},"watch":{"id":1,"canonical_repository":"example/repo","pr_number":12,"head_sha":"head"},"batch":{"id":9,"head_sha":"head"},"prompt":"continue the task"}});
            std::fs::write(
                root.join("claim.json"),
                claim_contents
                    .map(str::to_string)
                    .unwrap_or_else(|| report.to_string()),
            )
            .unwrap();
            std::fs::write(
                root.join("empty.json"),
                json!({"adapter":delivery::ADAPTER,"worker":runner.worker,"delivery":null})
                    .to_string(),
            )
            .unwrap();
            let watches: Vec<_> = (1..=9).map(|id| json!({"id":id,"status":if id==9 {"paused"} else {"active"},"next_poll_at":null})).collect();
            std::fs::write(
                root.join("watches.json"),
                serde_json::to_vec(&watches).unwrap(),
            )
            .unwrap();
            let script = if unsupported {
                "#!/bin/sh\nprintf 'schema upgrade required' >&2\nexit 2\n"
            } else {
                r#"#!/bin/sh
[ "$GH_PROMPT_DISABLED:$GIT_TERMINAL_PROMPT:$NO_COLOR" = '1:0:1' ] || exit 91
printf '%s\n' "$*" >> calls
case "$3:$4:$5" in
  watch:pr:list) cat watches.json ;;
  watch:pr:poll) printf '{}' ;;
  deliveries:claim:--adapter) if [ -e claimed ]; then cat empty.json; else touch claimed; cat claim.json; fi ;;
  deliveries:complete:--id) printf '{}' ;;
  *) exit 92 ;;
esac
"#
            };
            std::fs::write(&runner.executable, script).unwrap();
            std::fs::set_permissions(&runner.executable, std::fs::Permissions::from_mode(0o700))
                .unwrap();
            Self {
                root,
                runner,
                target,
            }
        }
        fn calls(&self) -> Vec<String> {
            std::fs::read_to_string(self.root.join("calls"))
                .unwrap_or_default()
                .lines()
                .map(str::to_string)
                .collect()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn isolated_cli_polls_four_and_fences_accepted_delivery() {
        let mut f = Fixture::new("chau7-next:", None, false);
        let target = f.target.clone();
        let mut delivered = 0;
        f.runner
            .run_root(f.root.to_str().unwrap(), |actual, prompt| {
                assert_eq!(actual, &target);
                assert_eq!(prompt, "[Aethyme delivery #7]\ncontinue the task");
                delivered += 1;
                Readiness::Ready
            });
        assert_eq!(delivered, 1);
        let calls = f.calls();
        assert_eq!(
            calls
                .iter()
                .filter(|c| c.starts_with("broker advanced watch pr poll"))
                .count(),
            4
        );
        assert_eq!(
            calls
                .iter()
                .filter(|c| c.contains("deliveries claim --adapter chau7-next"))
                .count(),
            2
        );
        assert!(
            calls
                .iter()
                .any(|c| c.contains("deliveries complete --id 7")
                    && c.contains("--generation 11 --outcome delivered"))
        );
    }
    #[test]
    fn retry_stops_drain_and_never_sends_a_second_prompt() {
        let mut f = Fixture::new("chau7-next:", None, false);
        let mut attempts = 0;
        f.runner.run_root(f.root.to_str().unwrap(), |_, _| {
            attempts += 1;
            Readiness::Retry("target_has_pending_input")
        });
        assert_eq!(attempts, 1);
        let calls = f.calls();
        assert_eq!(
            calls
                .iter()
                .filter(|c| c.contains("deliveries claim"))
                .count(),
            1
        );
        assert!(
            calls
                .iter()
                .any(|c| c.contains("--outcome retry --error-code target_has_pending_input"))
        );
    }
    #[test]
    fn swift_target_and_partial_claim_never_deliver() {
        let mut f = Fixture::new("chau7:", None, false);
        f.runner.run_root(f.root.to_str().unwrap(), |_, _| {
            panic!("must not send to Swift")
        });
        assert!(
            f.calls()
                .iter()
                .any(|c| c.contains("--outcome failed --error-code invalid_chau7_next_target"))
        );
        let mut f = Fixture::new("chau7-next:", Some("{\"adapter\":\"chau7-next\""), false);
        f.runner.run_root(f.root.to_str().unwrap(), |_, _| {
            panic!("must not decode partial claim")
        });
        assert!(!f.calls().iter().any(|c| c.contains("deliveries complete")));
    }
    #[test]
    fn unsupported_and_cancelled_commands_do_not_drain() {
        let mut f = Fixture::new("chau7-next:", None, true);
        f.runner
            .run_root(f.root.to_str().unwrap(), |_, _| panic!("unsupported"));
        assert!(f.runner.backing_off());
        assert!(
            f.runner
                .backoff
                .unwrap()
                .saturating_duration_since(Instant::now())
                > Duration::from_secs(590)
        );
        let mut f = Fixture::new("chau7-next:", None, false);
        f.runner.stopped.store(true, Ordering::Release);
        f.runner
            .run_root(f.root.to_str().unwrap(), |_, _| panic!("stopped"));
        assert!(f.calls().is_empty());
    }
    #[test]
    fn incomplete_captures_back_off_with_a_bound_and_one_warning_per_outage() {
        let mut runner = Runner::new(Arc::new(AtomicBool::new(false)));
        let now = Instant::now();
        for (index, seconds) in [30, 60, 120, 240, 300, 300].into_iter().enumerate() {
            assert_eq!(
                runner.incomplete_capture(CaptureKind::List, now),
                index == 0
            );
            assert_eq!(
                runner.backoff.unwrap().duration_since(now),
                Duration::from_secs(seconds)
            );
        }
        runner.incomplete_failures[CaptureKind::List as usize] = u32::MAX;
        assert!(!runner.incomplete_capture(CaptureKind::List, now));
        assert_eq!(
            runner.incomplete_failures[CaptureKind::List as usize],
            u32::MAX
        );
        assert_eq!(
            runner.backoff.unwrap().duration_since(now),
            Duration::from_secs(300)
        );
    }
    #[test]
    fn successful_owned_capture_resets_incomplete_outage_and_normal_polling() {
        let mut fixture = Fixture::new("chau7-next:", None, false);
        assert!(
            fixture
                .runner
                .incomplete_capture(CaptureKind::List, Instant::now())
        );
        assert!(
            !fixture
                .runner
                .incomplete_capture(CaptureKind::List, Instant::now())
        );
        // Model expiry without sleeping; the actual fake CLI capture must reset.
        fixture.runner.backoff = None;
        assert!(
            fixture
                .runner
                .run(
                    fixture.root.to_str().unwrap(),
                    delivery::list_watches(),
                    CaptureKind::List
                )
                .is_some()
        );
        assert_eq!(fixture.runner.incomplete_failures, [0; 4]);
        assert!(fixture.runner.backoff.is_none());
        assert!(
            fixture
                .runner
                .incomplete_capture(CaptureKind::List, Instant::now())
        );
        assert!(
            fixture
                .calls()
                .iter()
                .any(|call| call.contains("watch pr list"))
        );
    }
    #[test]
    fn shutdown_cancellation_does_not_open_an_incomplete_outage() {
        let mut runner = Runner::new(Arc::new(AtomicBool::new(true)));
        assert!(!runner.incomplete_capture(CaptureKind::List, Instant::now()));
        assert_eq!(runner.incomplete_failures, [0; 4]);
        assert!(runner.backoff.is_none());
    }

    #[test]
    fn actual_output_limit_stops_delivery_and_repeated_captures_back_off() {
        let mut fixture = Fixture::new("chau7-next:", None, false);
        std::fs::write(
            &fixture.runner.executable,
            "#!/bin/sh\nprintf '%s\n' attempt >> attempts\nhead -c 4194305 /dev/zero\n",
        )
        .unwrap();
        for expected in [1, 2] {
            fixture.runner.backoff = None;
            fixture
                .runner
                .run_root(fixture.root.to_str().unwrap(), |_, _| {
                    panic!("incomplete capture delivered")
                });
            assert_eq!(
                fixture.runner.incomplete_failures[CaptureKind::List as usize],
                expected
            );
            assert!(fixture.runner.backing_off());
            assert!(
                fixture
                    .runner
                    .run(
                        fixture.root.to_str().unwrap(),
                        delivery::list_watches(),
                        CaptureKind::List
                    )
                    .is_none()
            );
        }
        assert_eq!(
            std::fs::read_to_string(fixture.root.join("attempts"))
                .unwrap()
                .lines()
                .count(),
            2
        );
    }
    #[test]
    fn successful_list_and_poll_do_not_reset_an_incomplete_claim_outage() {
        let mut fixture = Fixture::new("chau7-next:", None, false);
        let script = std::fs::read_to_string(&fixture.runner.executable).unwrap();
        let script = script.replace("case \"$3:$4:$5\" in\n", "if [ \"$3:$4\" = 'deliveries:claim' ]; then\nprintf '%s\n' attempt >> attempts\nhead -c 4194305 /dev/zero\nexit 0\nfi\ncase \"$3:$4:$5\" in\n");
        std::fs::write(&fixture.runner.executable, script).unwrap();
        for expected in [1, 2] {
            fixture.runner.backoff = None;
            fixture
                .runner
                .run_root(fixture.root.to_str().unwrap(), |_, _| {
                    panic!("incomplete claim delivered")
                });
            assert_eq!(
                fixture.runner.incomplete_failures[CaptureKind::Claim as usize],
                expected
            );
            assert_eq!(
                fixture.runner.incomplete_failures[CaptureKind::List as usize],
                0
            );
            assert_eq!(
                fixture.runner.incomplete_failures[CaptureKind::Poll as usize],
                0
            );
            assert!(!fixture.runner.completion_warning_required());
        }
        assert_eq!(
            std::fs::read_to_string(fixture.root.join("attempts"))
                .unwrap()
                .lines()
                .count(),
            2
        );
        assert_eq!(
            fixture
                .calls()
                .iter()
                .filter(|call| call.contains("watch pr list"))
                .count(),
            2
        );
    }
    #[test]
    fn completion_warning_is_suppressed_for_backoff_and_shutdown() {
        let mut runner = Runner::new(Arc::new(AtomicBool::new(false)));
        assert!(runner.completion_warning_required());
        assert!(runner.incomplete_capture(CaptureKind::Complete, Instant::now()));
        assert!(!runner.completion_warning_required());
        runner.backoff = None;
        assert!(runner.completion_warning_required());
        runner.stopped.store(true, Ordering::Release);
        assert!(!runner.completion_warning_required());
    }
}
