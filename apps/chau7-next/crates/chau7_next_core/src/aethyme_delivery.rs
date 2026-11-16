//! Isolated current AethymeDelivery.swift contract, using broker advanced.
use serde::Deserialize;
/// Retry state follows the canonical repository; another repository succeeding
/// must neither clear this outage nor be held behind its backoff.
#[derive(Default)]
pub struct RetryState {
    pub backoff: Option<std::time::Instant>,
    pub incomplete_failures: [u32; 4],
}
#[derive(Default)]
pub struct RepositoryRetries {
    current: Option<String>,
    parked: std::collections::HashMap<String, RetryState>,
}
impl RepositoryRetries {
    pub fn select(&mut self, root: &str, active: &mut RetryState) {
        if self.current.as_deref() == Some(root) {
            return;
        }
        if let Some(previous) = self.current.replace(root.into()) {
            self.parked.insert(previous, std::mem::take(active));
        }
        *active = self.parked.remove(root).unwrap_or_default();
    }
    pub fn retain(&mut self, live: &[String]) {
        self.parked.retain(|root, _| live.contains(root));
    }
}

/// Idle-repository round skipping.
///
/// Every input that can make `watch pr list` or `deliveries claim` return
/// something new is either a write to the repository's broker database
/// (`<main checkout>/.aethyme/broker.db` in WAL mode) or one of three
/// time-driven transitions: a watch's `next_poll_at` coming due, a retried
/// delivery's backoff elapsing (capped at 300 s), or a claim lease expiring
/// (Chau7 claims for 120 s). A round may therefore be skipped while the
/// database is byte-for-byte untouched, as long as no time-driven transition
/// can be pending. Anything uncertain polls.
pub mod quiet {
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant, SystemTime};

    /// Hard upper bound between real rounds for a root, whatever the stamp
    /// says. It bounds the delay of any transition this model misses, such as
    /// a lease longer than [`SETTLED_AGE`] taken by a non-Chau7 worker.
    pub const QUIET_MAX: Duration = Duration::from_secs(300);
    /// A quiet round arms skipping only when the database was last written at
    /// least this long before the round's stamp. Aethyme's retry backoff caps
    /// at 300 s and Chau7's claim lease is 120 s, so after 300 s without a
    /// write no backed-off or leased item can still be waiting on the clock:
    /// an empty claim then proves only a write can produce a delivery. Ten
    /// seconds of slack absorbs clock and round-timing skew.
    pub const SETTLED_AGE: Duration = Duration::from_secs(310);
    /// Environment that redirects which database or Git directory the CLI
    /// child opens. When present, the file Chau7 would stat may not be the
    /// one the child reads, so skipping is disabled.
    const REDIRECTING_ENV: [&str; 4] = [
        "AETHYME_BROKER_DB",
        "AETHYME_GATE_BROKER_DATABASES",
        "GIT_DIR",
        "GIT_COMMON_DIR",
    ];

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct FileStamp {
        pub size: u64,
        pub modified_ns: i128,
        pub device: u64,
        pub inode: u64,
    }
    impl FileStamp {
        fn of(metadata: &std::fs::Metadata) -> Option<Self> {
            let modified = metadata.modified().ok()?;
            let modified_ns = modified
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()?
                .as_nanos()
                .try_into()
                .ok()?;
            #[cfg(unix)]
            let (device, inode) = {
                use std::os::unix::fs::MetadataExt;
                (metadata.dev(), metadata.ino())
            };
            #[cfg(not(unix))]
            let (device, inode) = (0, 0);
            Some(Self {
                size: metadata.len(),
                modified_ns,
                device,
                inode,
            })
        }
    }

    /// Change stamp of a WAL-mode SQLite database. An absent or empty `-wal`
    /// holds no frames, so both are recorded as `None`: committed data is then
    /// entirely in the main file, and a checkpoint that empties the WAL
    /// rewrites the main file first. Read-only CLI commands create and remove
    /// an empty `-wal` without writing, which must not look like a change.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct StoreStamp {
        pub database: FileStamp,
        pub wal: Option<FileStamp>,
    }
    impl StoreStamp {
        pub fn newest_modified_ns(&self) -> i128 {
            self.wal.map_or(self.database.modified_ns, |wal| {
                wal.modified_ns.max(self.database.modified_ns)
            })
        }
    }

    /// The broker database the CLI opens for a canonical repository root, or
    /// `None` when that cannot be established without running Git.
    pub fn broker_db_path(repository_root: &Path) -> Option<PathBuf> {
        if REDIRECTING_ENV
            .iter()
            .any(|name| std::env::var_os(name).is_some())
        {
            return None;
        }
        main_checkout(repository_root).map(|main| main.join(".aethyme/broker.db"))
    }

    /// Aethyme keeps broker state in the parent of the Git common directory.
    /// Only the standard layouts (`<root>/.git` directory, or a linked
    /// worktree whose `.git` file names a gitdir with a `commondir`) whose
    /// common directory is named `.git` are recognised.
    fn main_checkout(root: &Path) -> Option<PathBuf> {
        let dot_git = root.join(".git");
        let metadata = std::fs::symlink_metadata(&dot_git).ok()?;
        let common = if metadata.is_dir() {
            dot_git
        } else if metadata.is_file() {
            let text = std::fs::read_to_string(&dot_git).ok()?;
            let gitdir = root.join(text.strip_prefix("gitdir:")?.trim());
            let commondir = std::fs::read_to_string(gitdir.join("commondir")).ok()?;
            gitdir.join(commondir.trim())
        } else {
            return None;
        };
        let common = std::fs::canonicalize(common).ok()?;
        if common.file_name()? != ".git" {
            return None;
        }
        common.parent().map(Path::to_path_buf)
    }

    /// Stat the database and its `-wal` sibling; no process is spawned. Any
    /// error other than an absent `-wal` yields `None`, which means poll.
    pub fn store_stamp(database: &Path) -> Option<StoreStamp> {
        let main = FileStamp::of(&std::fs::metadata(database).ok()?)?;
        let mut wal_path = database.as_os_str().to_owned();
        wal_path.push("-wal");
        let wal = match std::fs::metadata(PathBuf::from(wal_path)) {
            Ok(metadata) if metadata.len() == 0 => None,
            Ok(metadata) => Some(FileStamp::of(&metadata)?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return None,
        };
        Some(StoreStamp {
            database: main,
            wal,
        })
    }

    /// What a completed round established about its root.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum RoundOutcome {
        /// The watch list was read, no watch was due, and a validated claim
        /// returned no delivery. `next_watch_due_ms` is the earliest
        /// `next_poll_at` among active watches.
        Quiet { next_watch_due_ms: Option<i64> },
        /// Anything else: a failure, a timeout, a due watch, a delivery.
        Active,
    }

    /// Evidence from the last real round that may justify skipping.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct QuietRound {
        pub stamp: StoreStamp,
        pub polled_at: Instant,
        pub next_watch_due_ms: Option<i64>,
    }
    impl QuietRound {
        /// `stamp` must be taken before the round's first command, so a write
        /// racing the round changes the stamp the next round compares.
        pub fn arm(
            stamp: Option<StoreStamp>,
            stamp_taken_at: SystemTime,
            polled_at: Instant,
            outcome: RoundOutcome,
        ) -> Option<Self> {
            let RoundOutcome::Quiet { next_watch_due_ms } = outcome else {
                return None;
            };
            let stamp = stamp?;
            let taken_ns: i128 = stamp_taken_at
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()?
                .as_nanos()
                .try_into()
                .ok()?;
            let settled = taken_ns
                .checked_sub(stamp.newest_modified_ns())
                .is_some_and(|age| age >= SETTLED_AGE.as_nanos() as i128);
            settled.then_some(Self {
                stamp,
                polled_at,
                next_watch_due_ms,
            })
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Decision {
        Skip,
        Poll(&'static str),
    }

    /// Pure skip decision. `previous` is `None` for a root never polled or
    /// whose last round was not an armed quiet round.
    pub fn decide(
        previous: Option<&QuietRound>,
        current: Option<&StoreStamp>,
        now: Instant,
        now_ms: i64,
    ) -> Decision {
        let Some(previous) = previous else {
            return Decision::Poll("no_quiet_round");
        };
        let Some(current) = current else {
            return Decision::Poll("stamp_unavailable");
        };
        if *current != previous.stamp {
            return Decision::Poll("store_changed");
        }
        if previous.next_watch_due_ms.is_some_and(|due| due <= now_ms) {
            return Decision::Poll("watch_due");
        }
        match now.checked_duration_since(previous.polled_at) {
            Some(elapsed) if elapsed < QUIET_MAX => Decision::Skip,
            _ => Decision::Poll("quiet_period_elapsed"),
        }
    }

    /// Per-root quiet evidence, kept beside the retry state.
    #[derive(Default)]
    pub struct QuietRoots {
        rounds: std::collections::HashMap<String, QuietRound>,
    }
    impl QuietRoots {
        pub fn decide(
            &self,
            root: &str,
            current: Option<&StoreStamp>,
            now: Instant,
            now_ms: i64,
        ) -> Decision {
            decide(self.rounds.get(root), current, now, now_ms)
        }
        pub fn observe(&mut self, root: &str, armed: Option<QuietRound>) {
            match armed {
                Some(round) => {
                    self.rounds.insert(root.into(), round);
                }
                None => {
                    self.rounds.remove(root);
                }
            }
        }
        pub fn retain(&mut self, live: &[String]) {
            self.rounds.retain(|root, _| live.contains(root));
        }
    }
}

/// Export only a static hint, never CLI stderr (which may contain user data).
pub fn capture_stderr_hint(stderr: &[u8]) -> &'static str {
    let text = String::from_utf8_lossy(&stderr[..stderr.len().min(8192)]).to_ascii_lowercase();
    if text.lines().any(|line| {
        line.contains("database is locked")
            || line.contains("database is busy")
            || (line.contains("lock")
                && (line.contains("waiting for") || line.contains("lock timeout")))
    }) {
        "lock_wait_reported"
    } else {
        "unclassified"
    }
}

pub const ADAPTER: &str = "chau7-next";
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub tab_id: uuid::Uuid,
    pub ai_session_id: String,
}
impl Target {
    pub fn parse(value: &str) -> Option<Self> {
        let rest = value.strip_prefix("chau7-next://tab/")?;
        if rest.contains('#') {
            return None;
        }
        let (tab, query) = rest.split_once('?')?;
        let tab_id = uuid::Uuid::parse_str(tab).ok()?;
        let mut session = None;
        for item in query.split('&') {
            let (key, value) = item.split_once('=')?;
            if key == "session" {
                if session.is_some() {
                    return None;
                }
                let decoded = decode(value)?;
                if decoded.trim().is_empty() || decoded.chars().any(char::is_control) {
                    return None;
                }
                session = Some(decoded);
            }
        }
        Some(Self {
            tab_id,
            ai_session_id: session?,
        })
    }
    pub fn opaque_value(&self) -> String {
        let mut encoded = String::new();
        for byte in self.ai_session_id.bytes() {
            if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
                encoded.push(byte as char);
            } else {
                use std::fmt::Write;
                let _ = write!(encoded, "%{byte:02X}");
            }
        }
        format!("chau7-next://tab/{}?session={encoded}", self.tab_id)
    }
}
fn decode(value: &str) -> Option<String> {
    let mut bytes = Vec::new();
    let mut input = value.bytes();
    while let Some(byte) = input.next() {
        bytes.push(if byte == b'%' {
            (input.next()? as char).to_digit(16)? as u8 * 16
                + (input.next()? as char).to_digit(16)? as u8
        } else {
            byte
        });
    }
    String::from_utf8(bytes).ok()
}
#[derive(Debug, Clone)]
pub struct TabSnapshot {
    pub tab_id: uuid::Uuid,
    pub ai_session_id: Option<String>,
    pub ai_provider: Option<String>,
    pub repository_root: Option<String>,
    pub status: String,
    pub is_at_prompt: bool,
    pub has_pending_input: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Readiness {
    Ready,
    Retry(&'static str),
    Failed(&'static str),
}
impl Readiness {
    pub fn outcome(&self) -> &'static str {
        match self {
            Self::Ready => "delivered",
            Self::Retry(_) => "retry",
            Self::Failed(_) => "failed",
        }
    }
    pub fn error_code(&self) -> Option<&'static str> {
        match self {
            Self::Ready => None,
            Self::Retry(code) | Self::Failed(code) => Some(code),
        }
    }
}
/// Repository strings have already been canonicalized off the UI thread.
pub fn evaluate(target: &Target, tab: Option<&TabSnapshot>, repository_root: &str) -> Readiness {
    let Some(tab) = tab else {
        return Readiness::Retry("target_tab_missing");
    };
    if tab.tab_id != target.tab_id {
        return Readiness::Failed("target_tab_mismatch");
    }
    if tab.ai_session_id.as_deref() != Some(&target.ai_session_id) {
        return Readiness::Failed("target_session_mismatch");
    }
    if tab.repository_root.as_deref() != Some(repository_root) {
        return Readiness::Failed("target_repository_mismatch");
    }
    if tab
        .ai_provider
        .as_deref()
        .is_none_or(|provider| provider.trim().is_empty())
    {
        return Readiness::Retry("target_agent_unavailable");
    }
    if !matches!(tab.status.as_str(), "idle" | "done") {
        return Readiness::Retry("target_tab_busy");
    }
    if !tab.is_at_prompt {
        return Readiness::Retry("target_not_at_prompt");
    }
    if tab.has_pending_input {
        return Readiness::Retry("target_has_pending_input");
    }
    Readiness::Ready
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Policy {
    Notify,
    Resume,
    ReviewAndPush,
}
#[derive(Debug, Deserialize)]
pub struct Watch {
    pub id: i64,
    pub status: String,
    pub next_poll_at: Option<i64>,
}
#[derive(Debug, Deserialize)]
pub struct ClaimReport {
    pub adapter: String,
    pub worker: String,
    pub delivery: Option<Envelope>,
}
#[derive(Debug, Deserialize)]
pub struct Envelope {
    pub item: Item,
    pub subscription: Subscription,
    pub watch: DeliveryWatch,
    pub batch: Batch,
    pub prompt: String,
}
#[derive(Debug, Deserialize)]
pub struct Item {
    pub id: i64,
    pub generation: i64,
}
#[derive(Debug, Deserialize)]
pub struct Subscription {
    pub id: i64,
    pub target: String,
    pub policy: Policy,
}
#[derive(Debug, Deserialize)]
pub struct DeliveryWatch {
    pub id: i64,
    pub canonical_repository: String,
    pub pr_number: i64,
    pub head_sha: String,
}
#[derive(Debug, Deserialize)]
pub struct Batch {
    pub id: i64,
    pub head_sha: String,
}
impl ClaimReport {
    pub fn validated(self, worker: &str) -> Result<Option<Envelope>, &'static str> {
        if self.adapter != ADAPTER || self.worker != worker {
            return Err("claim_worker_mismatch");
        }
        if let Some(e) = &self.delivery
            && (e.item.id <= 0
                || e.item.generation < 0
                || e.subscription.id <= 0
                || e.watch.id <= 0
                || e.batch.id <= 0
                || e.watch.pr_number <= 0
                || e.watch.canonical_repository.is_empty()
                || e.prompt.trim().is_empty()
                || e.prompt.contains('\0'))
        {
            return Err("invalid_delivery_envelope");
        }
        Ok(self.delivery)
    }
}
fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).into()).collect()
}
pub fn list_watches() -> Vec<String> {
    args(&["broker", "advanced", "watch", "pr", "list", "--json"])
}
pub fn poll_watch(id: i64) -> Vec<String> {
    args(&[
        "broker",
        "advanced",
        "watch",
        "pr",
        "poll",
        "--id",
        &id.to_string(),
        "--json",
    ])
}
pub fn claim(worker: &str) -> Vec<String> {
    args(&[
        "broker",
        "advanced",
        "deliveries",
        "claim",
        "--adapter",
        ADAPTER,
        "--worker",
        worker,
        "--seconds",
        "120",
        "--json",
    ])
}
pub fn complete(item: &Item, worker: &str, readiness: &Readiness) -> Vec<String> {
    let mut result = args(&[
        "broker",
        "advanced",
        "deliveries",
        "complete",
        "--id",
        &item.id.to_string(),
        "--worker",
        worker,
        "--generation",
        &item.generation.to_string(),
        "--outcome",
        readiness.outcome(),
    ]);
    if let Some(code) = readiness.error_code() {
        result.extend(args(&["--error-code", code]));
    }
    result.push("--json".into());
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    fn target() -> Target {
        Target {
            tab_id: uuid::Uuid::new_v4(),
            ai_session_id: "native/é +?&".into(),
        }
    }
    fn tab(t: &Target) -> TabSnapshot {
        TabSnapshot {
            tab_id: t.tab_id,
            ai_session_id: Some(t.ai_session_id.clone()),
            ai_provider: Some("codex".into()),
            repository_root: Some("/repo".into()),
            status: "done".into(),
            is_at_prompt: true,
            has_pending_input: false,
        }
    }
    #[test]
    fn repository_outages_are_isolated_and_retain_their_failure_budget() {
        let mut roots = RepositoryRetries::default();
        let mut active = RetryState::default();
        let until = std::time::Instant::now() + std::time::Duration::from_secs(30);
        roots.select("/fixture/a", &mut active);
        active.backoff = Some(until);
        active.incomplete_failures[2] = 4;
        roots.select("/fixture/b", &mut active);
        assert!(active.backoff.is_none());
        assert_eq!(active.incomplete_failures, [0; 4]);
        roots.select("/fixture/a", &mut active);
        assert_eq!(active.backoff, Some(until));
        assert_eq!(active.incomplete_failures[2], 4);
        roots.select("/fixture/b", &mut active);
        roots.retain(&["/fixture/b".into()]);
        roots.select("/fixture/a", &mut active);
        assert!(active.backoff.is_none());
    }
    mod quiet_rounds {
        use super::super::quiet::*;
        use std::time::{Duration, Instant, SystemTime};

        const NOW_MS: i64 = 1_800_000_000_000;
        fn stamp() -> StoreStamp {
            StoreStamp {
                database: FileStamp {
                    size: 4096,
                    modified_ns: 1_000_000_000_000_000_000,
                    device: 1,
                    inode: 2,
                },
                wal: None,
            }
        }
        fn settled_at(stamp: &StoreStamp) -> SystemTime {
            SystemTime::UNIX_EPOCH
                + Duration::from_nanos(stamp.newest_modified_ns() as u64)
                + SETTLED_AGE
        }
        fn armed(polled_at: Instant, next_watch_due_ms: Option<i64>) -> QuietRound {
            let s = stamp();
            QuietRound::arm(
                Some(s),
                settled_at(&s),
                polled_at,
                RoundOutcome::Quiet { next_watch_due_ms },
            )
            .expect("settled quiet round arms")
        }

        #[test]
        fn unchanged_stamp_skips() {
            let polled = Instant::now();
            let round = armed(polled, Some(NOW_MS + 60_000));
            assert_eq!(
                decide(
                    Some(&round),
                    Some(&stamp()),
                    polled + Duration::from_secs(30),
                    NOW_MS
                ),
                Decision::Skip
            );
        }

        #[test]
        fn changed_size_mtime_inode_or_wal_polls() {
            let polled = Instant::now();
            let round = armed(polled, None);
            let later = polled + Duration::from_secs(30);
            let mut changes = Vec::new();
            let mut s = stamp();
            s.database.size += 1;
            changes.push(s);
            let mut s = stamp();
            s.database.modified_ns += 1;
            changes.push(s);
            let mut s = stamp();
            s.database.inode += 1;
            changes.push(s);
            let mut s = stamp();
            s.wal = Some(FileStamp {
                size: 32,
                ..s.database
            });
            changes.push(s);
            for changed in changes {
                assert_eq!(
                    decide(Some(&round), Some(&changed), later, NOW_MS),
                    Decision::Poll("store_changed")
                );
            }
        }

        #[test]
        fn due_watch_polls() {
            let polled = Instant::now();
            let round = armed(polled, Some(NOW_MS));
            assert_eq!(
                decide(
                    Some(&round),
                    Some(&stamp()),
                    polled + Duration::from_secs(30),
                    NOW_MS
                ),
                Decision::Poll("watch_due")
            );
        }

        #[test]
        fn quiet_period_exceeded_polls() {
            let polled = Instant::now();
            let round = armed(polled, None);
            assert_eq!(
                decide(Some(&round), Some(&stamp()), polled + QUIET_MAX, NOW_MS),
                Decision::Poll("quiet_period_elapsed")
            );
            assert_eq!(
                decide(
                    Some(&round),
                    Some(&stamp()),
                    polled + QUIET_MAX - Duration::from_secs(1),
                    NOW_MS
                ),
                Decision::Skip
            );
        }

        #[test]
        fn stat_failure_polls() {
            let polled = Instant::now();
            let round = armed(polled, None);
            assert_eq!(
                decide(Some(&round), None, polled + Duration::from_secs(30), NOW_MS),
                Decision::Poll("stamp_unavailable")
            );
            assert!(
                store_stamp(&std::env::temp_dir().join(format!(
                    "chau7-next-missing-{}/broker.db",
                    uuid::Uuid::new_v4()
                )))
                .is_none()
            );
        }

        #[test]
        fn previous_round_failed_or_first_round_polls() {
            let s = stamp();
            let polled = Instant::now();
            assert_eq!(
                QuietRound::arm(Some(s), settled_at(&s), polled, RoundOutcome::Active),
                None
            );
            let mut roots = QuietRoots::default();
            assert_eq!(
                roots.decide("/repo", Some(&s), polled, NOW_MS),
                Decision::Poll("no_quiet_round")
            );
            roots.observe("/repo", Some(armed(polled, None)));
            let later = polled + Duration::from_secs(30);
            assert_eq!(
                roots.decide("/repo", Some(&s), later, NOW_MS),
                Decision::Skip
            );
            roots.observe("/repo", None);
            assert_eq!(
                roots.decide("/repo", Some(&s), later, NOW_MS),
                Decision::Poll("no_quiet_round")
            );
            roots.observe("/repo", Some(armed(polled, None)));
            roots.retain(&[]);
            assert_eq!(
                roots.decide("/repo", Some(&s), later, NOW_MS),
                Decision::Poll("no_quiet_round")
            );
        }

        #[test]
        fn recently_written_or_unstatted_store_does_not_arm() {
            let s = stamp();
            let polled = Instant::now();
            let quiet = RoundOutcome::Quiet {
                next_watch_due_ms: None,
            };
            let recent = settled_at(&s) - Duration::from_secs(1);
            assert_eq!(QuietRound::arm(Some(s), recent, polled, quiet), None);
            assert_eq!(QuietRound::arm(None, settled_at(&s), polled, quiet), None);
            // A future modification time (clock skew) is never settled.
            assert_eq!(
                QuietRound::arm(Some(s), SystemTime::UNIX_EPOCH, polled, quiet),
                None
            );
        }

        #[test]
        fn stamp_ignores_empty_wal_and_resolves_worktree_main_checkout() {
            let base = std::env::temp_dir()
                .join(format!("chau7-next-quiet-fixture-{}", uuid::Uuid::new_v4()));
            let main = base.join("main");
            let linked = base.join("linked");
            let gitdir = main.join(".git/worktrees/linked");
            std::fs::create_dir_all(&gitdir).unwrap();
            std::fs::create_dir_all(main.join(".aethyme")).unwrap();
            std::fs::create_dir_all(&linked).unwrap();
            std::fs::write(gitdir.join("commondir"), "../..\n").unwrap();
            std::fs::write(
                linked.join(".git"),
                format!("gitdir: {}\n", gitdir.display()),
            )
            .unwrap();
            let main = std::fs::canonicalize(&main).unwrap();
            let database = main.join(".aethyme/broker.db");
            std::fs::write(&database, b"db").unwrap();
            if std::env::var_os("AETHYME_BROKER_DB").is_none()
                && std::env::var_os("AETHYME_GATE_BROKER_DATABASES").is_none()
                && std::env::var_os("GIT_DIR").is_none()
                && std::env::var_os("GIT_COMMON_DIR").is_none()
            {
                assert_eq!(broker_db_path(&linked), Some(database.clone()));
                assert_eq!(broker_db_path(&main), Some(database.clone()));
            }
            let without_wal = store_stamp(&database).unwrap();
            assert_eq!(without_wal.wal, None);
            let wal = main.join(".aethyme/broker.db-wal");
            std::fs::write(&wal, b"").unwrap();
            assert_eq!(store_stamp(&database), Some(without_wal));
            std::fs::write(&wal, b"frame").unwrap();
            let with_frames = store_stamp(&database).unwrap();
            assert_ne!(with_frames, without_wal);
            assert_eq!(with_frames.wal.unwrap().size, 5);
            std::fs::remove_dir_all(&base).unwrap();
        }
    }
    #[test]
    fn stderr_hints_are_bounded_and_do_not_export_cli_text() {
        assert_eq!(
            capture_stderr_hint(b"waiting for repository coordination lock /private/example"),
            "lock_wait_reported"
        );
        assert_eq!(
            capture_stderr_hint(b"database is locked"),
            "lock_wait_reported"
        );
        assert_eq!(
            capture_stderr_hint(b"clock updated, secret token omitted"),
            "unclassified"
        );
        let mut bytes = vec![b'x'; 8192];
        bytes.extend_from_slice(b"database is locked");
        assert_eq!(capture_stderr_hint(&bytes), "unclassified");
    }
    #[test]
    fn own_target_round_trip_and_swift_is_rejected() {
        let t = target();
        assert_eq!(Target::parse(&t.opaque_value()), Some(t.clone()));
        for v in [
            t.opaque_value().replacen("chau7-next:", "chau7:", 1),
            format!("{}&session=other", t.opaque_value()),
            format!("chau7-next://tab/{}?session=%0A", t.tab_id),
            format!("chau7-next://tab/{}?session=%GG", t.tab_id),
        ] {
            assert!(Target::parse(&v).is_none());
        }
    }
    #[test]
    fn exact_recipient_and_readiness_are_required() {
        let t = target();
        let mut s = tab(&t);
        assert_eq!(
            evaluate(&t, None, "/repo"),
            Readiness::Retry("target_tab_missing")
        );
        assert_eq!(evaluate(&t, Some(&s), "/repo"), Readiness::Ready);
        s.has_pending_input = true;
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Retry("target_has_pending_input")
        );
        s.has_pending_input = false;
        s.is_at_prompt = false;
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Retry("target_not_at_prompt")
        );
        s.is_at_prompt = true;
        s.status = "approval_required".into();
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Retry("target_tab_busy")
        );
        s.status = "idle".into();
        s.ai_provider = None;
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Retry("target_agent_unavailable")
        );
        s.ai_provider = Some("claude".into());
        assert_eq!(
            evaluate(&t, Some(&s), "/other"),
            Readiness::Failed("target_repository_mismatch")
        );
        s.ai_session_id = Some("other".into());
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Failed("target_session_mismatch")
        );
        s.tab_id = uuid::Uuid::new_v4();
        assert_eq!(
            evaluate(&t, Some(&s), "/repo"),
            Readiness::Failed("target_tab_mismatch")
        );
    }
    #[test]
    fn completion_preserves_fencing_and_exact_argv() {
        assert_eq!(
            complete(
                &Item {
                    id: 7,
                    generation: 11
                },
                "chau7-next-42",
                &Readiness::Retry("target_tab_busy")
            ),
            args(&[
                "broker",
                "advanced",
                "deliveries",
                "complete",
                "--id",
                "7",
                "--worker",
                "chau7-next-42",
                "--generation",
                "11",
                "--outcome",
                "retry",
                "--error-code",
                "target_tab_busy",
                "--json"
            ])
        );
        assert!(
            claim("worker")
                .windows(2)
                .any(|args| args == ["--adapter", "chau7-next"])
        );
        assert!(list_watches().starts_with(&args(&["broker", "advanced", "watch"])));
    }
    #[test]
    fn incomplete_and_wrong_owner_claims_are_not_accepted() {
        assert!(
            serde_json::from_str::<ClaimReport>(
                r#"{"adapter":"chau7-next","worker":"worker","delivery":{} }"#
            )
            .is_err()
        );
        assert!(
            ClaimReport {
                adapter: "chau7".into(),
                worker: "worker".into(),
                delivery: None
            }
            .validated("worker")
            .is_err()
        );
        assert!(
            ClaimReport {
                adapter: ADAPTER.into(),
                worker: "other".into(),
                delivery: None
            }
            .validated("worker")
            .is_err()
        );
        assert!(
            ClaimReport {
                adapter: ADAPTER.into(),
                worker: "worker".into(),
                delivery: None
            }
            .validated("worker")
            .unwrap()
            .is_none()
        );
    }
}
