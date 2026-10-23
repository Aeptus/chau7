//! Snippet model and on-disk storage.
//!
//! Port of the data half of `Snippets/SnippetManager.swift`: the `Snippet`
//! JSON format (one file per snippet, `<id>.json`), the three sources (User
//! stored as `global`, Profile stored as `default`, and the current git repo),
//! merging with the OVERRIDDEN rule, quick-select letters, token and input
//! variable replacement, and the create / update / delete / copy / import /
//! export operations. No UI and no clock: callers pass the time in.
//!
//! Layout:
//!
//! | Source | Folder |
//! |---|---|
//! | User | `<data root>/snippets/global/` |
//! | Profile | `<data root>/snippets/default/` |
//! | Repo | `<git root>/<repo snippet path>/` (default `.chau7/snippets`), read only |
//! | Repo edits | `<data root>/repo-overlays/<repo key>/snippets/` |
//!
//! A repo may still hold the pre-split single file `.chau7/snippets.json`.
//! It is read (ids that already have a file in the folder win). The repo's
//! files belong to the Swift app, which migrates them (DUAL-SHIP phase 1), so
//! Chau7 Next never writes them: creating, editing or pinning a repo snippet
//! writes it to the repo's overlay folder, whose files win over the repo's,
//! and deleting one records its id in the overlay's `.deleted.json`, which
//! hides it.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use chrono::{DateTime, NaiveDateTime, SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::snippet_parsing::{self, Placeholder};

pub use crate::data_root::DEFAULT_REPO_SNIPPET_PATH;
use crate::data_root::DataRoot;

// ---------------------------------------------------------------------------
// Source
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SnippetSource {
    /// Shown as "User", stored as `global`.
    Global,
    Profile,
    Repo,
}

impl SnippetSource {
    pub const ALL: [SnippetSource; 3] = [Self::Global, Self::Profile, Self::Repo];

    /// Stored name (`global`, `profile`, `repo`).
    pub fn raw(self) -> &'static str {
        match self {
            Self::Global => "global",
            Self::Profile => "profile",
            Self::Repo => "repo",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Global => "User",
            Self::Profile => "Profile",
            Self::Repo => "Repo",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Self::Global => "Available everywhere",
            Self::Profile => "Profile-specific",
            Self::Repo => "Repository-specific",
        }
    }

    /// Higher wins when two sources hold the same id.
    pub fn priority(self) -> u8 {
        match self {
            Self::Repo => 3,
            Self::Profile => 2,
            Self::Global => 1,
        }
    }
}

// ---------------------------------------------------------------------------
// Snippet
// ---------------------------------------------------------------------------

/// Dates are written as `2025-01-14T12:30:45Z` (Swift `.iso8601`) and read as
/// ISO 8601 with or without fractional seconds, or as seconds since 2001-01-01
/// (files written by old Swift builds).
mod snippet_date {
    use super::*;
    use serde::{Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match date {
            Some(d) => s.serialize_str(&d.to_rfc3339_opts(SecondsFormat::Secs, true)),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            Text(String),
            Number(f64),
        }
        Ok(match Option::<Raw>::deserialize(d)? {
            Some(Raw::Text(text)) => DateTime::parse_from_rfc3339(&text)
                .ok()
                .map(|d| d.with_timezone(&Utc)),
            Some(Raw::Number(secs)) => {
                // Apple reference date: 2001-01-01T00:00:00Z.
                DateTime::from_timestamp(978_307_200 + secs.floor() as i64, 0)
            }
            None => None,
        })
    }
}

/// One snippet file. Fields are declared in alphabetical order so the JSON
/// keys come out sorted, like Swift's clean encoder.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Snippet {
    pub body: String,
    #[serde(
        rename = "createdAt",
        default,
        skip_serializing_if = "Option::is_none",
        with = "snippet_date"
    )]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    pub id: String,
    #[serde(rename = "isPinned", default, skip_serializing_if = "is_false")]
    pub is_pinned: bool,
    /// Quick-select letter (a-z) for the picker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(default, skip_serializing_if = "shells_empty")]
    pub shells: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    pub title: String,
    #[serde(
        rename = "updatedAt",
        default,
        skip_serializing_if = "Option::is_none",
        with = "snippet_date"
    )]
    pub updated_at: Option<DateTime<Utc>>,
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn shells_empty(value: &Option<Vec<String>>) -> bool {
    value.as_ref().is_none_or(|v| v.is_empty())
}

impl Snippet {
    pub fn new(id: impl Into<String>, title: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            body: body.into(),
            created_at: None,
            folder: None,
            id: id.into(),
            is_pinned: false,
            key: None,
            shells: None,
            tags: Vec::new(),
            title: title.into(),
            updated_at: None,
        }
    }

    /// The quick-select key if it is a single letter a-z (files can be edited
    /// by hand, so the raw value may be anything).
    pub fn validated_key(&self) -> Option<char> {
        let key = self.key.as_deref()?.trim().to_lowercase();
        let mut chars = key.chars();
        let first = chars.next()?;
        (chars.next().is_none() && first.is_ascii_lowercase()).then_some(first)
    }
}

/// `{ "version": 1, "snippets": [...] }`, the single-file format and the
/// import / export format.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnippetFile {
    pub version: u32,
    pub snippets: Vec<Snippet>,
}

/// Pretty-printed JSON with sorted keys, empty fields left out.
pub fn encode_snippet(snippet: &Snippet) -> String {
    serde_json::to_string_pretty(snippet).unwrap_or_default()
}

/// Text of a single-file export (`{version, snippets}`).
pub fn export_json(snippets: &[Snippet]) -> String {
    let file = SnippetFile {
        version: 1,
        snippets: snippets.to_vec(),
    };
    serde_json::to_string_pretty(&file).unwrap_or_default()
}

/// Parse a `{version, snippets}` file or a bare array of snippets.
pub fn parse_snippet_text(text: &str) -> Result<Vec<Snippet>, String> {
    match serde_json::from_str::<SnippetFile>(text) {
        Ok(file) => Ok(file.snippets),
        Err(first) => serde_json::from_str::<Vec<Snippet>>(text).map_err(|_| first.to_string()),
    }
}

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct SnippetEntry {
    pub snippet: Snippet,
    pub source: SnippetSource,
    pub source_path: PathBuf,
    /// Another source holds the same id with higher priority.
    pub is_overridden: bool,
    pub repo_root: Option<PathBuf>,
    /// The snippet only exists in the pre-split `.chau7/snippets.json`.
    pub from_legacy_repo_file: bool,
}

impl SnippetEntry {
    /// Unique across sources: `global::id`.
    pub fn entry_id(&self) -> String {
        format!("{}::{}", self.source.raw(), self.snippet.id)
    }
}

/// Where each source lives.
#[derive(Debug, Clone)]
pub struct SnippetPaths {
    pub global: PathBuf,
    pub profile: PathBuf,
    /// Relative to the git root; empty means the default.
    pub repo_relative: String,
    /// Chau7 Next's per-repo overlays (`DataRoot::repo_overlays_dir`).
    pub overlays: PathBuf,
}

/// Ids of repo snippets deleted in Chau7 Next, in the overlay folder.
const TOMBSTONES: &str = ".deleted.json";

impl SnippetPaths {
    /// The repo's own snippet folder (read only).
    pub fn repo_dir(&self, root: &Path) -> PathBuf {
        repo_snippets_dir(root, &self.repo_relative)
    }

    /// Where Chau7 Next writes a repo's snippets (its overlay).
    pub fn repo_write_dir(&self, root: &Path) -> PathBuf {
        self.overlays
            .join(crate::data_root::repo_overlay_key(root))
            .join("snippets")
    }

    /// Folder a source is written to. `repo_root` is needed for
    /// [`SnippetSource::Repo`] (its overlay, never the repo).
    pub fn dir_for(&self, source: SnippetSource, repo_root: Option<&Path>) -> Option<PathBuf> {
        match source {
            SnippetSource::Global => Some(self.global.clone()),
            SnippetSource::Profile => Some(self.profile.clone()),
            SnippetSource::Repo => repo_root.map(|r| self.repo_write_dir(r)),
        }
    }
}

/// `<root>/<relative>`; an empty path means the default, a trailing `.json`
/// (old setting values) is dropped.
pub fn repo_snippets_dir(root: &Path, relative: &str) -> PathBuf {
    let mut relative = relative.trim();
    if relative.is_empty() {
        relative = DEFAULT_REPO_SNIPPET_PATH;
    }
    let relative = relative.strip_suffix(".json").unwrap_or(relative);
    root.join(relative)
}

/// The protected folder (Downloads, Desktop, Documents, Library, and the
/// system folders) that contains `path`, if any. Reading inside these makes
/// macOS ask for permission, so repo detection can be switched off for them.
pub fn protected_root(path: &Path, home: &Path) -> Option<PathBuf> {
    let roots = [
        home.join("Downloads"),
        home.join("Desktop"),
        home.join("Documents"),
        home.join("Library"),
        PathBuf::from("/Applications"),
        PathBuf::from("/System"),
        PathBuf::from("/Library"),
    ];
    roots.into_iter().find(|root| path.starts_with(root))
}

/// The pre-split single file of a repo.
pub fn legacy_repo_file(root: &Path) -> PathBuf {
    DataRoot::repo_snippets_file(root)
}

fn valid_file_id(id: &str) -> bool {
    !id.is_empty()
        && id != "."
        && id != ".."
        && !id.contains(['/', '\\', '\0'])
        && !id.starts_with('.')
}

/// Snippets in `<dir>/*.json`. Files that do not parse are skipped.
pub fn load_dir(dir: &Path) -> Vec<Snippet> {
    let Ok(read) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = read
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.extension().is_some_and(|e| e == "json")
                && p.file_name()
                    .is_some_and(|n| !n.to_string_lossy().starts_with('.'))
        })
        .collect();
    files.sort();
    files
        .iter()
        .filter_map(|path| {
            let text = std::fs::read_to_string(path).ok()?;
            match serde_json::from_str::<Snippet>(&text) {
                Ok(s) => Some(s),
                Err(error) => {
                    log::warn!("Could not decode snippet {}: {error}", path.display());
                    None
                }
            }
        })
        .collect()
}

fn tombstones(dir: &Path) -> BTreeSet<String> {
    std::fs::read_to_string(dir.join(TOMBSTONES))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn set_tombstone(dir: &Path, id: &str, deleted: bool) -> std::io::Result<()> {
    let mut ids = tombstones(dir);
    let changed = if deleted {
        ids.insert(id.to_string())
    } else {
        ids.remove(id)
    };
    if !changed {
        return Ok(());
    }
    std::fs::create_dir_all(dir)?;
    let text = serde_json::to_string_pretty(&ids).map_err(std::io::Error::other)?;
    let temp = dir.join(".deleted.json.tmp");
    std::fs::write(&temp, text)?;
    std::fs::rename(temp, dir.join(TOMBSTONES))
}

/// Remove a repo snippet in Chau7 Next: drop its overlay file and hide the
/// repo's copy (the repo itself is not changed).
fn delete_repo_snippet(paths: &SnippetPaths, root: &Path, id: &str) {
    let dir = paths.repo_write_dir(root);
    delete_snippet_file(&dir, id);
    if valid_file_id(id)
        && let Err(err) = set_tombstone(&dir, id, true)
    {
        log::warn!("snippets: could not hide {id}: {err}");
    }
}

/// Remove an entry's file from `source` (a repo snippet through its overlay).
fn remove_from(paths: &SnippetPaths, source: SnippetSource, repo_root: Option<&Path>, id: &str) {
    match (source, repo_root) {
        (SnippetSource::Repo, Some(root)) => delete_repo_snippet(paths, root, id),
        _ => {
            if let Some(dir) = paths.dir_for(source, repo_root) {
                delete_snippet_file(&dir, id);
            }
        }
    }
}

/// Write `<dir>/<id>.json` (via a temporary file, so a crash never leaves half
/// a snippet). A hidden (deleted) id in an overlay folder shows again.
pub fn save_snippet(dir: &Path, snippet: &Snippet) -> std::io::Result<()> {
    if !valid_file_id(&snippet.id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("invalid snippet id: {}", snippet.id),
        ));
    }
    std::fs::create_dir_all(dir)?;
    let target = dir.join(format!("{}.json", snippet.id));
    let temp = dir.join(format!(".{}.json.tmp", snippet.id));
    std::fs::write(&temp, encode_snippet(snippet))?;
    std::fs::rename(&temp, &target)?;
    if dir.join(TOMBSTONES).exists() {
        set_tombstone(dir, &snippet.id, false)?;
    }
    Ok(())
}

pub fn delete_snippet_file(dir: &Path, id: &str) {
    if valid_file_id(id) {
        let _ = std::fs::remove_file(dir.join(format!("{id}.json")));
    }
}

/// Snippets of a single-file `{version, snippets}` or bare-array file.
pub fn load_legacy_file(path: &Path) -> Vec<Snippet> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| parse_snippet_text(&t).ok())
        .unwrap_or_default()
}

/// Split a single-file store into one file per snippet. Writes every file
/// first, then (when `delete_legacy`) removes the legacy file. An empty legacy
/// file is just removed. Returns how many snippets were written.
pub fn migrate_legacy_file(legacy: &Path, target_dir: &Path, delete_legacy: bool) -> usize {
    if !legacy.is_file() {
        return 0;
    }
    let snippets = load_legacy_file(legacy);
    if snippets.is_empty() {
        if delete_legacy {
            let _ = std::fs::remove_file(legacy);
        }
        return 0;
    }
    let mut written = 0;
    for snippet in &snippets {
        if save_snippet(target_dir, snippet).is_ok() {
            written += 1;
        }
    }
    if delete_legacy && written == snippets.len() {
        let _ = std::fs::remove_file(legacy);
    }
    written
}

/// Rewrite every snippet file of `dir` with the clean encoder.
pub fn rewrite_clean(dir: &Path) -> usize {
    let snippets = load_dir(dir);
    for snippet in &snippets {
        let _ = save_snippet(dir, snippet);
    }
    snippets.len()
}

/// Snippets of a repo: Chau7 Next's overlay, then the repo's folder, then
/// ids that only exist in the old file, minus the ids deleted in Chau7 Next.
/// Returns `(snippet, from_legacy_file)`.
pub fn load_repo(paths: &SnippetPaths, root: &Path) -> Vec<(Snippet, bool)> {
    let overlay = paths.repo_write_dir(root);
    let deleted = tombstones(&overlay);
    let mut out: Vec<(Snippet, bool)> = Vec::new();
    let mut known: HashSet<String> = HashSet::new();
    for snippet in load_dir(&overlay)
        .into_iter()
        .chain(load_dir(&paths.repo_dir(root)))
    {
        if known.insert(snippet.id.clone()) {
            out.push((snippet, false));
        }
    }
    for snippet in load_legacy_file(&legacy_repo_file(root)) {
        if known.insert(snippet.id.clone()) {
            out.push((snippet, true));
        }
    }
    out.retain(|(s, _)| !deleted.contains(&s.id));
    out
}

/// Entries for the three sources, sorted: pinned first, then Repo, Profile,
/// User, then title A to Z.
pub fn merge_entries(
    paths: &SnippetPaths,
    global: Vec<Snippet>,
    profile: Vec<Snippet>,
    repo: Vec<(Snippet, bool)>,
    repo_root: Option<&Path>,
) -> Vec<SnippetEntry> {
    let mut highest: HashMap<String, SnippetSource> = HashMap::new();
    let mut register = |snippets: &mut dyn Iterator<Item = &Snippet>, source: SnippetSource| {
        for snippet in snippets {
            let better = highest
                .get(&snippet.id)
                .is_none_or(|current| source.priority() > current.priority());
            if better {
                highest.insert(snippet.id.clone(), source);
            }
        }
    };
    register(&mut global.iter(), SnippetSource::Global);
    register(&mut profile.iter(), SnippetSource::Profile);
    if repo_root.is_some() {
        register(&mut repo.iter().map(|(s, _)| s), SnippetSource::Repo);
    }

    let mut entries = Vec::new();
    for snippet in global {
        entries.push(SnippetEntry {
            source_path: paths.global.join(format!("{}.json", snippet.id)),
            is_overridden: highest.get(&snippet.id) != Some(&SnippetSource::Global),
            snippet,
            source: SnippetSource::Global,
            repo_root: None,
            from_legacy_repo_file: false,
        });
    }
    for snippet in profile {
        entries.push(SnippetEntry {
            source_path: paths.profile.join(format!("{}.json", snippet.id)),
            is_overridden: highest.get(&snippet.id) != Some(&SnippetSource::Profile),
            snippet,
            source: SnippetSource::Profile,
            repo_root: None,
            from_legacy_repo_file: false,
        });
    }
    if let Some(root) = repo_root {
        let dir = paths.repo_dir(root);
        let overlay = paths.repo_write_dir(root);
        for (snippet, legacy) in repo {
            let edited = overlay.join(format!("{}.json", snippet.id));
            entries.push(SnippetEntry {
                source_path: if legacy {
                    legacy_repo_file(root)
                } else if edited.exists() {
                    edited
                } else {
                    dir.join(format!("{}.json", snippet.id))
                },
                is_overridden: highest.get(&snippet.id) != Some(&SnippetSource::Repo),
                snippet,
                source: SnippetSource::Repo,
                repo_root: Some(root.to_path_buf()),
                from_legacy_repo_file: legacy,
            });
        }
    }
    entries.sort_by(|a, b| {
        b.snippet
            .is_pinned
            .cmp(&a.snippet.is_pinned)
            .then(b.source.priority().cmp(&a.source.priority()))
            .then_with(|| {
                a.snippet
                    .title
                    .to_lowercase()
                    .cmp(&b.snippet.title.to_lowercase())
            })
    });
    entries
}

/// Case-insensitive substring search over title, body, tags and folder.
pub fn filter_entries<'a>(entries: &'a [SnippetEntry], query: &str) -> Vec<&'a SnippetEntry> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return entries.iter().collect();
    }
    entries
        .iter()
        .filter(|e| {
            let s = &e.snippet;
            s.title.to_lowercase().contains(&query)
                || s.body.to_lowercase().contains(&query)
                || s.tags.iter().any(|t| t.to_lowercase().contains(&query))
                || s.folder
                    .as_ref()
                    .is_some_and(|f| f.to_lowercase().contains(&query))
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Quick-select letters
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeyMap {
    /// Entry id to its letter.
    pub snippet_keys: HashMap<String, char>,
    /// Letter to the index in the list the map was built for.
    pub key_to_index: HashMap<char, usize>,
    /// Letters claimed by more than one snippet (nobody gets them).
    pub conflicting: HashSet<char>,
}

/// A snippet's own letter wins; two claims on one letter conflict and neither
/// gets it; the rest take free letters in order.
pub fn build_key_map(entries: &[&SnippetEntry]) -> KeyMap {
    let mut map = KeyMap::default();
    let mut claims: HashMap<char, Vec<usize>> = HashMap::new();
    for (index, entry) in entries.iter().enumerate() {
        if let Some(key) = entry.snippet.validated_key() {
            claims.entry(key).or_default().push(index);
        }
    }
    let mut used: HashSet<char> = HashSet::new();
    for (key, group) in &claims {
        if group.len() > 1 {
            map.conflicting.insert(*key);
        } else {
            let index = group[0];
            map.snippet_keys.insert(entries[index].entry_id(), *key);
            map.key_to_index.insert(*key, index);
            used.insert(*key);
        }
    }
    let mut available: Vec<char> = ('a'..='z')
        .filter(|c| !used.contains(c) && !map.conflicting.contains(c))
        .collect();
    available.reverse();
    for (index, entry) in entries.iter().enumerate() {
        let id = entry.entry_id();
        if map.snippet_keys.contains_key(&id) {
            continue;
        }
        if entry
            .snippet
            .validated_key()
            .is_some_and(|k| map.conflicting.contains(&k))
        {
            continue;
        }
        if let Some(letter) = available.pop() {
            map.snippet_keys.insert(id, letter);
            map.key_to_index.insert(letter, index);
        }
    }
    map
}

// ---------------------------------------------------------------------------
// Draft and CRUD
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct SnippetDraft {
    pub id: String,
    pub title: String,
    pub body: String,
    pub tags_text: String,
    pub folder: String,
    pub shells_text: String,
    pub key: String,
    pub source: SnippetSource,
    pub repo_path: String,
}

impl Default for SnippetDraft {
    fn default() -> Self {
        Self {
            id: String::new(),
            title: String::new(),
            body: String::new(),
            tags_text: String::new(),
            folder: String::new(),
            shells_text: String::new(),
            key: String::new(),
            source: SnippetSource::Global,
            repo_path: String::new(),
        }
    }
}

impl SnippetDraft {
    pub fn from_entry(entry: &SnippetEntry) -> Self {
        let s = &entry.snippet;
        Self {
            id: s.id.clone(),
            title: s.title.clone(),
            body: s.body.clone(),
            tags_text: s.tags.join(", "),
            folder: s.folder.clone().unwrap_or_default(),
            shells_text: s.shells.clone().unwrap_or_default().join(", "),
            key: s.key.clone().unwrap_or_default(),
            source: entry.source,
            repo_path: entry
                .repo_root
                .as_ref()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default(),
        }
    }
}

/// Trim, lowercase, first character, a-z only.
pub fn normalize_key(input: &str) -> Option<String> {
    let first = input.trim().to_lowercase().chars().next()?;
    first.is_ascii_lowercase().then(|| first.to_string())
}

/// `slug-xxxxxx` from a title and a 6 character suffix.
pub fn make_snippet_id(title: &str, suffix: &str) -> String {
    let mut base = String::new();
    let mut last_dash = true;
    for c in title.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            base.push(c);
            last_dash = false;
        } else if !last_dash {
            base.push('-');
            last_dash = true;
        }
    }
    let base = base.trim_matches('-');
    let base = if base.is_empty() { "snippet" } else { base };
    format!("{base}-{suffix}")
}

fn random_suffix() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..6].to_uppercase()
}

fn dir_for_draft(
    paths: &SnippetPaths,
    source: SnippetSource,
    repo_path: &str,
    active_repo: Option<&Path>,
) -> Option<PathBuf> {
    let repo = repo_path.trim();
    let root = if repo.is_empty() {
        active_repo
    } else {
        Some(Path::new(repo))
    };
    paths.dir_for(source, root)
}

fn snippet_from_draft(draft: &SnippetDraft, id: String) -> Snippet {
    Snippet {
        body: draft.body.clone(),
        created_at: None,
        folder: (!draft.folder.is_empty()).then(|| draft.folder.clone()),
        id,
        is_pinned: false,
        key: normalize_key(&draft.key),
        shells: Some(snippet_parsing::parse_csv(&draft.shells_text)),
        tags: snippet_parsing::parse_csv(&draft.tags_text),
        title: draft.title.clone(),
        updated_at: None,
    }
}

/// Create a snippet from a draft; returns the written snippet.
pub fn create_snippet(
    paths: &SnippetPaths,
    draft: &SnippetDraft,
    active_repo: Option<&Path>,
    now: DateTime<Utc>,
) -> std::io::Result<Snippet> {
    let dir = dir_for_draft(paths, draft.source, &draft.repo_path, active_repo)
        .ok_or_else(|| std::io::Error::other("no repository for a repo snippet"))?;
    let id = if draft.id.is_empty() {
        make_snippet_id(&draft.title, &random_suffix())
    } else {
        draft.id.clone()
    };
    let mut snippet = snippet_from_draft(draft, id);
    snippet.created_at = Some(now);
    snippet.updated_at = Some(now);
    save_snippet(&dir, &snippet)?;
    Ok(snippet)
}

/// Apply a draft to an existing entry. A changed id or location moves the
/// file (old one deleted, new one written, created date and pin kept).
pub fn update_snippet(
    paths: &SnippetPaths,
    entry: &SnippetEntry,
    draft: &SnippetDraft,
    active_repo: Option<&Path>,
    now: DateTime<Utc>,
) -> std::io::Result<Snippet> {
    let new_dir = dir_for_draft(paths, draft.source, &draft.repo_path, active_repo)
        .ok_or_else(|| std::io::Error::other("no repository for a repo snippet"))?;
    let id = if draft.id.is_empty() {
        entry.snippet.id.clone()
    } else {
        draft.id.clone()
    };
    let mut updated = snippet_from_draft(draft, id.clone());
    updated.is_pinned = entry.snippet.is_pinned;
    updated.created_at = entry.snippet.created_at.or(Some(now));
    updated.updated_at = Some(now);

    let old_repo = entry
        .repo_root
        .as_ref()
        .map(|p| p.to_string_lossy().trim().to_string())
        .unwrap_or_default();
    let same_repo = entry.source != SnippetSource::Repo
        || draft.source != SnippetSource::Repo
        || old_repo == draft.repo_path.trim();
    // Write the new file first, so a hidden old id never hides the new one.
    save_snippet(&new_dir, &updated)?;
    let moved = !(entry.source == draft.source && same_repo);
    if moved || id != entry.snippet.id {
        remove_from(
            paths,
            entry.source,
            entry.repo_root.as_deref(),
            &entry.snippet.id,
        );
    }
    Ok(updated)
}

/// Delete an entry's file. A repo snippet (folder or old single file) is
/// hidden through the overlay; the repo is not changed.
pub fn delete_snippet(paths: &SnippetPaths, entry: &SnippetEntry) {
    remove_from(
        paths,
        entry.source,
        entry.repo_root.as_deref(),
        &entry.snippet.id,
    );
}

/// Copy an entry to another source. A new id is made when the file exists.
pub fn duplicate_snippet(
    paths: &SnippetPaths,
    entry: &SnippetEntry,
    target: SnippetSource,
    repo_root: Option<&Path>,
    now: DateTime<Utc>,
) -> std::io::Result<Snippet> {
    let dir = paths
        .dir_for(target, repo_root)
        .ok_or_else(|| std::io::Error::other("no repository for a repo snippet"))?;
    let mut copy = entry.snippet.clone();
    copy.created_at = Some(now);
    copy.updated_at = Some(now);
    if dir.join(format!("{}.json", copy.id)).exists() {
        copy.id = make_snippet_id(&copy.title, &random_suffix());
    }
    save_snippet(&dir, &copy)?;
    Ok(copy)
}

pub fn toggle_pin(
    paths: &SnippetPaths,
    entry: &SnippetEntry,
    now: DateTime<Utc>,
) -> std::io::Result<()> {
    // A repo snippet is written to the overlay, where the pin survives.
    let dir = paths
        .dir_for(entry.source, entry.repo_root.as_deref())
        .ok_or_else(|| std::io::Error::other("no repository"))?;
    let mut snippet = entry.snippet.clone();
    snippet.is_pinned = !snippet.is_pinned;
    snippet.updated_at = Some(now);
    save_snippet(&dir, &snippet)
}

/// Import snippets from pasted JSON into User or Profile, like the Swift
/// Import sheet (each snippet becomes a new one with its id kept). Returns the
/// number imported.
pub fn import_snippets(
    paths: &SnippetPaths,
    text: &str,
    target: SnippetSource,
    now: DateTime<Utc>,
) -> Result<usize, String> {
    let snippets = parse_snippet_text(text)?;
    let mut count = 0;
    for snippet in snippets {
        let draft = SnippetDraft {
            id: snippet.id.clone(),
            title: snippet.title.clone(),
            body: snippet.body.clone(),
            tags_text: snippet.tags.join(", "),
            folder: snippet.folder.clone().unwrap_or_default(),
            shells_text: snippet.shells.clone().unwrap_or_default().join(", "),
            key: snippet.key.clone().unwrap_or_default(),
            source: target,
            repo_path: String::new(),
        };
        create_snippet(paths, &draft, None, now).map_err(|e| e.to_string())?;
        count += 1;
    }
    Ok(count)
}

// ---------------------------------------------------------------------------
// Insertion: tokens, placeholders, input variables
// ---------------------------------------------------------------------------

/// Values for `${cwd}`, `${home}`, `${date}`, `${time}` and `${clip}`.
pub struct TokenContext<'a> {
    pub cwd: &'a str,
    pub home: &'a str,
    /// Local time.
    pub now: NaiveDateTime,
    /// Called only when the text contains `${clip}`.
    pub clipboard: &'a dyn Fn() -> String,
}

/// The current UTC time, for created and updated dates.
pub fn now_utc() -> DateTime<Utc> {
    Utc::now()
}

/// The current local time, for [`TokenContext::now`].
pub fn local_now() -> NaiveDateTime {
    chrono::Local::now().naive_local()
}

/// Replace `${cwd}`, `${home}`, `${date}`, `${time}`, `${clip}` and
/// `${env:VAR}` in one pass over `input`. Substituted values are inert: a
/// clipboard or directory holding `${env:SECRET}` is inserted as written.
pub fn replace_tokens(input: &str, ctx: &TokenContext, env: &dyn Fn(&str) -> String) -> String {
    let (marked, values) = mark_tokens(input, ctx, env);
    unmark(&marked, &values)
}

/// First marker character: the start of Supplementary Private Use Area-A.
/// Each token value stands as one marker char while placeholders are
/// expanded, so nothing reads inside a value.
const MARKER_BASE: u32 = 0xF0000;
/// Area-A holds U+F0000..=U+FFFFD.
const MARKER_COUNT: u32 = 0xFFFE;

fn marker_index(c: char) -> Option<usize> {
    let code = c as u32;
    (MARKER_BASE..MARKER_BASE + MARKER_COUNT)
        .contains(&code)
        .then(|| (code - MARKER_BASE) as usize)
}

/// `input` with each token replaced by a marker char standing for its value
/// in the returned list. Marker-range characters already in `input` become
/// markers for themselves, so [`unmark`] gives them back unchanged.
fn mark_tokens(
    input: &str,
    ctx: &TokenContext,
    env: &dyn Fn(&str) -> String,
) -> (String, Vec<String>) {
    let mut out = String::with_capacity(input.len());
    let mut values: Vec<String> = Vec::new();
    let mut clip: Option<String> = None;
    fn push_value(out: &mut String, values: &mut Vec<String>, value: String) {
        let index = values.len() as u32;
        if index < MARKER_COUNT {
            out.push(char::from_u32(MARKER_BASE + index).expect("private use char"));
            values.push(value);
        }
        // Past 65534 tokens the rest expand to nothing rather than to text
        // that later passes could read.
    }
    let mut rest = input;
    while !rest.is_empty() {
        if let Some((len, value)) = token_at(rest, ctx, env, &mut clip) {
            push_value(&mut out, &mut values, value);
            rest = &rest[len..];
            continue;
        }
        let c = rest.chars().next().expect("non-empty");
        if marker_index(c).is_some() {
            push_value(&mut out, &mut values, c.to_string());
        } else {
            out.push(c);
        }
        rest = &rest[c.len_utf8()..];
    }
    (out, values)
}

/// The token at the start of `text`: its byte length and its value.
fn token_at(
    text: &str,
    ctx: &TokenContext,
    env: &dyn Fn(&str) -> String,
    clip: &mut Option<String>,
) -> Option<(usize, String)> {
    let body = text.strip_prefix("${")?;
    let fixed = |name: &str| body.starts_with(name) && body[name.len()..].starts_with('}');
    let token_len = |name: &str| 2 + name.len() + 1;
    if fixed("cwd") {
        return Some((token_len("cwd"), ctx.cwd.to_string()));
    }
    if fixed("home") {
        return Some((token_len("home"), ctx.home.to_string()));
    }
    if fixed("date") {
        return Some((token_len("date"), ctx.now.format("%Y-%m-%d").to_string()));
    }
    if fixed("time") {
        return Some((token_len("time"), ctx.now.format("%H:%M:%S").to_string()));
    }
    if fixed("clip") {
        // Read at most once, and only when the text uses it.
        let value = clip.get_or_insert_with(|| (ctx.clipboard)()).clone();
        return Some((token_len("clip"), value));
    }
    // `${env:NAME}`, NAME in [A-Za-z0-9_]+ (`replace_env_tokens_with`).
    let name_part = body.strip_prefix("env:")?;
    let name_len = name_part
        .bytes()
        .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_')
        .count();
    (name_len > 0 && name_part[name_len..].starts_with('}')).then(|| {
        let name = &name_part[..name_len];
        (token_len("env:") + name_len, env(name))
    })
}

/// `text` with every marker char replaced by its value.
fn unmark(text: &str, values: &[String]) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match marker_index(c).and_then(|i| values.get(i)) {
            Some(value) => out.push_str(value),
            None => out.push(c),
        }
    }
    out
}

/// Char offset in the unmarked text of each char offset in `text` (one
/// more entry than `text` has chars, for the end).
fn unmarked_offsets(text: &str, values: &[String]) -> Vec<usize> {
    let mut offsets = Vec::with_capacity(text.len() + 1);
    let mut at = 0;
    for c in text.chars() {
        offsets.push(at);
        at += match marker_index(c).and_then(|i| values.get(i)) {
            Some(value) => value.chars().count(),
            None => 1,
        };
    }
    offsets.push(at);
    offsets
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Insertion {
    pub text: String,
    pub placeholders: Vec<Placeholder>,
    /// Where the cursor ends (`${0}` or the end), in chars.
    pub final_cursor_offset: usize,
}

/// Text to insert plus its tab stops. Paste mode, or placeholders turned off,
/// leaves `${1:x}` as written and has no tab stops.
pub fn prepare_insertion(
    body: &str,
    ctx: &TokenContext,
    env: &dyn Fn(&str) -> String,
    paste_mode: bool,
    placeholders_enabled: bool,
) -> Insertion {
    // Tab stops are read from the snippet only: token values (clipboard,
    // directory, environment) stay markers until the very end.
    let (marked, values) = mark_tokens(body, ctx, env);
    if paste_mode || !placeholders_enabled {
        let text = unmark(&marked, &values);
        let len = text.chars().count();
        return Insertion {
            text,
            placeholders: Vec::new(),
            final_cursor_offset: len,
        };
    }
    let expanded = snippet_parsing::expand_placeholders(&marked);
    let offsets = unmarked_offsets(&expanded.text, &values);
    let at = |offset: usize| offsets[offset.min(offsets.len() - 1)];
    let placeholders = expanded
        .placeholders
        .iter()
        .map(|p| {
            let start = at(p.start);
            Placeholder::new(p.index, start, at(p.start + p.length) - start)
        })
        .collect();
    let final_offset = at(expanded
        .final_cursor_offset
        .unwrap_or_else(|| expanded.text.chars().count()));
    Insertion {
        text: unmark(&expanded.text, &values),
        placeholders,
        final_cursor_offset: final_offset,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputType {
    Text,
    SingleSelect,
    MultiSelect,
}

/// A prompted `${input:...}` or `${multiselect:...}` variable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputVariable {
    pub name: String,
    pub default_value: String,
    pub value: String,
    pub input_type: InputType,
    pub options: Vec<String>,
    pub selected: BTreeSet<String>,
}

impl InputVariable {
    fn text(name: &str, default_value: &str) -> Self {
        Self {
            name: name.to_string(),
            default_value: default_value.to_string(),
            value: default_value.to_string(),
            input_type: InputType::Text,
            options: Vec::new(),
            selected: BTreeSet::new(),
        }
    }

    fn picker(name: &str, options: Vec<String>, input_type: InputType) -> Self {
        let first = if input_type == InputType::SingleSelect {
            options.first().cloned().unwrap_or_default()
        } else {
            String::new()
        };
        Self {
            name: name.to_string(),
            default_value: first.clone(),
            value: first,
            input_type,
            options,
            selected: BTreeSet::new(),
        }
    }
}

fn input_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\$\{input:([^:}]+)(?::([^}]*))?\}").expect("valid regex"))
}

fn multiselect_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\$\{multiselect:([^:}]+):([^}]+)\}").expect("valid regex"))
}

fn split_options(text: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    text.split('|')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && seen.insert(s.clone()))
        .collect()
}

/// Variables in order of first occurrence (multiselect ones first, like
/// Swift): `${input:name}`, `${input:name:default}`, `${input:name:a|b|c}`
/// (dropdown) and `${multiselect:name:a|b|c}` (checkboxes).
pub fn parse_input_variables(text: &str) -> Vec<InputVariable> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for caps in multiselect_regex().captures_iter(text) {
        let name = caps[1].to_string();
        if !seen.insert(name.clone()) {
            continue;
        }
        let options = split_options(&caps[2]);
        if options.is_empty() {
            continue;
        }
        out.push(InputVariable::picker(
            &name,
            options,
            InputType::MultiSelect,
        ));
    }
    for caps in input_regex().captures_iter(text) {
        let name = caps[1].to_string();
        if !seen.insert(name.clone()) {
            continue;
        }
        match caps.get(2) {
            Some(value) => {
                let value = value.as_str();
                if value.contains('|') {
                    let options = split_options(value);
                    if options.is_empty() {
                        out.push(InputVariable::text(&name, value));
                    } else {
                        out.push(InputVariable::picker(
                            &name,
                            options,
                            InputType::SingleSelect,
                        ));
                    }
                } else {
                    out.push(InputVariable::text(&name, value));
                }
            }
            None => out.push(InputVariable::text(&name, "")),
        }
    }
    out
}

pub fn has_input_variables(body: &str) -> bool {
    input_regex().is_match(body) || multiselect_regex().is_match(body)
}

/// Replace every occurrence of each variable with its value (multi-select
/// values are sorted and joined by spaces).
pub fn replace_input_variables(text: &str, variables: &[InputVariable]) -> String {
    let mut result = text.to_string();
    for variable in variables {
        let value = match variable.input_type {
            InputType::Text | InputType::SingleSelect => variable.value.clone(),
            InputType::MultiSelect => variable
                .selected
                .iter()
                .cloned()
                .collect::<Vec<_>>()
                .join(" "),
        };
        let name = regex::escape(&variable.name);
        let patterns = [
            format!(r"\$\{{input:{name}:[^}}]*\}}"),
            format!(r"\$\{{input:{name}\}}"),
            format!(r"\$\{{multiselect:{name}:[^}}]*\}}"),
        ];
        for pattern in patterns {
            if let Ok(re) = Regex::new(&pattern) {
                result = re
                    .replace_all(&result, regex::NoExpand(value.as_str()))
                    .into_owned();
            }
        }
    }
    result
}

// ---------------------------------------------------------------------------
// Tab-stop navigation
// ---------------------------------------------------------------------------

/// State after inserting a snippet with tab stops. `advance` returns the
/// cursor movement to send (positive = right) and whether navigation goes on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Navigation {
    pub placeholders: Vec<Placeholder>,
    pub current: usize,
    pub cursor_offset: usize,
    pub final_offset: usize,
}

impl Navigation {
    /// After the text was typed (cursor at its end): the state plus the first
    /// move, to placeholder 1. `None` when there is nothing to navigate or the
    /// text has non-ASCII characters (cursor arithmetic would be wrong).
    pub fn start(insertion: &Insertion) -> Option<(Self, i64)> {
        if insertion.placeholders.is_empty() || !insertion.text.is_ascii() {
            return None;
        }
        let mut nav = Self {
            placeholders: insertion.placeholders.clone(),
            current: 0,
            cursor_offset: insertion.text.chars().count(),
            final_offset: insertion.final_cursor_offset,
        };
        let target = nav.placeholders[0].start;
        let delta = nav.move_to(target);
        Some((nav, delta))
    }

    fn move_to(&mut self, target: usize) -> i64 {
        let delta = target as i64 - self.cursor_offset as i64;
        self.cursor_offset = target;
        delta
    }

    /// Tab (or Shift+Tab when `backward`). Returns the horizontal move and
    /// whether navigation is still active.
    pub fn advance(&mut self, backward: bool) -> (i64, bool) {
        if backward {
            if self.current > 0 {
                self.current -= 1;
                let target = self.placeholders[self.current].start;
                return (self.move_to(target), true);
            }
            let target = self.final_offset;
            return (self.move_to(target), false);
        }
        if self.current + 1 < self.placeholders.len() {
            self.current += 1;
            let target = self.placeholders[self.current].start;
            return (self.move_to(target), true);
        }
        let target = self.final_offset;
        (self.move_to(target), false)
    }
}

/// Escape sequences moving the cursor `delta` columns (positive = right).
/// One plain arrow key per column: shells (readline, zle) understand that, but
/// not a counted `ESC [ n D`, which bash prints as a literal `D`.
pub fn cursor_move_bytes(delta: i64) -> Vec<u8> {
    let arrow: &[u8] = if delta > 0 { b"\x1b[C" } else { b"\x1b[D" };
    arrow.repeat(delta.unsigned_abs() as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("chau7-snip-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn paths(root: &Path) -> SnippetPaths {
        SnippetPaths {
            global: root.join("global"),
            profile: root.join("default"),
            repo_relative: String::new(),
            overlays: root.join("repo-overlays"),
        }
    }

    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp(1_700_000_000, 0).unwrap()
    }

    #[test]
    fn clean_encoding_omits_empty_fields_and_sorts_keys() {
        let mut s = Snippet::new("a", "A", "ls");
        s.created_at = Some(now());
        let text = encode_snippet(&s);
        assert!(!text.contains("tags"));
        assert!(!text.contains("isPinned"));
        assert!(text.contains("\"createdAt\": \"2023-11-14T22:13:20Z\""));
        assert!(text.find("body").unwrap() < text.find("id").unwrap());
        assert!(text.find("id").unwrap() < text.find("title").unwrap());
    }

    #[test]
    fn decodes_swift_dates_and_missing_fields() {
        let text = r#"{"id":"x","title":"T","body":"b","createdAt":"2025-01-14T12:30:45.123Z","updatedAt":700000000.5}"#;
        let s: Snippet = serde_json::from_str(text).unwrap();
        assert!(s.created_at.is_some());
        assert_eq!(s.updated_at.unwrap().timestamp(), 978_307_200 + 700_000_000);
        assert!(s.tags.is_empty());
        assert!(!s.is_pinned);
    }

    #[test]
    fn validated_key_accepts_one_letter() {
        let mut s = Snippet::new("a", "A", "");
        s.key = Some(" Q ".into());
        assert_eq!(s.validated_key(), Some('q'));
        s.key = Some("qq".into());
        assert_eq!(s.validated_key(), None);
        s.key = Some("1".into());
        assert_eq!(s.validated_key(), None);
    }

    #[test]
    fn protected_roots_are_found() {
        let home = Path::new("/Users/me");
        assert_eq!(
            protected_root(Path::new("/Users/me/Documents/x/y"), home),
            Some(PathBuf::from("/Users/me/Documents"))
        );
        assert!(protected_root(Path::new("/Users/me/code"), home).is_none());
        assert!(protected_root(Path::new("/Users/me/DocumentsX"), home).is_none());
        assert!(protected_root(Path::new("/Library/x"), home).is_some());
    }

    #[test]
    fn repo_dir_default_and_json_suffix() {
        let root = Path::new("/r");
        assert_eq!(
            repo_snippets_dir(root, ""),
            root.join(DEFAULT_REPO_SNIPPET_PATH)
        );
        assert_eq!(repo_snippets_dir(root, "x/y.json"), root.join("x/y"));
    }

    #[test]
    fn repo_reads_folder_and_old_single_file_without_touching_it() {
        let root = temp("repo");
        let p = paths(&root.join("data"));
        let repo = root.join("repo");
        std::fs::create_dir_all(legacy_repo_file(&repo).parent().unwrap()).unwrap();
        let legacy = legacy_repo_file(&repo);
        std::fs::write(
            &legacy,
            r#"{"version":1,"snippets":[{"id":"old","title":"Old","body":"o"},{"id":"both","title":"Legacy","body":"l"}]}"#,
        )
        .unwrap();
        save_snippet(&p.repo_dir(&repo), &Snippet::new("both", "Folder", "f")).unwrap();
        save_snippet(&p.repo_dir(&repo), &Snippet::new("new", "New", "n")).unwrap();
        let before = std::fs::read(&legacy).unwrap();

        let loaded = load_repo(&p, &repo);
        let ids: Vec<_> = loaded.iter().map(|(s, l)| (s.id.as_str(), *l)).collect();
        assert!(ids.contains(&("old", true)));
        assert!(ids.contains(&("both", false)));
        assert!(ids.contains(&("new", false)));
        assert_eq!(loaded.iter().filter(|(s, _)| s.id == "both").count(), 1);
        assert_eq!(
            loaded.iter().find(|(s, _)| s.id == "both").unwrap().0.title,
            "Folder"
        );
        assert_eq!(std::fs::read(&legacy).unwrap(), before);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn deleting_a_legacy_only_snippet_hides_it_without_touching_the_repo() {
        let root = temp("legacy-delete");
        let p = paths(&root.join("data"));
        let repo = root.join("repo");
        std::fs::create_dir_all(legacy_repo_file(&repo).parent().unwrap()).unwrap();
        std::fs::write(
            legacy_repo_file(&repo),
            r#"{"version":1,"snippets":[{"id":"a","title":"A","body":"a"},{"id":"b","title":"B","body":"b"}]}"#,
        )
        .unwrap();
        let entries = merge_entries(
            &p,
            vec![],
            vec![],
            load_repo(&p, &repo),
            Some(repo.as_path()),
        );
        let before = std::fs::read(legacy_repo_file(&repo)).unwrap();
        let a = entries.iter().find(|e| e.snippet.id == "a").unwrap();
        delete_snippet(&p, a);
        assert_eq!(std::fs::read(legacy_repo_file(&repo)).unwrap(), before);
        let rest = load_repo(&p, &repo);
        assert_eq!(rest.len(), 1);
        assert_eq!(rest[0].0.id, "b");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn repo_edits_go_to_the_overlay() {
        let root = temp("overlay");
        let p = paths(&root.join("data"));
        let repo = root.join("repo");
        let repo_dir = p.repo_dir(&repo);
        save_snippet(&repo_dir, &Snippet::new("r", "Repo", "x")).unwrap();
        let repo_file = repo_dir.join("r.json");
        let before = std::fs::read(&repo_file).unwrap();
        let entries = |p: &SnippetPaths| {
            merge_entries(p, vec![], vec![], load_repo(p, &repo), Some(repo.as_path()))
        };

        // Pin: written to the overlay, which wins.
        let entry = entries(&p)
            .into_iter()
            .find(|e| e.snippet.id == "r")
            .unwrap();
        toggle_pin(&p, &entry, now()).unwrap();
        let entry = entries(&p)
            .into_iter()
            .find(|e| e.snippet.id == "r")
            .unwrap();
        assert!(entry.snippet.is_pinned);
        assert!(entry.source_path.starts_with(&p.overlays));

        // Delete: hidden, then a new snippet with the same id shows again.
        delete_snippet(&p, &entry);
        assert!(entries(&p).is_empty());
        let draft = SnippetDraft {
            id: "r".into(),
            title: "Again".into(),
            body: "y".into(),
            source: SnippetSource::Repo,
            ..SnippetDraft::from_entry(&entry)
        };
        create_snippet(&p, &draft, Some(&repo), now()).unwrap();
        let shown = entries(&p);
        assert_eq!(shown.len(), 1);
        assert_eq!(shown[0].snippet.title, "Again");

        // The repo's folder never changed and holds no new files.
        assert_eq!(std::fs::read(&repo_file).unwrap(), before);
        assert_eq!(std::fs::read_dir(&repo_dir).unwrap().count(), 1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn migrate_splits_and_deletes_legacy_file() {
        let root = temp("migrate");
        let legacy = root.join("snippets.json");
        std::fs::write(
            &legacy,
            r#"{"version":1,"snippets":[{"id":"a","title":"A","body":"a"},{"id":"b","title":"B","body":"b"}]}"#,
        )
        .unwrap();
        let target = root.join("global");
        assert_eq!(migrate_legacy_file(&legacy, &target, true), 2);
        assert!(!legacy.exists());
        assert_eq!(load_dir(&target).len(), 2);

        std::fs::write(&legacy, "[]").unwrap();
        assert_eq!(migrate_legacy_file(&legacy, &target, true), 0);
        assert!(!legacy.exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn merge_marks_overridden_and_sorts() {
        let root = temp("merge");
        let p = paths(&root);
        let repo = root.join("repo");
        let mut pinned = Snippet::new("p", "Zeta", "z");
        pinned.is_pinned = true;
        let entries = merge_entries(
            &p,
            vec![
                Snippet::new("same", "User same", "u"),
                Snippet::new("b", "beta", "b"),
                pinned,
            ],
            vec![Snippet::new("a", "Alpha", "a")],
            vec![(Snippet::new("same", "Repo same", "r"), false)],
            Some(repo.as_path()),
        );
        let titles: Vec<_> = entries.iter().map(|e| e.snippet.title.as_str()).collect();
        assert_eq!(
            titles,
            vec!["Zeta", "Repo same", "Alpha", "beta", "User same"]
        );
        let user_same = entries.iter().find(|e| e.snippet.title == "User same");
        assert!(user_same.unwrap().is_overridden);
        let repo_same = entries.iter().find(|e| e.snippet.title == "Repo same");
        assert!(!repo_same.unwrap().is_overridden);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn no_repo_means_no_repo_entries() {
        let p = paths(Path::new("/x"));
        let entries = merge_entries(
            &p,
            vec![],
            vec![],
            vec![(Snippet::new("r", "R", "r"), false)],
            None,
        );
        assert!(entries.is_empty());
    }

    #[test]
    fn filter_matches_title_body_tags_folder() {
        let p = paths(Path::new("/x"));
        let mut s = Snippet::new("a", "Deploy", "kubectl apply");
        s.tags = vec!["Ops".into()];
        s.folder = Some("Cluster".into());
        let entries = merge_entries(&p, vec![s], vec![], vec![], None);
        for q in ["deploy", "KUBECTL", "ops", "cluster", "  "] {
            assert_eq!(filter_entries(&entries, q).len(), 1, "{q}");
        }
        assert!(filter_entries(&entries, "nope").is_empty());
    }

    fn entry_with_key(id: &str, key: Option<&str>) -> SnippetEntry {
        let mut s = Snippet::new(id, id, "");
        s.key = key.map(str::to_string);
        SnippetEntry {
            snippet: s,
            source: SnippetSource::Global,
            source_path: PathBuf::new(),
            is_overridden: false,
            repo_root: None,
            from_legacy_repo_file: false,
        }
    }

    #[test]
    fn key_map_custom_wins_conflicts_excluded_rest_in_order() {
        let list = [
            entry_with_key("one", None),
            entry_with_key("two", Some("a")),
            entry_with_key("three", Some("b")),
            entry_with_key("four", Some("b")),
            entry_with_key("five", None),
        ];
        let refs: Vec<&SnippetEntry> = list.iter().collect();
        let map = build_key_map(&refs);
        assert_eq!(map.snippet_keys["global::two"], 'a');
        assert!(map.conflicting.contains(&'b'));
        assert!(!map.snippet_keys.contains_key("global::three"));
        assert!(!map.snippet_keys.contains_key("global::four"));
        assert_eq!(map.snippet_keys["global::one"], 'c');
        assert_eq!(map.snippet_keys["global::five"], 'd');
        assert_eq!(map.key_to_index[&'c'], 0);
    }

    #[test]
    fn crud_round_trip_and_move() {
        let root = temp("crud");
        let p = paths(&root);
        let draft = SnippetDraft {
            title: "Hello World".into(),
            body: "echo hi".into(),
            tags_text: "a, b,,".into(),
            key: "X".into(),
            ..Default::default()
        };
        let created = create_snippet(&p, &draft, None, now()).unwrap();
        assert!(created.id.starts_with("hello-world-"));
        assert_eq!(created.tags, vec!["a", "b"]);
        assert_eq!(created.key.as_deref(), Some("x"));

        let entry = merge_entries(&p, load_dir(&p.global), vec![], vec![], None).remove(0);
        let mut edit = SnippetDraft::from_entry(&entry);
        edit.source = SnippetSource::Profile;
        edit.id = "renamed".into();
        let later = now() + chrono::Duration::seconds(60);
        let moved = update_snippet(&p, &entry, &edit, None, later).unwrap();
        assert_eq!(moved.created_at, Some(now()));
        assert_eq!(moved.updated_at, Some(later));
        assert!(load_dir(&p.global).is_empty());
        assert_eq!(load_dir(&p.profile)[0].id, "renamed");

        let entry = merge_entries(&p, vec![], load_dir(&p.profile), vec![], None).remove(0);
        toggle_pin(&p, &entry, later).unwrap();
        assert!(load_dir(&p.profile)[0].is_pinned);
        delete_snippet(&p, &entry);
        assert!(load_dir(&p.profile).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn duplicate_uses_new_id_when_file_exists() {
        let root = temp("dup");
        let p = paths(&root);
        let draft = SnippetDraft {
            title: "T".into(),
            body: "b".into(),
            id: "t".into(),
            ..Default::default()
        };
        create_snippet(&p, &draft, None, now()).unwrap();
        let entry = merge_entries(&p, load_dir(&p.global), vec![], vec![], None).remove(0);
        let same = duplicate_snippet(&p, &entry, SnippetSource::Profile, None, now()).unwrap();
        assert_eq!(same.id, "t");
        let other = duplicate_snippet(&p, &entry, SnippetSource::Global, None, now()).unwrap();
        assert_ne!(other.id, "t");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_ids_that_escape_the_folder() {
        let root = temp("evil");
        let result = save_snippet(&root, &Snippet::new("../x", "T", "b"));
        assert!(result.is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn import_export_round_trip() {
        let root = temp("import");
        let p = paths(&root);
        let text = export_json(&[Snippet::new("a", "A", "x"), Snippet::new("b", "B", "y")]);
        assert_eq!(
            import_snippets(&p, &text, SnippetSource::Profile, now()).unwrap(),
            2
        );
        assert_eq!(load_dir(&p.profile).len(), 2);
        assert!(import_snippets(&p, "not json", SnippetSource::Global, now()).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn snippet_ids_are_slugs() {
        assert_eq!(
            make_snippet_id("Git: Status!", "ABC123"),
            "git-status-ABC123"
        );
        assert_eq!(make_snippet_id("!!!", "ABC123"), "snippet-ABC123");
    }

    fn ctx<'a>(clip: &'a dyn Fn() -> String) -> TokenContext<'a> {
        TokenContext {
            cwd: "/work",
            home: "/home/me",
            now: chrono::NaiveDate::from_ymd_opt(2026, 3, 4)
                .unwrap()
                .and_hms_opt(5, 6, 7)
                .unwrap(),
            clipboard: clip,
        }
    }

    #[test]
    fn tokens_are_replaced() {
        let clip = || "CLIP".to_string();
        let env = |k: &str| {
            if k == "USER" {
                "me".into()
            } else {
                String::new()
            }
        };
        let out = replace_tokens(
            "${cwd} ${home} ${date} ${time} ${clip} ${env:USER}",
            &ctx(&clip),
            &env,
        );
        assert_eq!(out, "/work /home/me 2026-03-04 05:06:07 CLIP me");
    }

    /// Clipboard, directory and environment values are inserted as written:
    /// a copied `${env:...}` must never type a secret into the shell.
    #[test]
    fn substituted_values_are_not_expanded_again() {
        let payload = "${env:AWS_SECRET_ACCESS_KEY}";
        let clip = || payload.to_string();
        let env = |k: &str| {
            if k == "AWS_SECRET_ACCESS_KEY" {
                "leaked-s3cr3t-value".to_string()
            } else {
                String::new()
            }
        };
        let body = "echo ${clip} ${1:x}";
        assert_eq!(
            replace_tokens(body, &ctx(&clip), &env),
            format!("echo {payload} ${{1:x}}")
        );
        for (paste, placeholders) in [(false, true), (true, true), (false, false)] {
            let ins = prepare_insertion(body, &ctx(&clip), &env, paste, placeholders);
            assert!(!ins.text.contains("leaked-s3cr3t-value"), "{ins:?}");
            assert!(ins.text.starts_with(&format!("echo {payload} ")), "{ins:?}");
        }
        // A value never becomes a tab stop or reads the clipboard.
        let clip = || "${1:stop}".to_string();
        let ins = prepare_insertion("${clip}", &ctx(&clip), &env, false, true);
        assert_eq!(ins.text, "${1:stop}");
        assert!(ins.placeholders.is_empty());
        let clip = || panic!("clipboard read");
        let cwd_ctx = TokenContext {
            cwd: "/w/${clip}/${env:AWS_SECRET_ACCESS_KEY}",
            ..ctx(&clip)
        };
        assert_eq!(
            replace_tokens("${cwd}", &cwd_ctx, &env),
            "/w/${clip}/${env:AWS_SECRET_ACCESS_KEY}"
        );
    }

    /// Tab stops around and after token values point into the final text.
    #[test]
    fn placeholder_offsets_follow_token_values() {
        let clip = || "é😀".to_string();
        let env = |_: &str| "ENV".to_string();
        let ins = prepare_insertion(
            "${clip} ${1:${cwd}} ${env:X} ${2:b}${0}",
            &ctx(&clip),
            &env,
            false,
            true,
        );
        assert_eq!(ins.text, "é😀 /work ENV b");
        assert_eq!(ins.placeholders[0], Placeholder::new(1, 3, 5));
        assert_eq!(ins.placeholders[1], Placeholder::new(2, 13, 1));
        assert_eq!(ins.final_cursor_offset, 14);
        // Marker-range characters typed in a snippet come back unchanged.
        let text = "\u{F0000}\u{F0001}";
        assert_eq!(replace_tokens(text, &ctx(&clip), &env), text);
    }

    #[test]
    fn clipboard_is_read_only_when_used() {
        let clip = || panic!("clipboard read");
        let env = |_: &str| String::new();
        assert_eq!(replace_tokens("x", &ctx(&clip), &env), "x");
    }

    #[test]
    fn insertion_modes() {
        let clip = || String::new();
        let env = |_: &str| String::new();
        let body = "echo ${1:a} ${2:b}${0}";
        let expand = prepare_insertion(body, &ctx(&clip), &env, false, true);
        assert_eq!(expand.text, "echo a b");
        assert_eq!(expand.placeholders.len(), 2);
        assert_eq!(expand.final_cursor_offset, 8);
        for (paste, enabled) in [(true, true), (false, false)] {
            let plain = prepare_insertion(body, &ctx(&clip), &env, paste, enabled);
            assert_eq!(plain.text, body);
            assert!(plain.placeholders.is_empty());
        }
    }

    #[test]
    fn input_variables_parse() {
        let vars = parse_input_variables(
            "a ${input:name} b ${input:greeting:hello} c ${input:env:dev|prod| dev } ${multiselect:flags:-v|-x} ${input:name:again}",
        );
        let names: Vec<_> = vars.iter().map(|v| v.name.as_str()).collect();
        assert_eq!(names, vec!["flags", "name", "greeting", "env"]);
        assert_eq!(vars[0].input_type, InputType::MultiSelect);
        assert_eq!(vars[1].value, "");
        assert_eq!(vars[2].value, "hello");
        assert_eq!(vars[3].input_type, InputType::SingleSelect);
        assert_eq!(vars[3].options, vec!["dev", "prod"]);
        assert_eq!(vars[3].value, "dev");
        assert!(has_input_variables("${input:x}"));
        assert!(!has_input_variables("${1:x}"));
    }

    #[test]
    fn input_variables_replace() {
        let mut vars = parse_input_variables(
            "${input:name} ${input:name:x} ${input:env:a|b} ${multiselect:flags:-v|-x}",
        );
        for v in &mut vars {
            match v.name.as_str() {
                "name" => v.value = "$1\\n".into(),
                "flags" => {
                    v.selected.insert("-x".into());
                    v.selected.insert("-v".into());
                }
                _ => {}
            }
        }
        let out = replace_input_variables(
            "${input:name} ${input:name:x} ${input:env:a|b} ${multiselect:flags:-v|-x}",
            &vars,
        );
        assert_eq!(out, "$1\\n $1\\n a -v -x");
    }

    #[test]
    fn navigation_walks_tab_stops_then_the_end() {
        let clip = || String::new();
        let env = |_: &str| String::new();
        let ins = prepare_insertion("ab ${1:cd} ef ${2:gh}", &ctx(&clip), &env, false, true);
        assert_eq!(ins.text, "ab cd ef gh");
        let (mut nav, first) = Navigation::start(&ins).unwrap();
        assert_eq!(first, 3 - 11);
        assert_eq!(nav.advance(false), (9 - 3, true));
        assert_eq!(nav.advance(true), (3 - 9, true));
        assert_eq!(nav.advance(true), (11 - 3, false));
        let (mut nav, _) = Navigation::start(&ins).unwrap();
        nav.advance(false);
        assert_eq!(nav.advance(false), (2, false));
    }

    #[test]
    fn navigation_skipped_for_non_ascii_or_no_stops() {
        let clip = || String::new();
        let env = |_: &str| String::new();
        let ins = prepare_insertion("é ${1:x}", &ctx(&clip), &env, false, true);
        assert!(Navigation::start(&ins).is_none());
        let ins = prepare_insertion("plain", &ctx(&clip), &env, false, true);
        assert!(Navigation::start(&ins).is_none());
    }

    #[test]
    fn cursor_move_sequences() {
        assert_eq!(cursor_move_bytes(3), b"\x1b[C\x1b[C\x1b[C");
        assert_eq!(cursor_move_bytes(-2), b"\x1b[D\x1b[D");
        assert!(cursor_move_bytes(0).is_empty());
    }
}
