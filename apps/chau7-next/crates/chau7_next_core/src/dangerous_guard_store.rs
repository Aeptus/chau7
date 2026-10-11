//! Persistence of the command guard's lists (`dangerousGuard.allowList`,
//! `dangerousGuard.blockList` and `dangerousGuard.directoryAllowLists` in
//! Swift's UserDefaults) as one JSON file of Chau7 Next's own.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::command_risk::DangerousCommandGuard;

#[derive(Debug, Default, Serialize, Deserialize)]
struct GuardFile {
    #[serde(default)]
    allow: BTreeSet<String>,
    #[serde(default)]
    block: BTreeSet<String>,
    #[serde(default, rename = "directoryAllow")]
    directory_allow: BTreeMap<String, BTreeSet<String>>,
}

/// Copy the lists stored at `path` into `guard`. A missing or damaged file
/// leaves the guard's lists empty.
pub fn load_into(guard: &mut DangerousCommandGuard, path: &Path) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return;
    };
    let file: GuardFile = serde_json::from_str(&text).unwrap_or_default();
    guard.allow_list = file.allow.into_iter().collect();
    guard.block_list = file.block.into_iter().collect();
    for (dir, commands) in file.directory_allow {
        for command in commands {
            guard.add_to_directory_allow_list(&command, &dir);
        }
    }
}

/// Write the guard's lists (sorted, so the file diffs cleanly).
pub fn save(guard: &DangerousCommandGuard, path: &Path) -> std::io::Result<()> {
    let file = GuardFile {
        allow: guard.allow_list.iter().cloned().collect(),
        block: guard.block_list.iter().cloned().collect(),
        directory_allow: guard
            .directory_allow_lists()
            .iter()
            .map(|(dir, cmds)| (dir.clone(), cmds.iter().cloned().collect()))
            .collect(),
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let text = serde_json::to_string_pretty(&file).map_err(std::io::Error::other)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("chau7-guard-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn lists_round_trip() {
        let dir = temp("rt");
        let path = dir.join("g.json");
        let mut guard = DangerousCommandGuard::default();
        guard.add_to_allow_list("rm -rf build");
        guard.add_to_block_list("rm -rf /");
        guard.add_to_directory_allow_list("make clean", "/work/proj");
        save(&guard, &path).unwrap();

        let mut loaded = DangerousCommandGuard::default();
        load_into(&mut loaded, &path);
        assert_eq!(loaded.allow_list, guard.allow_list);
        assert_eq!(loaded.block_list, guard.block_list);
        assert_eq!(
            loaded.directory_allow_lists(),
            guard.directory_allow_lists()
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn missing_or_damaged_file_leaves_lists_empty() {
        let dir = temp("bad");
        let mut guard = DangerousCommandGuard::default();
        load_into(&mut guard, &dir.join("none.json"));
        assert!(guard.allow_list.is_empty());
        std::fs::write(dir.join("bad.json"), "not json").unwrap();
        load_into(&mut guard, &dir.join("bad.json"));
        assert!(guard.allow_list.is_empty() && guard.block_list.is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }
}
