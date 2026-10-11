//! Cheap Codex quota rollout discovery: cached file, today's directory, then a
//! slow fourteen-day fallback. This never opens or changes provider transcripts.
use chrono::{DateTime, Local, Utc};
use std::{
    path::{Path, PathBuf},
    time::SystemTime,
};
#[derive(Default)]
pub struct CodexQuotaLocator {
    cached: Option<PathBuf>,
    last_full_walk: Option<DateTime<Utc>>,
}
impl CodexQuotaLocator {
    pub fn find(&mut self, sessions: &Path, now: DateTime<Utc>) -> Option<PathBuf> {
        let mut best = self
            .cached
            .as_ref()
            .and_then(|p| modified(p).map(|at| (p.clone(), at)));
        let local = now.with_timezone(&Local);
        consider_directory(
            &sessions.join(local.format("%Y/%m/%d").to_string()),
            &mut best,
        );
        if best.is_none()
            || self
                .last_full_walk
                .is_none_or(|at| now.signed_duration_since(at).num_seconds() >= 600)
        {
            self.last_full_walk = Some(now);
            for days in 0..14 {
                let date = local - chrono::Duration::days(days);
                consider_directory(
                    &sessions.join(date.format("%Y/%m/%d").to_string()),
                    &mut best,
                );
            }
        }
        self.cached = best.map(|(path, _)| path);
        self.cached.clone()
    }
}
fn modified(path: &Path) -> Option<SystemTime> {
    path.metadata().ok()?.modified().ok()
}
fn consider_directory(dir: &Path, best: &mut Option<(PathBuf, SystemTime)>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "jsonl")
            || entry.file_name().to_string_lossy().starts_with('.')
        {
            continue;
        }
        let Some(at) = modified(&path) else {
            continue;
        };
        if best.as_ref().is_none_or(|(_, prior)| at > *prior) {
            *best = Some((path, at));
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn write(path: &Path, at: DateTime<Utc>) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"{}\n").unwrap();
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(at.into())
            .unwrap();
    }
    #[test]
    fn today_scan_detects_new_sessions_without_rewalking_history() {
        let root = std::env::temp_dir().join(format!("chau7-locator-{}", uuid::Uuid::new_v4()));
        let now = Utc::now();
        let local = now.with_timezone(&Local);
        let yesterday = root.join(
            (local - chrono::Duration::days(1))
                .format("%Y/%m/%d")
                .to_string(),
        );
        let old = yesterday.join("old.jsonl");
        write(&old, now);
        let mut locator = CodexQuotaLocator::default();
        assert_eq!(locator.find(&root, now), Some(old.clone()));
        let historic_new = yesterday.join("new.jsonl");
        write(&historic_new, now + chrono::Duration::seconds(10));
        assert_eq!(
            locator.find(&root, now + chrono::Duration::seconds(30)),
            Some(old)
        );
        assert_eq!(
            locator.find(&root, now + chrono::Duration::seconds(600)),
            Some(historic_new)
        );
        let today = root
            .join(local.format("%Y/%m/%d").to_string())
            .join("today.jsonl");
        write(&today, now + chrono::Duration::seconds(700));
        assert_eq!(
            locator.find(&root, now + chrono::Duration::seconds(630)),
            Some(today.clone())
        );
        std::fs::remove_file(&today).unwrap();
        assert!(
            locator
                .find(&root, now + chrono::Duration::seconds(660))
                .is_some()
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn empty_and_hidden_files_never_supply_quota_identity() {
        let root = std::env::temp_dir().join(format!("chau7-locator-{}", uuid::Uuid::new_v4()));
        let now = Utc::now();
        let mut locator = CodexQuotaLocator::default();
        assert!(locator.find(&root, now).is_none());
        let dir = root.join(now.with_timezone(&Local).format("%Y/%m/%d").to_string());
        write(&dir.join(".hidden.jsonl"), now);
        write(&dir.join("notes.txt"), now);
        assert!(locator.find(&root, now).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }
}
