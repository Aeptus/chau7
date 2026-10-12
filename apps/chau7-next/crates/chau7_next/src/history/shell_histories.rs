//! The per-tab shell-history producer and off-thread startup maintenance.
//! Namespace and identity are independent of pane analytics attribution.
use crate::session_store::SavedSession;
use chau7_next_core::{data_root::DataRoot, shell_histories};
use parking_lot::Mutex;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Instant;
use uuid::Uuid;

type OwnerKey = (PathBuf, Uuid);
static ACTIVE: OnceLock<Mutex<HashMap<OwnerKey, usize>>> = OnceLock::new();
fn active() -> &'static Mutex<HashMap<OwnerKey, usize>> {
    ACTIVE.get_or_init(|| Mutex::new(HashMap::new()))
}
/// A split registers the same stable owner independently; dropping one pane
/// cannot remove the protection held by another live pane in the tab.
pub struct Registration {
    key: OwnerKey,
}
impl Registration {
    fn new(root: &DataRoot, tab: Uuid) -> Self {
        let key = (root.config_dir().to_path_buf(), tab);
        *active().lock().entry(key.clone()).or_default() += 1;
        Self { key }
    }
}
impl Drop for Registration {
    fn drop(&mut self) {
        let mut state = active().lock();
        if let Some(count) = state.get_mut(&self.key) {
            *count -= 1;
            if *count == 0 {
                state.remove(&self.key);
            }
        }
    }
}
fn is_live(root: &DataRoot, tab: Uuid) -> bool {
    active()
        .lock()
        .contains_key(&(root.config_dir().to_path_buf(), tab))
}
/// Prepare before PTY creation. The marker is present even on failure: the
/// wrapper then leaves HISTFILE empty instead of falling back into shared data.
pub fn prepare_shell(
    root: &DataRoot,
    tab: Uuid,
    shell: &str,
) -> (Option<Registration>, Vec<(String, String)>) {
    if shell_histories::path(root, tab, shell).is_none() {
        return (None, Vec::new());
    }
    let owner = Registration::new(root, tab);
    let file = match shell_histories::prepare(root, tab, shell) {
        Ok(Some(file)) => file.to_string_lossy().into_owned(),
        Ok(None) => String::new(),
        Err(error) => {
            log::warn!("owned per-tab shell history unavailable: {error}");
            String::new()
        }
    };
    (
        Some(owner),
        vec![
            ("CHAU7_NEXT_OWNED_SHELL_HISTORY".into(), "1".into()),
            ("CHAU7_NEXT_SHELL_HISTORY_FILE".into(), file.clone()),
            ("HISTFILE".into(), file),
        ],
    )
}
pub fn prune_startup(root: &DataRoot, restored: Option<&SavedSession>, max_lines: usize) {
    let root = root.clone();
    let restored_ids: HashSet<_> = restored
        .into_iter()
        .flat_map(|s| &s.windows)
        .flat_map(|w| &w.tabs)
        .filter_map(|tab| tab.uuid)
        .collect();
    let result=std::thread::Builder::new().name("chau7-next-shell-history-prune".into()).spawn(move|| {
        let start=Instant::now();
        let mut protected=crate::session_store::restorable_tab_ids(&root);
        protected.extend(restored_ids);
        match shell_histories::prune(&root,&protected,max_lines,|tab|is_live(&root,tab)) {
            Ok(report)=>log::info!("shell history maintenance: trimmed={}, removed={}, protected={}, observed_closed_lines={}, failed_operations={}, deferred_entries={}, elapsed_ms={}",report.trimmed_files,report.removed_files,report.protected_files,report.retained_lines,report.failed_operations,report.deferred_entries,start.elapsed().as_millis()),
            Err(error)=>log::warn!("owned shell history maintenance unavailable: {error}"),
        }
    });
    if let Err(error) = result {
        log::warn!("shell history worker unavailable: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stable_tab_owner_and_split_lifetimes_are_distinct_from_profile_namespaces() {
        let home = std::env::temp_dir().join(format!("chau7-next-shell-owner-{}", Uuid::new_v4()));
        std::fs::create_dir(&home).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        let id = Uuid::new_v4();
        let (a, env_a) = prepare_shell(&root, id, "/bin/zsh");
        let (b, env_b) = prepare_shell(&root, id, "/bin/zsh");
        assert_eq!(env_a, env_b);
        assert!(is_live(&root, id));
        assert!(
            env_a
                .iter()
                .find(|(k, _)| k == "HISTFILE")
                .unwrap()
                .1
                .starts_with(root.config_dir().to_string_lossy().as_ref())
        );
        drop(a);
        assert!(is_live(&root, id));
        drop(b);
        assert!(!is_live(&root, id));
        let other = DataRoot::with_home(home.join("other"), true);
        assert!(!is_live(&other, id));
        std::fs::remove_dir_all(home).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn failed_owned_preparation_never_falls_back_to_a_foreign_history() {
        use std::os::unix::fs::symlink;
        let home = std::env::temp_dir().join(format!("chau7-next-shell-owner-{}", Uuid::new_v4()));
        std::fs::create_dir(&home).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        let foreign = home.join("foreign");
        std::fs::create_dir(&foreign).unwrap();
        symlink(&foreign, root.config_dir()).unwrap();
        let (owner, env) = prepare_shell(&root, Uuid::new_v4(), "/bin/bash");
        assert_eq!(
            env.iter()
                .find(|(k, _)| k == "CHAU7_NEXT_OWNED_SHELL_HISTORY")
                .unwrap()
                .1,
            "1"
        );
        assert!(
            env.iter()
                .find(|(k, _)| k == "HISTFILE")
                .unwrap()
                .1
                .is_empty()
        );
        assert_eq!(std::fs::read_dir(foreign).unwrap().count(), 0);
        drop(owner);
        std::fs::remove_dir_all(home).unwrap();
    }
}
