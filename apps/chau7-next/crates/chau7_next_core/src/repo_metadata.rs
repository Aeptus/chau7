//! Repository metadata and the recent repositories list
//! (`Repository/RepoMetadata.swift`, `FeatureSettings.recordRecentRepo`).
//!
//! Metadata is `<repo>/.chau7/metadata.json` with the keys `description`,
//! `labels`, `favoriteFiles` and `updatedAt` (ISO 8601); empty fields are
//! left out. The repo's file belongs to the Swift app (which migrates it), so
//! Chau7 Next only reads it: its edits go to an overlay in its own data root
//! (`DataRoot::repo_metadata_overlay_file`), which wins over the repo's file
//! on read. A cleared record is kept in the overlay so it hides the repo's
//! values.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::data_root::DataRoot;

/// At most this many recent repositories.
pub const RECENT_REPOS_LIMIT: usize = 20;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub labels: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub favorite_files: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
}

impl RepoMetadata {
    pub fn is_empty(&self) -> bool {
        self.description.is_none() && self.labels.is_empty() && self.favorite_files.is_empty()
    }

    /// From the settings editor fields (`saveMetadata`): labels comma
    /// separated, favorite files one per line, blanks dropped.
    pub fn from_fields(description: &str, labels: &str, favorites: &str, now: String) -> Self {
        let description = description.trim();
        let split = |text: &str, sep: char| -> Vec<String> {
            text.split(sep)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        };
        Self {
            description: (!description.is_empty()).then(|| description.to_string()),
            labels: split(labels, ','),
            favorite_files: split(favorites, '\n'),
            updated_at: Some(now),
        }
    }
}

fn read(path: &Path) -> Option<RepoMetadata> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
}

/// `RepoMetadataStore.load`: Chau7 Next's overlay when there is one, else the
/// repo's own file; empty when missing or unreadable.
pub fn load(root: &DataRoot, repo_root: &Path) -> RepoMetadata {
    read(&root.repo_metadata_overlay_file(repo_root))
        .or_else(|| read(&DataRoot::repo_metadata_file(repo_root)))
        .unwrap_or_default()
}

/// `RepoMetadataStore.save`, into the overlay (never the repo): pretty JSON
/// with sorted keys, written atomically.
pub fn save(root: &DataRoot, repo_root: &Path, metadata: &RepoMetadata) -> std::io::Result<()> {
    let path = root.repo_metadata_overlay_file(repo_root);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // serde_json::Value objects keep keys sorted.
    let value = serde_json::to_value(metadata).map_err(std::io::Error::other)?;
    let text = serde_json::to_string_pretty(&value).map_err(std::io::Error::other)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(tmp, path)
}

/// `recordRecentRepo`: move `root` to the front, keep 20.
pub fn record_recent(list: &mut Vec<String>, root: &str) {
    list.retain(|r| r != root);
    list.insert(0, root.to_string());
    list.truncate(RECENT_REPOS_LIMIT);
}

pub fn load_recent(file: &Path) -> Vec<String> {
    std::fs::read_to_string(file)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

pub fn save_recent(file: &Path, list: &[String]) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let text = serde_json::to_string_pretty(list).map_err(std::io::Error::other)?;
    std::fs::write(file, text)
}

/// Last path component, for the list.
pub fn repo_name(root: &str) -> String {
    PathBuf::from(root)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| root.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_go_to_the_overlay_and_the_repo_file_is_only_read() {
        let home = std::env::temp_dir().join(format!("c7n-meta-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let root = DataRoot::with_home(home.clone(), true);
        let repo = home.join("repo");
        let repo_file = DataRoot::repo_metadata_file(&repo);
        std::fs::create_dir_all(repo_file.parent().unwrap()).unwrap();
        std::fs::write(&repo_file, r#"{"description":"From Swift","labels":["a"]}"#).unwrap();
        let before = std::fs::read(&repo_file).unwrap();
        assert_eq!(
            load(&root, &repo).description.as_deref(),
            Some("From Swift")
        );

        let edited = RepoMetadata::from_fields("Mine", "b", "", "t".into());
        save(&root, &repo, &edited).unwrap();
        assert_eq!(load(&root, &repo).description.as_deref(), Some("Mine"));
        assert_eq!(load(&root, &repo).labels, vec!["b"]);
        // Cleared in Chau7 Next: the repo's values stay hidden.
        save(&root, &repo, &RepoMetadata::default()).unwrap();
        assert!(load(&root, &repo).is_empty());
        assert_eq!(std::fs::read(&repo_file).unwrap(), before);
        assert!(
            root.repo_metadata_overlay_file(&repo)
                .starts_with(root.repo_overlays_dir())
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn fields_are_split_and_trimmed() {
        let m = RepoMetadata::from_fields(
            "  API server ",
            "backend, rust,, api ",
            "src/main.rs\n\n README.md \n",
            "2026-10-10T00:00:00Z".into(),
        );
        assert_eq!(m.description.as_deref(), Some("API server"));
        assert_eq!(m.labels, vec!["backend", "rust", "api"]);
        assert_eq!(m.favorite_files, vec!["src/main.rs", "README.md"]);
        assert!(RepoMetadata::from_fields(" ", "", "", "x".into()).is_empty());
    }

    #[test]
    fn json_omits_empty_fields_and_uses_swift_keys() {
        let m = RepoMetadata {
            favorite_files: vec!["a".into()],
            ..Default::default()
        };
        assert_eq!(
            serde_json::to_string(&m).unwrap(),
            r#"{"favoriteFiles":["a"]}"#
        );
    }

    #[test]
    fn save_load_round_trip() {
        let home =
            std::env::temp_dir().join(format!("chau7-next-repo-meta-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let root = DataRoot::with_home(home.clone(), true);
        let repo = home.join("r");
        let m = RepoMetadata::from_fields("d", "x", "", "2026-10-10T00:00:00Z".into());
        save(&root, &repo, &m).unwrap();
        assert_eq!(load(&root, &repo), m);
        assert!(!DataRoot::repo_metadata_file(&repo).exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn recent_list_moves_to_front_and_caps() {
        let mut list: Vec<String> = (0..20).map(|i| format!("/r{i}")).collect();
        record_recent(&mut list, "/r5");
        assert_eq!(list[0], "/r5");
        assert_eq!(list.len(), 20);
        record_recent(&mut list, "/new");
        assert_eq!(list[0], "/new");
        assert_eq!(list.len(), 20);
        assert!(!list.contains(&"/r19".to_string()));
    }
}
