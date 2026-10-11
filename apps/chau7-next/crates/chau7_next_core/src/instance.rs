//! Independent nonblocking application lock and honest launch continuity.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions, TryLockError},
    io::{self, Read},
    path::{Path, PathBuf},
};
use uuid::Uuid;
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Owner {
    pub pid: u32,
    pub launch_token: Uuid,
    pub acquired_at: DateTime<Utc>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Unknown,
    Clean,
    Abrupt,
}
impl Outcome {
    pub fn name(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Clean => "clean",
            Self::Abrupt => "abrupt",
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Marker {
    running: bool,
    build: String,
    started_at: DateTime<Utc>,
    launch_token: Uuid,
}
pub struct PreviousLaunch {
    pub outcome: Outcome,
    pub build: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
}
pub enum Acquisition {
    Acquired(InstanceGuard),
    AlreadyRunning(Option<Owner>),
}
pub struct InstanceGuard {
    _file: File,
    owner: Owner,
    continuity_path: PathBuf,
}
impl InstanceGuard {
    pub fn acquire(lock_path: &Path, continuity_path: PathBuf) -> io::Result<Acquisition> {
        fs::create_dir_all(
            lock_path
                .parent()
                .ok_or_else(|| io::Error::other("missing lock directory"))?,
        )?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options.open(lock_path)?;
        let owner_path = lock_path.with_extension("owner.json");
        match file.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => {
                return Ok(Acquisition::AlreadyRunning(read_bounded(&owner_path)));
            }
            Err(TryLockError::Error(error)) => return Err(error),
        }
        let owner = Owner {
            pid: std::process::id(),
            launch_token: Uuid::new_v4(),
            acquired_at: Utc::now(),
        };
        // Separate owner metadata stays readable on Windows while the lock is held.
        crate::incidents::atomic_write(&owner_path, &serde_json::to_vec(&owner)?)?;
        Ok(Acquisition::Acquired(Self {
            _file: file,
            owner,
            continuity_path,
        }))
    }
    pub fn owner(&self) -> &Owner {
        &self.owner
    }
    pub fn begin_launch(&self, build: &str) -> io::Result<PreviousLaunch> {
        let previous: Option<Marker> = read_bounded(&self.continuity_path);
        let outcome = match previous.as_ref().map(|m| m.running) {
            None => Outcome::Unknown,
            Some(false) => Outcome::Clean,
            Some(true) => Outcome::Abrupt,
        };
        let marker = Marker {
            running: true,
            build: build.chars().take(128).collect(),
            started_at: self.owner.acquired_at,
            launch_token: self.owner.launch_token,
        };
        crate::incidents::atomic_write(&self.continuity_path, &serde_json::to_vec(&marker)?)?;
        Ok(PreviousLaunch {
            outcome,
            build: previous.as_ref().map(|m| m.build.clone()),
            started_at: previous.map(|m| m.started_at),
        })
    }
    pub fn mark_clean(&self) -> io::Result<()> {
        let Some(mut marker): Option<Marker> = read_bounded(&self.continuity_path) else {
            return Err(io::Error::other("launch marker unavailable"));
        };
        if marker.launch_token != self.owner.launch_token {
            return Err(io::Error::other("launch marker belongs to another launch"));
        }
        marker.running = false;
        crate::incidents::atomic_write(&self.continuity_path, &serde_json::to_vec(&marker)?)
    }
}
fn read_bounded<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    let file = File::open(path).ok()?;
    if file.metadata().ok()?.len() > 4096 {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(4096).read_to_end(&mut bytes).ok()?;
    serde_json::from_slice(&bytes).ok()
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!("chau7-next-instance-{}", Uuid::new_v4()));
            fs::create_dir_all(&p).unwrap();
            Self(p)
        }
        fn acquire(&self) -> Acquisition {
            InstanceGuard::acquire(
                &self.0.join("app-instance.lock"),
                self.0.join("launch-continuity.json"),
            )
            .unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn guard(acquisition: Acquisition) -> InstanceGuard {
        match acquisition {
            Acquisition::Acquired(g) => g,
            _ => panic!("expected lock acquisition"),
        }
    }
    #[test]
    fn lock_retains_file_blocks_duplicate_and_releases_with_descriptor() {
        let f = Fixture::new();
        let first = guard(f.acquire());
        let token = first.owner().launch_token;
        match f.acquire() {
            Acquisition::AlreadyRunning(Some(owner)) => assert_eq!(owner.launch_token, token),
            _ => panic!("duplicate not blocked"),
        };
        drop(first);
        assert!(f.0.join("app-instance.lock").exists());
        let next = guard(f.acquire());
        assert_ne!(next.owner().launch_token, token);
    }
    #[test]
    fn unknown_clean_and_abrupt_outcomes_do_not_invent_a_crash() {
        let f = Fixture::new();
        let first = guard(f.acquire());
        assert_eq!(first.begin_launch("one").unwrap().outcome, Outcome::Unknown);
        first.mark_clean().unwrap();
        drop(first);
        let next = guard(f.acquire());
        let old = next.begin_launch("two").unwrap();
        assert_eq!(old.outcome, Outcome::Clean);
        assert_eq!(old.build.as_deref(), Some("one"));
        drop(next);
        let after = guard(f.acquire());
        assert_eq!(
            after.begin_launch("three").unwrap().outcome,
            Outcome::Abrupt
        );
    }
    #[test]
    fn profiles_are_independent_and_foreign_marker_is_not_cleared() {
        let a = Fixture::new();
        let b = Fixture::new();
        let ga = guard(a.acquire());
        let gb = guard(b.acquire());
        ga.begin_launch("a").unwrap();
        gb.begin_launch("b").unwrap();
        let foreign = fs::read(b.0.join("launch-continuity.json")).unwrap();
        fs::write(a.0.join("launch-continuity.json"), foreign.clone()).unwrap();
        assert!(ga.mark_clean().is_err());
        assert_eq!(
            fs::read(a.0.join("launch-continuity.json")).unwrap(),
            foreign
        );
    }
    #[test]
    fn corrupt_or_oversized_marker_is_unknown() {
        for text in [b"broken".to_vec(), vec![b'x'; 4097]] {
            let f = Fixture::new();
            fs::write(f.0.join("launch-continuity.json"), text).unwrap();
            let g = guard(f.acquire());
            assert_eq!(g.begin_launch("build").unwrap().outcome, Outcome::Unknown);
        }
    }
}
