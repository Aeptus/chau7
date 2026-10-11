//! Bounded local incident evidence and current Swift admission thresholds.
//! No terminal output or request body belongs in this store.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, VecDeque},
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub const MAX_LOG_BYTES: usize = 256 * 1024;
pub const MAX_ENTRIES: usize = 200;
const MAX_FIELD_BYTES: usize = 1024;
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    AppRecovery,
    MainThreadHang,
    MemoryPressure,
    ProxyRequestHighWater,
    RestorePayload,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Info,
    Warning,
    Critical,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Breadcrumb {
    pub schema_version: u8,
    pub id: Uuid,
    pub timestamp: DateTime<Utc>,
    pub kind: Kind,
    pub severity: Severity,
    pub message: String,
    pub metadata: BTreeMap<String, String>,
}
fn bounded(text: &str, max: usize) -> String {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}
impl Breadcrumb {
    pub fn new(
        at: DateTime<Utc>,
        kind: Kind,
        severity: Severity,
        message: &str,
        metadata: BTreeMap<String, String>,
    ) -> Self {
        Self {
            schema_version: 1,
            id: Uuid::new_v4(),
            timestamp: at,
            kind,
            severity,
            message: bounded(message, MAX_FIELD_BYTES),
            metadata: metadata
                .into_iter()
                .take(32)
                .map(|(k, v)| (bounded(&k, 128), bounded(&v, MAX_FIELD_BYTES)))
                .collect(),
        }
    }
}
#[derive(Default)]
pub struct Policy {
    restore: BTreeMap<String, String>,
    last_restore: Option<(DateTime<Utc>, u64)>,
    memory: BTreeMap<Severity, (DateTime<Utc>, u64)>,
    proxy_high_water: u64,
}
impl Policy {
    pub fn restore(
        &mut self,
        at: DateTime<Utc>,
        bytes: u64,
        mut metadata: BTreeMap<String, String>,
    ) -> Option<Breadcrumb> {
        metadata.insert("totalPayloadBytes".into(), bytes.to_string());
        self.restore = metadata.clone();
        if bytes < 1_000_000
            || self.last_restore.is_some_and(|(last, previous)| {
                (at - last).num_seconds() < 300 && bytes.abs_diff(previous) < 256 * 1024
            })
        {
            return None;
        }
        self.last_restore = Some((at, bytes));
        Some(Breadcrumb::new(
            at,
            Kind::RestorePayload,
            Severity::Warning,
            "Large restore payload observed during autosave",
            metadata,
        ))
    }
    pub fn memory(
        &mut self,
        at: DateTime<Utc>,
        severity: Severity,
        resident: u64,
        physical: u64,
        reclaimed: u64,
    ) -> Option<Breadcrumb> {
        if self.memory.get(&severity).is_some_and(|&(last, previous)| {
            (at - last).num_seconds() < 60 && resident.abs_diff(previous) < 256 * 1024 * 1024
        }) {
            return None;
        }
        self.memory.insert(severity, (at, resident));
        let mut metadata: BTreeMap<String, String> = self
            .restore
            .iter()
            .map(|(k, v)| (format!("restore.{k}"), v.clone()))
            .collect();
        metadata.extend([
            ("residentBytes".into(), resident.to_string()),
            ("physicalBytes".into(), physical.to_string()),
            (
                "proxyRequestHighWaterBytes".into(),
                self.proxy_high_water.to_string(),
            ),
        ]);
        if physical > 0 {
            metadata.insert(
                "residentPhysicalPercent".into(),
                ((u128::from(resident) * 100) / u128::from(physical)).to_string(),
            );
        }
        if reclaimed > 0 {
            metadata.insert("reclaimedBytes".into(), reclaimed.to_string());
        }
        Some(Breadcrumb::new(
            at,
            Kind::MemoryPressure,
            severity,
            if severity == Severity::Critical {
                "Critical memory pressure"
            } else {
                "Memory pressure warning"
            },
            metadata,
        ))
    }
    pub fn proxy(&mut self, at: DateTime<Utc>, bytes: u64) -> Option<Breadcrumb> {
        if bytes < 512 * 1024
            || bytes
                <= self
                    .proxy_high_water
                    .saturating_add((256 * 1024).max(self.proxy_high_water / 4))
        {
            return None;
        }
        self.proxy_high_water = bytes;
        Some(Breadcrumb::new(
            at,
            Kind::ProxyRequestHighWater,
            Severity::Info,
            "Large AI proxy request observed",
            BTreeMap::from([("requestBytes".into(), bytes.to_string())]),
        ))
    }
}
pub fn request_length(message: &str) -> Option<u64> {
    let tail = message.split_once("reqLen=")?.1;
    let digits = tail.bytes().take_while(u8::is_ascii_digit).count();
    (digits > 0).then(|| tail[..digits].parse().ok()).flatten()
}
/// Worker-owned store. Every file read and write has a strict byte budget.
pub struct Store {
    directory: PathBuf,
    entries: VecDeque<Breadcrumb>,
}
impl Store {
    pub fn open(directory: PathBuf) -> io::Result<Self> {
        fs::create_dir_all(&directory)?;
        let mut entries = VecDeque::new();
        if let Ok(mut file) = fs::File::open(directory.join("breadcrumbs.jsonl")) {
            let size = file.metadata()?.len();
            // Reject oversized legacy/corrupt files instead of loading them without a bound.
            if size <= MAX_LOG_BYTES as u64 {
                let mut text = String::new();
                file.by_ref()
                    .take(MAX_LOG_BYTES as u64)
                    .read_to_string(&mut text)?;
                for line in text.lines() {
                    if let Ok(record) = serde_json::from_str::<Breadcrumb>(line) {
                        if record.schema_version == 1 {
                            entries.push_back(Breadcrumb {
                                id: record.id,
                                ..Breadcrumb::new(
                                    record.timestamp,
                                    record.kind,
                                    record.severity,
                                    &record.message,
                                    record.metadata,
                                )
                            });
                        }
                        while entries.len() > MAX_ENTRIES {
                            entries.pop_front();
                        }
                    }
                }
            }
        }
        Ok(Self { directory, entries })
    }
    pub fn recent(&self, limit: usize) -> Vec<Breadcrumb> {
        self.entries
            .iter()
            .skip(self.entries.len().saturating_sub(limit))
            .cloned()
            .collect()
    }
    pub fn append(&mut self, record: Breadcrumb) -> io::Result<()> {
        // Public fields may have been changed after construction. Enforce
        // admission bounds again at the persistence boundary.
        let record = Breadcrumb {
            id: record.id,
            ..Breadcrumb::new(
                record.timestamp,
                record.kind,
                record.severity,
                &record.message,
                record.metadata,
            )
        };
        let latest = serde_json::to_vec(&record)?;
        self.entries.push_back(record);
        while self.entries.len() > MAX_ENTRIES {
            self.entries.pop_front();
        }
        let mut lines: Vec<Vec<u8>> = self
            .entries
            .iter()
            .map(serde_json::to_vec)
            .collect::<Result<_, _>>()?;
        let mut bytes = lines.iter().map(|line| line.len() + 1).sum::<usize>();
        while bytes > MAX_LOG_BYTES && !lines.is_empty() {
            bytes -= lines.remove(0).len() + 1;
            self.entries.pop_front();
        }
        let mut log = Vec::with_capacity(bytes);
        for line in lines {
            log.extend(line);
            log.push(b'\n');
        }
        atomic_write(&self.directory.join("breadcrumbs.jsonl"), &log)?;
        atomic_write(&self.directory.join("latest.json"), &latest)
    }
    pub fn recover_previous_critical(&mut self, now: DateTime<Utc>) -> io::Result<bool> {
        let Some(incident) = self
            .entries
            .iter()
            .rev()
            .find(|e| e.kind == Kind::MemoryPressure && e.severity == Severity::Critical)
            .cloned()
        else {
            return Ok(false);
        };
        let age = (now - incident.timestamp).num_seconds();
        if !(0..=86400).contains(&age) {
            return Ok(false);
        }
        let marker = self.directory.join("reported-critical-id");
        let previous = fs::File::open(&marker).ok().and_then(|f| {
            let mut bytes = Vec::new();
            f.take(128).read_to_end(&mut bytes).ok()?;
            String::from_utf8(bytes).ok()
        });
        if previous.as_deref() == Some(&incident.id.to_string()) {
            return Ok(false);
        }
        atomic_write(&marker, incident.id.to_string().as_bytes())?;
        self.append(Breadcrumb::new(
            now,
            Kind::AppRecovery,
            Severity::Info,
            "Previous critical memory-pressure incident surfaced at launch",
            BTreeMap::from([("incidentID".into(), incident.id.to_string())]),
        ))?;
        Ok(true)
    }
}
pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let pending = path.with_extension("pending");
    fs::write(&pending, bytes)?;
    #[cfg(not(target_os = "windows"))]
    {
        fs::rename(&pending, path)
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn MoveFileExW(from: *const u16, to: *const u16, flags: u32) -> i32;
        }
        let from: Vec<u16> = pending.as_os_str().encode_wide().chain(Some(0)).collect();
        let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        // SAFETY: both paths are stable NUL-terminated buffers for this synchronous call.
        if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), 1 | 8) } == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    struct TempDir(PathBuf);
    impl TempDir {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("chau7-next-incidents-test-{}", Uuid::new_v4()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp(1_790_000_000, 0).unwrap()
    }
    #[test]
    fn extracts_only_ascii_request_length() {
        assert_eq!(request_length("x reqLen=524288 z"), Some(524288));
        for line in [
            "missing",
            "reqLen=",
            "reqLen=-1",
            "reqLen=１２",
            "reqLen=18446744073709551616",
        ] {
            assert_eq!(request_length(line), None);
        }
    }
    #[test]
    fn high_water_requires_material_strict_jump() {
        let mut p = Policy::default();
        assert!(p.proxy(now(), 524288).is_some());
        assert!(p.proxy(now(), 524289).is_none());
        assert!(p.proxy(now(), 786432).is_none());
        assert!(p.proxy(now(), 786433).is_some());
        assert!(p.proxy(now(), 4 * 1024 * 1024).is_some());
        assert!(p.proxy(now(), 5 * 1024 * 1024).is_none());
        assert!(p.proxy(now(), 5 * 1024 * 1024 + 1).is_some());
    }
    #[test]
    fn restore_keeps_small_context_and_throttles_growth() {
        let mut p = Policy::default();
        assert!(
            p.restore(
                now(),
                42,
                BTreeMap::from([("paneCount".into(), "2".into())])
            )
            .is_none()
        );
        assert_eq!(
            p.memory(now(), Severity::Warning, 100, 200, 0)
                .unwrap()
                .metadata["restore.paneCount"],
            "2"
        );
        assert!(p.restore(now(), 1_000_000, BTreeMap::new()).is_some());
        assert!(p.restore(now(), 1_000_001, BTreeMap::new()).is_none());
        assert!(
            p.restore(
                now() + chrono::Duration::minutes(5),
                1_000_001,
                BTreeMap::new()
            )
            .is_some()
        );
        assert!(
            p.restore(
                now() + chrono::Duration::minutes(5),
                1_300_000,
                BTreeMap::new()
            )
            .is_some()
        );
    }
    #[test]
    fn memory_has_context_separate_severity_and_time_budget() {
        let mut p = Policy::default();
        p.proxy(now(), 600000);
        let first = p.memory(now(), Severity::Warning, 300, 600, 22).unwrap();
        assert_eq!(first.metadata["residentPhysicalPercent"], "50");
        assert_eq!(first.metadata["proxyRequestHighWaterBytes"], "600000");
        assert!(p.memory(now(), Severity::Warning, 301, 600, 0).is_none());
        assert!(p.memory(now(), Severity::Critical, 301, 600, 0).is_some());
        assert!(
            p.memory(now(), Severity::Warning, 300 + 256 * 1024 * 1024, 600, 0)
                .is_some()
        );
        assert!(
            p.memory(
                now() + chrono::Duration::seconds(60),
                Severity::Warning,
                300,
                600,
                0
            )
            .is_some()
        );
    }
    #[test]
    fn storage_is_bounded_unicode_safe_and_restart_deduplicated() {
        let directory = TempDir::new();
        let mut store = Store::open(directory.path().into()).unwrap();
        for _ in 0..220 {
            store
                .append(Breadcrumb::new(
                    now(),
                    Kind::MainThreadHang,
                    Severity::Warning,
                    &"é".repeat(5000),
                    (0..40)
                        .map(|i| (i.to_string(), "界".repeat(1000)))
                        .collect(),
                ))
                .unwrap();
        }
        assert!(store.entries.len() <= 200);
        assert!(
            fs::metadata(directory.path().join("breadcrumbs.jsonl"))
                .unwrap()
                .len()
                <= MAX_LOG_BYTES as u64
        );
        store
            .append(Breadcrumb::new(
                now(),
                Kind::MemoryPressure,
                Severity::Critical,
                "critical",
                BTreeMap::new(),
            ))
            .unwrap();
        assert!(store.recover_previous_critical(now()).unwrap());
        assert!(!store.recover_previous_critical(now()).unwrap());
        let mut reopened = Store::open(directory.path().into()).unwrap();
        assert!(!reopened.recover_previous_critical(now()).unwrap());
        assert!(
            reopened
                .recent(100)
                .iter()
                .any(|e| e.kind == Kind::AppRecovery)
        );
    }
    #[test]
    fn persistence_rebounds_mutated_public_fields() {
        let directory = TempDir::new();
        let mut store = Store::open(directory.path().into()).unwrap();
        let mut record = Breadcrumb::new(
            now(),
            Kind::MainThreadHang,
            Severity::Warning,
            "initial",
            BTreeMap::new(),
        );
        let id = record.id;
        record.message = "界".repeat(MAX_LOG_BYTES);
        record.metadata = (0..100)
            .map(|i| {
                (
                    format!("{i}{}", "界".repeat(200)),
                    "é".repeat(MAX_LOG_BYTES),
                )
            })
            .collect();
        store.append(record).unwrap();
        for name in ["breadcrumbs.jsonl", "latest.json"] {
            let bytes = fs::read(directory.path().join(name)).unwrap();
            assert!(bytes.len() <= MAX_LOG_BYTES);
            let persisted: Breadcrumb = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(persisted.id, id);
            assert!(persisted.message.len() <= 1024);
            assert!(persisted.metadata.len() <= 32);
        }
    }
    #[test]
    fn corrupt_and_oversized_inputs_are_bounded() {
        let directory = TempDir::new();
        fs::write(
            directory.path().join("breadcrumbs.jsonl"),
            vec![b'x'; MAX_LOG_BYTES + 1],
        )
        .unwrap();
        assert!(
            Store::open(directory.path().into())
                .unwrap()
                .recent(1)
                .is_empty()
        );
        fs::write(directory.path().join("breadcrumbs.jsonl"), b"invalid\n").unwrap();
        assert!(
            Store::open(directory.path().into())
                .unwrap()
                .recent(1)
                .is_empty()
        );
    }
    #[test]
    fn old_or_future_critical_does_not_surface() {
        for at in [
            now() - chrono::Duration::days(2),
            now() + chrono::Duration::days(1),
        ] {
            let d = TempDir::new();
            let mut s = Store::open(d.path().into()).unwrap();
            s.append(Breadcrumb::new(
                at,
                Kind::MemoryPressure,
                Severity::Critical,
                "x",
                BTreeMap::new(),
            ))
            .unwrap();
            assert!(!s.recover_previous_critical(now()).unwrap());
        }
    }
}
