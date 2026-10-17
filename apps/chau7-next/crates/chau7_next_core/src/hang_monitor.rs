//! Token-based main-thread stall detection and bounded diagnostic lifetime.
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, time::Duration};

/// Leave most of the deadline available for attaching and formatting symbols.
#[derive(Clone, Copy, Debug)]
pub struct SamplePolicy {
    pub duration_seconds: u32,
    pub interval_ms: u32,
    pub timeout: Duration,
}
impl Default for SamplePolicy {
    fn default() -> Self {
        Self {
            duration_seconds: 1,
            interval_ms: 10,
            timeout: Duration::from_secs(10),
        }
    }
}
impl SamplePolicy {
    pub fn arguments(self, pid: u32, output: &std::path::Path) -> Vec<String> {
        vec![
            pid.to_string(),
            self.duration_seconds.to_string(),
            self.interval_ms.to_string(),
            "-file".into(),
            output.to_string_lossy().into_owned(),
        ]
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Policy {
    pub stall_threshold: Duration,
    pub sample_threshold: Duration,
    pub sample_cooldown: Duration,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            stall_threshold: Duration::from_secs(2),
            sample_threshold: Duration::from_secs(2),
            sample_cooldown: Duration::from_secs(60),
        }
    }
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    #[default]
    Healthy,
    Stalled,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Observation {
    pub phase: Phase,
    pub stale_for: Duration,
    pub entered_stall: bool,
    pub recovered: bool,
    pub should_sample: bool,
}
pub struct Monitor {
    token: u64,
    last_progress: Duration,
    last_sample: Option<Duration>,
    sampled_stall: bool,
    phase: Phase,
}
impl Monitor {
    pub fn new(token: u64, now: Duration, last_sample: Option<Duration>) -> Self {
        Self {
            token,
            last_progress: now,
            last_sample,
            sampled_stall: false,
            phase: Phase::Healthy,
        }
    }
    pub fn observe(&mut self, token: u64, now: Duration, policy: Policy) -> Observation {
        assert!(
            !policy.stall_threshold.is_zero() && policy.sample_threshold >= policy.stall_threshold
        );
        if token != self.token {
            let recovered = self.phase == Phase::Stalled;
            let stale_for = if recovered {
                now.saturating_sub(self.last_progress)
            } else {
                Duration::ZERO
            };
            self.token = token;
            self.last_progress = now;
            self.sampled_stall = false;
            self.phase = Phase::Healthy;
            return Observation {
                phase: self.phase,
                stale_for,
                entered_stall: false,
                recovered,
                should_sample: false,
            };
        }
        let stale_for = now.saturating_sub(self.last_progress);
        let entered_stall = self.phase == Phase::Healthy && stale_for >= policy.stall_threshold;
        if entered_stall {
            self.phase = Phase::Stalled;
        }
        let should_sample = self.phase == Phase::Stalled
            && !self.sampled_stall
            && stale_for >= policy.sample_threshold
            && self.last_sample.is_none_or(|sample| {
                now.checked_sub(sample)
                    .is_some_and(|elapsed| elapsed >= policy.sample_cooldown)
            });
        if should_sample {
            self.last_sample = Some(now);
            self.sampled_stall = true;
        }
        Observation {
            phase: self.phase,
            stale_for,
            entered_stall,
            recovered: false,
            should_sample,
        }
    }
}

pub struct Lifetime {
    started: Duration,
    healthy_since: Option<Duration>,
}
impl Lifetime {
    pub fn new(started: Duration) -> Self {
        Self {
            started,
            healthy_since: None,
        }
    }
    pub fn observe(&mut self, healthy: bool, now: Duration) {
        if healthy {
            self.healthy_since.get_or_insert(now);
        } else {
            self.healthy_since = None;
        }
    }
    pub fn should_exit(&self, parent_alive: bool, now: Duration) -> bool {
        !parent_alive
            || self
                .healthy_since
                .is_some_and(|since| now.saturating_sub(since) >= Duration::from_secs(2))
            || now.saturating_sub(self.started) >= Duration::from_secs(3600)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct WatchdogCommand {
    pub parent_pid: u32,
    pub heartbeat: PathBuf,
    pub output_directory: PathBuf,
}
impl WatchdogCommand {
    /// A partial, repeated or unknown watchdog option never starts another GUI.
    pub fn parse(args: &[String]) -> Result<Option<Self>, &'static str> {
        if !args.iter().any(|arg| arg == "--hang-watchdog") {
            return Ok(None);
        }
        let mut parent_pid = None;
        let mut heartbeat = None;
        let mut output_directory = None;
        let mut flag = false;
        let mut i = 0;
        while i < args.len() {
            let arg = &args[i];
            if arg == "--hang-watchdog" {
                if flag {
                    return Err("repeated watchdog flag");
                }
                flag = true;
                i += 1;
                continue;
            }
            let value = args.get(i + 1).ok_or("missing watchdog value")?;
            match arg.as_str() {
                "--parent-pid" if parent_pid.is_none() => {
                    parent_pid = Some(value.parse::<u32>().map_err(|_| "invalid parent PID")?)
                }
                "--heartbeat" if heartbeat.is_none() => heartbeat = Some(PathBuf::from(value)),
                "--output-directory" if output_directory.is_none() => {
                    output_directory = Some(PathBuf::from(value))
                }
                _ => return Err("unknown or repeated watchdog option"),
            }
            i += 2;
        }
        let command = Self {
            parent_pid: parent_pid.ok_or("missing parent PID")?,
            heartbeat: heartbeat.ok_or("missing heartbeat")?,
            output_directory: output_directory.ok_or("missing output directory")?,
        };
        if command.parent_pid <= 1
            || command.parent_pid > i32::MAX as u32
            || !command.heartbeat.is_absolute()
            || !command.output_directory.is_absolute()
        {
            return Err("invalid watchdog target");
        }
        Ok(Some(command))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Heartbeat {
    pub schema_version: u32,
    pub parent_pid: u32,
    pub launch_id: String,
    pub progress_token: u64,
    pub observed_uptime_ms: u64,
}
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HeartbeatProgress {
    Advanced,
    Unchanged,
    Unavailable,
}
#[derive(Debug, Serialize)]
pub struct SampleEvidence {
    pub heartbeat_progress_during_capture: HeartbeatProgress,
    pub capture_duration_seconds: f64,
}
impl SampleEvidence {
    pub fn new(
        before: Option<u64>,
        after: Option<u64>,
        started: Duration,
        completed: Duration,
    ) -> Self {
        Self {
            heartbeat_progress_during_capture: match (before, after) {
                (Some(a), Some(b)) if a == b => HeartbeatProgress::Unchanged,
                (Some(_), Some(_)) => HeartbeatProgress::Advanced,
                _ => HeartbeatProgress::Unavailable,
            },
            capture_duration_seconds: completed.saturating_sub(started).as_secs_f64(),
        }
    }
}
#[derive(Debug, Serialize)]
pub struct StackObservations {
    pub main_thread_found: bool,
    pub main_thread_sample_count: Option<u64>,
    pub observed_families: Vec<&'static str>,
    pub input_truncated: bool,
}
impl StackObservations {
    pub const MAX_INPUT_BYTES: usize = 1024 * 1024;
    pub fn from_sample(bytes: &[u8]) -> Self {
        let input_truncated = bytes.len() > Self::MAX_INPUT_BYTES;
        let text = String::from_utf8_lossy(&bytes[..bytes.len().min(Self::MAX_INPUT_BYTES)]);
        let mut found = false;
        let mut count = None;
        let mut main = String::new();
        for line in text.lines() {
            let mut tokens = line.split_whitespace();
            let samples = tokens.next().and_then(|s| s.parse::<u64>().ok());
            let header =
                samples.is_some() && tokens.next().is_some_and(|s| s.starts_with("Thread_"));
            if header {
                if found {
                    break;
                }
                if line.contains("com.apple.main-thread") {
                    found = true;
                    count = samples;
                }
            } else if found {
                main.push_str(line);
                main.push('\n');
            }
        }
        let mut families = Vec::new();
        if main.contains("_Block_release")
            && main.contains("objc_destructInstance")
            && main.contains("_object_remove_associations")
        {
            families.push("objective_c_block_teardown");
        }
        if main.contains("runModal") && main.contains("NSAlert") {
            families.push("modal_dialog");
        }
        if main.contains("NSHostingView") && main.to_lowercase().contains("layout") {
            families.push("view_layout");
        }
        if main.contains("GitStatsSnapshotStore") && main.contains("loadRepositoryStats") {
            families.push("repository_statistics");
        }
        if main.contains("send")
            && (main.contains("MCPSession") || main.contains("BoundedSocketWriter"))
        {
            families.push("socket_write");
        }
        Self {
            main_thread_found: found,
            main_thread_sample_count: count,
            observed_families: families,
            input_truncated,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn at(s: u64) -> Duration {
        Duration::from_secs(s)
    }
    #[test]
    fn sample_budget_captures_short_stalls_and_leaves_report_headroom() {
        let policy = SamplePolicy::default();
        assert!(policy.duration_seconds <= 1);
        assert!(policy.timeout >= Duration::from_secs(policy.duration_seconds as u64 + 5));
        assert_eq!(
            policy.arguments(42, std::path::Path::new("/fixture/hang.sample.txt")),
            ["42", "1", "10", "-file", "/fixture/hang.sample.txt"]
        );
    }
    #[test]
    fn threshold_samples_once_and_recovers() {
        let mut m = Monitor::new(1, at(0), None);
        assert_eq!(m.observe(1, at(1), Policy::default()).phase, Phase::Healthy);
        let o = m.observe(1, at(2), Policy::default());
        assert!(o.entered_stall && o.should_sample);
        assert!(!m.observe(1, at(100), Policy::default()).should_sample);
        let o = m.observe(2, at(101), Policy::default());
        assert!(o.recovered && !o.should_sample);
        assert_eq!(o.stale_for, at(101));
        assert!(m.observe(2, at(103), Policy::default()).should_sample);
    }
    #[test]
    fn cooldown_survives_replacement_and_waits_within_same_stall() {
        let mut m = Monitor::new(1, at(0), Some(at(1)));
        assert!(!m.observe(1, at(2), Policy::default()).should_sample);
        assert!(!m.observe(1, at(60), Policy::default()).should_sample);
        assert!(m.observe(1, at(61), Policy::default()).should_sample);
    }
    #[test]
    fn backward_clock_never_creates_false_sample_or_negative_age() {
        let mut m = Monitor::new(1, at(10), Some(at(20)));
        assert_eq!(
            m.observe(1, at(1), Policy::default()).stale_for,
            Duration::ZERO
        );
        assert!(!m.observe(1, at(15), Policy::default()).should_sample);
    }
    #[test]
    fn recovery_grace_resets_on_another_stall_and_parent_exit_wins() {
        let mut l = Lifetime::new(at(0));
        l.observe(true, at(1));
        assert!(!l.should_exit(true, at(2)));
        l.observe(false, at(2));
        assert!(!l.should_exit(true, at(3)));
        l.observe(true, at(3));
        assert!(l.should_exit(true, at(5)));
        assert!(Lifetime::new(at(0)).should_exit(false, at(0)));
        assert!(Lifetime::new(at(0)).should_exit(true, at(3600)));
    }
    #[test]
    fn partial_cli_invocation_does_not_open_gui() {
        assert!(WatchdogCommand::parse(&["--hang-watchdog".into()]).is_err());
        assert_eq!(WatchdogCommand::parse(&[]), Ok(None));
        let mut args: Vec<_> = [
            "--hang-watchdog",
            "--parent-pid",
            "42",
            "--heartbeat",
            "/tmp/hb",
            "--output-directory",
            "/tmp/out",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        args[4] = std::env::temp_dir()
            .join("hb")
            .to_string_lossy()
            .into_owned();
        args[6] = std::env::temp_dir()
            .join("out")
            .to_string_lossy()
            .into_owned();
        assert_eq!(
            WatchdogCommand::parse(&args).unwrap().unwrap().parent_pid,
            42
        );
        for bad in ["0", "1", "-1", "2147483648", "abc"] {
            let mut a = args.clone();
            a[2] = bad.into();
            assert!(WatchdogCommand::parse(&a).is_err());
        }
        let mut a = args.clone();
        a.push("--hang-watchdog".into());
        assert!(WatchdogCommand::parse(&a).is_err());
        let mut a = args.clone();
        a[4] = "relative".into();
        assert!(WatchdogCommand::parse(&a).is_err());
    }
    #[test]
    fn capture_evidence_describes_progress_without_diagnosing_deadlock() {
        assert_eq!(
            SampleEvidence::new(Some(1), Some(1), at(3), at(2)).capture_duration_seconds,
            0.0
        );
        assert_eq!(
            SampleEvidence::new(Some(1), Some(2), at(0), at(1)).heartbeat_progress_during_capture,
            HeartbeatProgress::Advanced
        );
        assert_eq!(
            SampleEvidence::new(Some(1), None, at(0), at(1)).heartbeat_progress_during_capture,
            HeartbeatProgress::Unavailable
        );
    }
    #[test]
    fn only_main_thread_frames_contribute_to_families() {
        let sample = b"10 Thread_1 worker\n send MCPSession\n12 Thread_2 com.apple.main-thread\nNSAlert runModal\n7 Thread_3 worker\n_Block_release objc_destructInstance _object_remove_associations\n";
        let s = StackObservations::from_sample(sample);
        assert!(s.main_thread_found);
        assert_eq!(s.main_thread_sample_count, Some(12));
        assert_eq!(s.observed_families, vec!["modal_dialog"]);
    }
    #[test]
    fn stack_input_is_bounded_and_accepts_partial_utf8() {
        let input = vec![0xff; StackObservations::MAX_INPUT_BYTES + 1];
        let s = StackObservations::from_sample(&input);
        assert!(s.input_truncated && !s.main_thread_found);
    }
}
