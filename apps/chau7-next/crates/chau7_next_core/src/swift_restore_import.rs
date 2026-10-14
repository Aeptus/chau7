//! Read-only conversion of Chau7's Swift restore bundle and UserDefaults
//! index into the framework-independent Next session schema.
//!
//! This module deliberately accepts source paths from its caller. It never
//! resolves a profile path or writes to either source or destination. The app
//! layer can validate the returned snapshot immediately before its own
//! destination transaction.

use crate::session_restore::transaction::{SourceDecision, source_decision};
use crate::session_restore::{
    MAX_SCROLLBACK_BYTES, SavedAxis, SavedSplitNode, build_ai_resume_command,
    models::{SavedPane, SavedSession, SavedTab, SavedWindow},
    resolve_resume_metadata_from_saved,
};
use crate::token_optimization::TabTokenOptOverride;
use chrono::DateTime;
use plist::Value as PlistValue;
use serde::Deserialize;
use serde_json::Value as JsonValue;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Component, Path, PathBuf};
use uuid::Uuid;

const INDEX_KEY: &str = "com.chau7.savedTabState";
const MULTI_WINDOW_KEY: &str = "com.chau7.savedMultiWindowState";
const INDEX_TOKEN_KEY: &str = "com.chau7.savedTabState.saveToken";
const MAX_PLIST_BYTES: u64 = 32 * 1024 * 1024;
const MAX_JSON_BYTES: u64 = 32 * 1024 * 1024;
const MAX_CONTEXT_JSON_BYTES: u64 = 2 * 1024 * 1024;
const SWIFT_REFERENCE_UNIX_SECONDS: f64 = 978_307_200.0;

/// Explicit read-only locations for one Swift restore source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwiftRestoreSource {
    /// Root containing `current/manifest.json` and immutable context files.
    pub bundle_root: PathBuf,
    /// Preferences plist containing the scrollback-stripped restore index.
    pub preferences_file: PathBuf,
}

/// Counts and loss notices safe to print in a migration summary. These values
/// contain no paths, commands, AI identifiers, or terminal text.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportSummary {
    pub windows: usize,
    pub tabs: usize,
    pub panes: usize,
    pub context_bytes: usize,
    pub truncated_contexts: usize,
    pub dropped_unsupported_ai_identities: usize,
    pub dropped_tab_preview_contexts: usize,
    pub dropped_dashboard_group_ids: usize,
}

/// Fully validated, in-memory import. `snapshot` is private so callers must
/// use [`validate_source_snapshot`] rather than manufacturing a weaker check.
pub struct PreparedSwiftImport {
    pub session: SavedSession,
    pub scrollback: BTreeMap<u64, Vec<u8>>,
    pub summary: ImportSummary,
    snapshot: Vec<FileSnapshot>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportError {
    Io,
    InvalidPlist,
    Malformed(&'static str),
    Unsupported(&'static str),
    Integrity,
    SnapshotChanged,
}

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = match self {
            Self::Io => "could not read the Swift restore source",
            Self::InvalidPlist => "the Swift preferences file is malformed",
            Self::Malformed(reason) => reason,
            Self::Unsupported(reason) => reason,
            Self::Integrity => "a Swift restore context failed its integrity check",
            Self::SnapshotChanged => "the Swift restore source changed during import",
        };
        f.write_str(message)
    }
}

impl std::error::Error for ImportError {}

#[derive(Debug, Clone)]
struct FileSnapshot {
    path: PathBuf,
    content: Option<(usize, [u8; 32])>,
}

impl FileSnapshot {
    fn from_bytes(path: PathBuf, bytes: &[u8]) -> Self {
        Self {
            path,
            content: Some((bytes.len(), Sha256::digest(bytes).into())),
        }
    }

    fn missing(path: PathBuf) -> Self {
        Self {
            path,
            content: None,
        }
    }

    fn still_matches(&self) -> Result<bool, ImportError> {
        match self.content {
            Some((byte_count, expected_hash)) => {
                let Ok(bytes) = read_bounded(&self.path, max_for_path(&self.path)) else {
                    return Ok(false);
                };
                let hash: [u8; 32] = Sha256::digest(&bytes).into();
                Ok(bytes.len() == byte_count && hash == expected_hash)
            }
            None => Ok(!self.path.exists()),
        }
    }
}

fn max_for_path(path: &Path) -> u64 {
    if path
        .extension()
        .is_some_and(|extension| extension == "plist")
    {
        MAX_PLIST_BYTES
    } else {
        MAX_JSON_BYTES
    }
}

fn read_bounded(path: &Path, maximum: u64) -> Result<Vec<u8>, ImportError> {
    let file = fs::File::open(path).map_err(|_| ImportError::Io)?;
    let metadata = file.metadata().map_err(|_| ImportError::Io)?;
    if !metadata.is_file() || metadata.len() > maximum {
        return Err(ImportError::Malformed(
            "a Swift restore file exceeds its size bound",
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ImportError::Io)?;
    if bytes.len() as u64 > maximum {
        return Err(ImportError::Malformed(
            "a Swift restore file exceeds its size bound",
        ));
    }
    Ok(bytes)
}

/// Detects whether either supported Swift restore source exists. This is a
/// read-only probe for first-launch source choice; it does not decode tabs.
pub fn has_swift_restore_source(source: &SwiftRestoreSource) -> Result<bool, ImportError> {
    let manifest = source.bundle_root.join("current").join("manifest.json");
    if manifest.is_file() {
        return Ok(true);
    }
    if !source.preferences_file.is_file() {
        return Ok(false);
    }
    let bytes = read_bounded(&source.preferences_file, MAX_PLIST_BYTES)?;
    let plist =
        PlistValue::from_reader(Cursor::new(bytes)).map_err(|_| ImportError::InvalidPlist)?;
    let Some(dictionary) = plist.as_dictionary() else {
        return Err(ImportError::InvalidPlist);
    };
    Ok(dictionary.contains_key(INDEX_KEY) || dictionary.contains_key(MULTI_WINDOW_KEY))
}

/// Parse and convert the freshest supported Swift source. A missing or empty
/// restore state returns `Ok(None)`. Malformed state is rejected rather than
/// silently importing a partial tab set.
pub fn prepare_swift_import(
    source: &SwiftRestoreSource,
) -> Result<Option<PreparedSwiftImport>, ImportError> {
    let manifest_path = source.bundle_root.join("current").join("manifest.json");
    let mut snapshots = Vec::new();
    let mut preferences = None;
    let index_token;

    if source.preferences_file.is_file() {
        let bytes = read_bounded(&source.preferences_file, MAX_PLIST_BYTES)?;
        snapshots.push(FileSnapshot::from_bytes(
            source.preferences_file.clone(),
            &bytes,
        ));
        let plist =
            PlistValue::from_reader(Cursor::new(bytes)).map_err(|_| ImportError::InvalidPlist)?;
        let dictionary = plist.as_dictionary().ok_or(ImportError::InvalidPlist)?;
        index_token = dictionary
            .get(INDEX_TOKEN_KEY)
            .and_then(PlistValue::as_string)
            .map(str::to_owned);
        preferences = Some(dictionary.clone());
    } else {
        snapshots.push(FileSnapshot::missing(source.preferences_file.clone()));
        index_token = None;
    }

    let bundle = if manifest_path.is_file() {
        let bytes = read_bounded(&manifest_path, MAX_JSON_BYTES)?;
        snapshots.push(FileSnapshot::from_bytes(manifest_path, &bytes));
        let envelope: BundleEnvelope = serde_json::from_slice(&bytes)
            .map_err(|_| ImportError::Malformed("the Swift restore manifest is malformed"))?;
        if envelope.schema_version != 1 {
            return Err(ImportError::Unsupported(
                "the Swift restore manifest version is unsupported",
            ));
        }
        parse_iso8601_unix(&envelope.saved_at).map_err(|_| {
            ImportError::Malformed("the Swift restore manifest timestamp is malformed")
        })?;
        if envelope.reason.trim().is_empty() || envelope.source_fingerprint.trim().is_empty() {
            return Err(ImportError::Malformed(
                "the Swift restore manifest metadata is incomplete",
            ));
        }
        Some(envelope)
    } else {
        snapshots.push(FileSnapshot::missing(manifest_path.clone()));
        None
    };

    let bundle_is_current = match bundle.as_ref() {
        Some(envelope) => {
            source_decision(
                envelope.save_token.as_deref(),
                envelope.previous_index_save_token.as_deref(),
                index_token.as_deref(),
            ) != SourceDecision::IndexCurrent
        }
        None => false,
    };

    let (windows, bundle_contexts) = if bundle_is_current {
        let envelope = bundle.as_ref().expect("current bundle exists");
        (envelope.windows.clone(), true)
    } else if let Some(dictionary) = preferences.as_ref() {
        let windows = read_index_windows(dictionary)?;
        (windows, false)
    } else if bundle.is_some() {
        // With no published index token, the bundle is the only restorable
        // source. This also handles older bundles without transaction tokens.
        let envelope = bundle.as_ref().expect("bundle exists");
        (envelope.windows.clone(), true)
    } else {
        return Ok(None);
    };

    if windows.is_empty() || windows.iter().all(Vec::is_empty) {
        return Ok(None);
    }

    let bundle_root = canonical_existing(&source.bundle_root).ok();
    let mut converter = Converter {
        bundle_root,
        bundle_contexts,
        snapshots,
        scrollback: BTreeMap::new(),
        summary: ImportSummary::default(),
        global_pane_ids: HashSet::new(),
        global_layout_ids: HashSet::new(),
        global_tab_ids: HashSet::new(),
    };
    let mut saved_windows = Vec::with_capacity(windows.len());
    for (window_index, tabs) in windows.iter().enumerate() {
        if tabs.is_empty() {
            continue;
        }
        let selected = selected_tab_index(tabs)?;
        let mut saved_tabs = Vec::with_capacity(tabs.len());
        for (tab_index, tab) in tabs.iter().enumerate() {
            saved_tabs.push(converter.convert_tab(tab, window_index, tab_index)?);
        }
        converter.summary.tabs += saved_tabs.len();
        saved_windows.push(SavedWindow {
            tabs: saved_tabs,
            selected: selected.min(tabs.len().saturating_sub(1)),
            // Swift persists the tab/window arrangement and selected tab, but
            // not portable window geometry in this schema.
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
        });
    }
    converter.summary.windows = saved_windows.len();
    converter.summary.panes = saved_windows
        .iter()
        .flat_map(|window| &window.tabs)
        .map(|tab| tab.panes.len())
        .sum();
    converter.summary.context_bytes = converter.scrollback.values().map(Vec::len).sum();

    let session = SavedSession {
        version: 1,
        windows: saved_windows,
    };
    Ok(Some(PreparedSwiftImport {
        session,
        scrollback: converter.scrollback,
        summary: converter.summary,
        snapshot: converter.snapshots,
    }))
}

/// Re-read every source file that contributed to the import and reject any
/// change since conversion. The destination layer should call this while
/// holding its instance lock and immediately before its first write.
pub fn validate_source_snapshot(plan: &PreparedSwiftImport) -> Result<(), ImportError> {
    for snapshot in &plan.snapshot {
        if !snapshot.still_matches()? {
            return Err(ImportError::SnapshotChanged);
        }
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BundleEnvelope {
    schema_version: u32,
    saved_at: String,
    reason: String,
    source_fingerprint: String,
    #[serde(default)]
    save_token: Option<String>,
    #[serde(default)]
    previous_index_save_token: Option<String>,
    windows: Vec<Vec<SwiftTab>>,
}

fn read_index_windows(dictionary: &plist::Dictionary) -> Result<Vec<Vec<SwiftTab>>, ImportError> {
    if let Some(value) = dictionary.get(MULTI_WINDOW_KEY) {
        let data = value.as_data().ok_or(ImportError::Malformed(
            "the Swift multi-window index is malformed",
        ))?;
        if data.len() as u64 > MAX_JSON_BYTES {
            return Err(ImportError::Malformed(
                "the Swift restore index exceeds its size bound",
            ));
        }
        let state: MultiWindowIndex = serde_json::from_slice(data)
            .map_err(|_| ImportError::Malformed("the Swift multi-window index is malformed"))?;
        return Ok(state.windows);
    }
    if let Some(value) = dictionary.get(INDEX_KEY) {
        let data = value.as_data().ok_or(ImportError::Malformed(
            "the Swift restore index is malformed",
        ))?;
        if data.len() as u64 > MAX_JSON_BYTES {
            return Err(ImportError::Malformed(
                "the Swift restore index exceeds its size bound",
            ));
        }
        let tabs: Vec<SwiftTab> = serde_json::from_slice(data)
            .map_err(|_| ImportError::Malformed("the Swift restore index is malformed"))?;
        return Ok(vec![tabs]);
    }
    Err(ImportError::Malformed(
        "the current Swift restore source has no tab index",
    ))
}

#[derive(Deserialize)]
struct MultiWindowIndex {
    windows: Vec<Vec<SwiftTab>>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwiftTab {
    #[serde(default)]
    tab_id: Option<String>,
    #[serde(default)]
    selected_tab_id: Option<String>,
    #[serde(default)]
    custom_title: Option<String>,
    color: String,
    directory: String,
    #[serde(default)]
    selected_index: Option<usize>,
    #[serde(default)]
    token_opt_override: Option<String>,
    #[serde(default)]
    scrollback_content: Option<String>,
    #[serde(default)]
    ai_resume_command: Option<String>,
    #[serde(default)]
    ai_provider: Option<String>,
    #[serde(default)]
    ai_session_id: Option<String>,
    #[serde(default)]
    ai_session_id_source: Option<String>,
    #[serde(default)]
    split_layout: Option<JsonValue>,
    #[serde(default)]
    focused_pane_id: Option<String>,
    #[serde(default)]
    pane_states: Option<Vec<PaneState>>,
    #[serde(default)]
    pane_identities: Option<Vec<PaneIdentity>>,
    #[serde(default)]
    created_at: Option<String>,
    #[serde(default)]
    repo_group_id: Option<String>,
    #[serde(default)]
    known_repo_root: Option<String>,
    #[serde(default)]
    known_git_branch: Option<String>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    last_input_at: Option<f64>,
    #[serde(default)]
    last_status: Option<String>,
    #[serde(default)]
    agent_launch_command: Option<String>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    agent_started_at: Option<f64>,
    #[serde(default)]
    last_exit_code: Option<i32>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    last_exit_at: Option<f64>,
    #[serde(default)]
    context_ref: Option<ContextRef>,
    #[serde(default)]
    command_blocks: Option<Vec<JsonValue>>,
    #[serde(default)]
    preview_snapshot_png_data: Option<String>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaneState {
    pane_id: String,
    directory: String,
    #[serde(default)]
    scrollback_content: Option<String>,
    #[serde(default)]
    ai_resume_command: Option<String>,
    #[serde(default)]
    ai_provider: Option<String>,
    #[serde(default)]
    ai_session_id: Option<String>,
    #[serde(default)]
    ai_session_id_source: Option<String>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    last_output_at: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    last_input_at: Option<f64>,
    #[serde(default)]
    known_repo_root: Option<String>,
    #[serde(default)]
    known_git_branch: Option<String>,
    #[serde(default)]
    last_status: Option<String>,
    #[serde(default)]
    agent_launch_command: Option<String>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    agent_started_at: Option<f64>,
    #[serde(default)]
    last_exit_code: Option<i32>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    last_exit_at: Option<f64>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaneIdentity {
    pane_id: String,
    directory: String,
    #[serde(default)]
    ai_resume_command: Option<String>,
    #[serde(default)]
    ai_provider: Option<String>,
    #[serde(default)]
    ai_session_id: Option<String>,
    #[serde(default)]
    ai_session_id_source: Option<String>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    last_output_at: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    last_input_at: Option<f64>,
    #[serde(default)]
    known_repo_root: Option<String>,
    #[serde(default)]
    known_git_branch: Option<String>,
    #[serde(default)]
    last_status: Option<String>,
    #[serde(default)]
    agent_launch_command: Option<String>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    agent_started_at: Option<f64>,
    #[serde(default)]
    last_exit_code: Option<i32>,
    #[serde(default, deserialize_with = "deserialize_flexible_date")]
    last_exit_at: Option<f64>,
    #[serde(default)]
    context_ref: Option<ContextRef>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContextRef {
    path: String,
    sha256: String,
    byte_count: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabContext {
    schema_version: u32,
    #[serde(default)]
    tab_id: Option<String>,
    #[serde(default)]
    scrollback_content: Option<String>,
    #[serde(default)]
    command_blocks: Option<Vec<JsonValue>>,
    #[serde(default)]
    preview_snapshot_png_data: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaneContext {
    schema_version: u32,
    pane_id: String,
    #[serde(default)]
    scrollback_content: Option<String>,
}

fn deserialize_flexible_date<'de, D>(deserializer: D) -> Result<Option<f64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<JsonValue>::deserialize(deserializer)?;
    match value {
        None | Some(JsonValue::Null) => Ok(None),
        Some(JsonValue::Number(number)) => {
            let raw = number
                .as_f64()
                .ok_or_else(|| serde::de::Error::custom("invalid date"))?;
            let unix = raw + SWIFT_REFERENCE_UNIX_SECONDS;
            if unix.is_finite() {
                Ok(Some(unix))
            } else {
                Err(serde::de::Error::custom("invalid date"))
            }
        }
        Some(JsonValue::String(text)) => {
            let parsed = DateTime::parse_from_rfc3339(&text)
                .map_err(|_| serde::de::Error::custom("invalid date"))?;
            Ok(Some(
                parsed.timestamp() as f64 + parsed.timestamp_subsec_nanos() as f64 / 1e9,
            ))
        }
        _ => Err(serde::de::Error::custom("invalid date")),
    }
}

struct Converter {
    bundle_root: Option<PathBuf>,
    bundle_contexts: bool,
    snapshots: Vec<FileSnapshot>,
    scrollback: BTreeMap<u64, Vec<u8>>,
    summary: ImportSummary,
    global_pane_ids: HashSet<u64>,
    global_layout_ids: HashSet<u64>,
    global_tab_ids: HashSet<Uuid>,
}

impl Converter {
    fn convert_tab(
        &mut self,
        tab: &SwiftTab,
        window_index: usize,
        tab_index: usize,
    ) -> Result<SavedTab, ImportError> {
        let uuid = tab.tab_id.as_deref().map(parse_uuid).transpose()?;
        if uuid.is_some_and(|id| !self.global_tab_ids.insert(id)) {
            return Err(ImportError::Malformed(
                "the Swift restore index contains duplicate tab ids",
            ));
        }
        let mut terminal_layout = Vec::new();
        let layout = if let Some(value) = &tab.split_layout {
            Some(convert_layout(
                value,
                &mut self.global_layout_ids,
                &mut terminal_layout,
                &mut self.summary,
            )?)
        } else {
            None
        };

        let mut identity_map = HashMap::new();
        if let Some(identities) = tab.pane_identities.as_ref() {
            for identity in identities {
                let pane_uuid = parse_uuid(&identity.pane_id)?;
                if identity_map
                    .insert(identity.pane_id.as_str(), (pane_uuid, identity))
                    .is_some()
                {
                    return Err(ImportError::Malformed(
                        "the Swift restore manifest contains duplicate pane identities",
                    ));
                }
            }
        }
        let mut state_map = HashMap::new();
        if let Some(states) = tab.pane_states.as_ref() {
            for state in states {
                parse_uuid(&state.pane_id)?;
                if state_map.insert(state.pane_id.as_str(), state).is_some() {
                    return Err(ImportError::Malformed(
                        "the Swift restore index contains duplicate pane identities",
                    ));
                }
            }
        }

        if layout.is_none() {
            let pane_count = identity_map.len().max(state_map.len());
            if pane_count > 1 {
                return Err(ImportError::Unsupported(
                    "the Swift tab has multiple panes but no split layout",
                ));
            }
            let raw_id = identity_map
                .keys()
                .next()
                .copied()
                .or_else(|| state_map.keys().next().copied())
                .or(tab.tab_id.as_deref())
                .unwrap_or_else(|| "");
            let fallback_id;
            let raw_id = if raw_id.is_empty() {
                fallback_id = fallback_uuid(window_index, tab_index).to_string();
                fallback_id.as_str()
            } else {
                raw_id
            };
            let id = uuid_to_u64(parse_uuid(raw_id)?);
            if !self.global_layout_ids.insert(id) {
                return Err(ImportError::Malformed(
                    "the Swift restore source contains duplicate layout ids",
                ));
            }
            terminal_layout.push((raw_id.to_owned(), id, Some(tab.directory.clone())));
        }

        for key in identity_map.keys().chain(state_map.keys()) {
            if !terminal_layout.iter().any(|(raw, _, _)| raw == key) {
                return Err(ImportError::Malformed(
                    "the Swift pane state does not match its split layout",
                ));
            }
        }

        let tab_context = if self.bundle_contexts {
            tab.context_ref
                .as_ref()
                .map(|reference| self.read_tab_context(reference))
                .transpose()?
        } else {
            None
        };
        if tab_context.as_ref().is_some_and(|context| {
            context
                .command_blocks
                .as_ref()
                .is_some_and(|blocks| !blocks.is_empty())
                || context.preview_snapshot_png_data.is_some()
                || tab
                    .command_blocks
                    .as_ref()
                    .is_some_and(|blocks| !blocks.is_empty())
                || tab.preview_snapshot_png_data.is_some()
        }) || tab
            .command_blocks
            .as_ref()
            .is_some_and(|blocks| !blocks.is_empty())
            || tab.preview_snapshot_png_data.is_some()
        {
            self.summary.dropped_tab_preview_contexts += 1;
        }
        if let Some(context) = &tab_context {
            if context
                .tab_id
                .as_deref()
                .is_some_and(|id| tab.tab_id.as_deref() != Some(id))
            {
                return Err(ImportError::Malformed(
                    "the Swift tab context belongs to a different tab",
                ));
            }
        }

        let mut panes = Vec::new();
        for (raw_id, id, layout_directory) in &terminal_layout {
            if !self.global_pane_ids.insert(*id) {
                return Err(ImportError::Malformed(
                    "the Swift restore source contains duplicate pane ids",
                ));
            }
            let identity = identity_map.get(raw_id.as_str()).map(|(_, value)| *value);
            let state = state_map.get(raw_id.as_str()).copied();
            let directory = identity
                .map(|item| item.directory.clone())
                .or_else(|| state.map(|item| item.directory.clone()))
                .or_else(|| layout_directory.clone())
                .or_else(|| Some(tab.directory.clone()));

            let pane_context = if self.bundle_contexts {
                identity
                    .and_then(|item| item.context_ref.as_ref())
                    .map(|reference| self.read_pane_context(reference, raw_id))
                    .transpose()?
            } else {
                None
            };
            let scrollback = pane_context
                .as_ref()
                .and_then(|context| context.scrollback_content.clone())
                .or_else(|| state.and_then(|item| item.scrollback_content.clone()));
            let scrollback = scrollback.or_else(|| {
                (terminal_layout.first().is_some_and(|first| first.1 == *id))
                    .then(|| {
                        tab_context
                            .as_ref()
                            .and_then(|context| context.scrollback_content.clone())
                    })
                    .flatten()
                    .or_else(|| {
                        (terminal_layout.len() == 1)
                            .then(|| tab.scrollback_content.clone())
                            .flatten()
                    })
            });
            let scrollback = scrollback.map(|text| self.bound_scrollback(text));
            if let Some(bytes) = scrollback {
                self.scrollback.insert(*id, bytes);
            }

            let provider = identity
                .and_then(|item| item.ai_provider.as_deref())
                .or_else(|| state.and_then(|item| item.ai_provider.as_deref()))
                .or_else(|| {
                    (terminal_layout.first().is_some_and(|first| first.1 == *id))
                        .then_some(tab.ai_provider.as_deref())
                        .flatten()
                });
            let session_id = identity
                .and_then(|item| item.ai_session_id.as_deref())
                .or_else(|| state.and_then(|item| item.ai_session_id.as_deref()))
                .or_else(|| {
                    (terminal_layout.first().is_some_and(|first| first.1 == *id))
                        .then_some(tab.ai_session_id.as_deref())
                        .flatten()
                });
            let resume_command = identity
                .and_then(|item| item.ai_resume_command.as_deref())
                .or_else(|| state.and_then(|item| item.ai_resume_command.as_deref()))
                .or_else(|| {
                    (terminal_layout.first().is_some_and(|first| first.1 == *id))
                        .then_some(tab.ai_resume_command.as_deref())
                        .flatten()
                });
            let metadata = resolve_resume_metadata_from_saved(provider, session_id, resume_command);
            let safe_resume = metadata.as_ref().and_then(|meta| {
                build_ai_resume_command(Some(&meta.provider), Some(&meta.session_id))
            });
            let has_ai_payload =
                provider.is_some() || session_id.is_some() || resume_command.is_some();
            if has_ai_payload && safe_resume.is_none() {
                self.summary.dropped_unsupported_ai_identities += 1;
            }
            let source = identity
                .and_then(|item| item.ai_session_id_source.clone())
                .or_else(|| state.and_then(|item| item.ai_session_id_source.clone()))
                .or_else(|| {
                    (terminal_layout.first().is_some_and(|first| first.1 == *id))
                        .then(|| tab.ai_session_id_source.clone())
                        .flatten()
                });
            let directory = directory
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty());
            let last_status = identity
                .and_then(|item| item.last_status.as_deref())
                .or_else(|| state.and_then(|item| item.last_status.as_deref()))
                .or_else(|| {
                    (terminal_layout.first().is_some_and(|first| first.1 == *id))
                        .then_some(tab.last_status.as_deref())
                        .flatten()
                })
                .map(restored_status)
                .transpose()?;
            panes.push(SavedPane {
                id: *id,
                directory,
                scrollback: self.scrollback.contains_key(id),
                ai_provider: safe_resume
                    .as_ref()
                    .and_then(|_| metadata.as_ref().map(|meta| meta.provider.clone())),
                ai_session_id: safe_resume
                    .as_ref()
                    .and_then(|_| metadata.as_ref().map(|meta| meta.session_id.clone())),
                ai_resume_command: safe_resume,
                ai_session_id_source: metadata.as_ref().and_then(|_| source),
                agent_launch_command: identity
                    .and_then(|item| item.agent_launch_command.clone())
                    .or_else(|| state.and_then(|item| item.agent_launch_command.clone()))
                    .or_else(|| {
                        (terminal_layout.first().is_some_and(|first| first.1 == *id))
                            .then(|| tab.agent_launch_command.clone())
                            .flatten()
                    }),
                last_input_at: identity
                    .and_then(|item| item.last_input_at)
                    .or_else(|| state.and_then(|item| item.last_input_at))
                    .or_else(|| {
                        (terminal_layout.first().is_some_and(|first| first.1 == *id))
                            .then_some(tab.last_input_at)
                            .flatten()
                    }),
                last_output_at: identity
                    .and_then(|item| item.last_output_at)
                    .or_else(|| state.and_then(|item| item.last_output_at)),
                agent_started_at: identity
                    .and_then(|item| item.agent_started_at)
                    .or_else(|| state.and_then(|item| item.agent_started_at))
                    .or_else(|| {
                        (terminal_layout.first().is_some_and(|first| first.1 == *id))
                            .then_some(tab.agent_started_at)
                            .flatten()
                    }),
                last_exit_at: identity
                    .and_then(|item| item.last_exit_at)
                    .or_else(|| state.and_then(|item| item.last_exit_at))
                    .or_else(|| {
                        (terminal_layout.first().is_some_and(|first| first.1 == *id))
                            .then_some(tab.last_exit_at)
                            .flatten()
                    }),
                known_repo_root: identity
                    .and_then(|item| item.known_repo_root.clone())
                    .or_else(|| state.and_then(|item| item.known_repo_root.clone()))
                    .or_else(|| {
                        (terminal_layout.first().is_some_and(|first| first.1 == *id))
                            .then(|| tab.known_repo_root.clone())
                            .flatten()
                    }),
                known_git_branch: identity
                    .and_then(|item| item.known_git_branch.clone())
                    .or_else(|| state.and_then(|item| item.known_git_branch.clone()))
                    .or_else(|| {
                        (terminal_layout.first().is_some_and(|first| first.1 == *id))
                            .then(|| tab.known_git_branch.clone())
                            .flatten()
                    }),
                last_status,
                last_exit_code: identity
                    .and_then(|item| item.last_exit_code)
                    .or_else(|| state.and_then(|item| item.last_exit_code))
                    .or_else(|| {
                        (terminal_layout.first().is_some_and(|first| first.1 == *id))
                            .then_some(tab.last_exit_code)
                            .flatten()
                    }),
            });
        }
        let focused_pane = tab
            .focused_pane_id
            .as_deref()
            .map(parse_uuid)
            .transpose()?
            .map(uuid_to_u64);
        if focused_pane.is_some_and(|id| !panes.iter().any(|pane| pane.id == id)) {
            return Err(ImportError::Malformed(
                "the Swift focused pane is not present in the tab layout",
            ));
        }
        let created_at = tab
            .created_at
            .as_deref()
            .map(parse_iso8601_unix)
            .transpose()?;
        let token_opt_override = tab
            .token_opt_override
            .as_deref()
            .map(parse_token_override)
            .transpose()?;
        Ok(SavedTab {
            uuid,
            cwd: Some(PathBuf::from(tab.directory.clone())),
            custom_title: tab.custom_title.clone(),
            color: Some(tab.color.clone()),
            repo_group_id: tab.repo_group_id.clone(),
            token_opt_override,
            created_at,
            manual_color: false,
            layout,
            focused_pane,
            panes,
        })
    }

    fn read_tab_context(&mut self, reference: &ContextRef) -> Result<TabContext, ImportError> {
        let bytes = self.read_context_bytes(reference)?;
        let context: TabContext = serde_json::from_slice(&bytes)
            .map_err(|_| ImportError::Malformed("a Swift tab context is malformed"))?;
        if context.schema_version != 1 {
            return Err(ImportError::Unsupported(
                "the Swift tab context version is unsupported",
            ));
        }
        Ok(context)
    }

    fn read_pane_context(
        &mut self,
        reference: &ContextRef,
        pane_id: &str,
    ) -> Result<PaneContext, ImportError> {
        let bytes = self.read_context_bytes(reference)?;
        let context: PaneContext = serde_json::from_slice(&bytes)
            .map_err(|_| ImportError::Malformed("a Swift pane context is malformed"))?;
        if context.schema_version != 1 {
            return Err(ImportError::Unsupported(
                "the Swift pane context version is unsupported",
            ));
        }
        if context.pane_id != pane_id {
            return Err(ImportError::Malformed(
                "a Swift pane context belongs to a different pane",
            ));
        }
        Ok(context)
    }

    fn read_context_bytes(&mut self, reference: &ContextRef) -> Result<Vec<u8>, ImportError> {
        if reference.byte_count > MAX_CONTEXT_JSON_BYTES as usize
            || reference.sha256.len() != 64
            || !reference
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(ImportError::Integrity);
        }
        let root = self.bundle_root.as_ref().ok_or(ImportError::Integrity)?;
        let relative = Path::new(&reference.path);
        if relative.as_os_str().is_empty()
            || relative
                .components()
                .any(|component| !matches!(component, Component::Normal(_)))
        {
            return Err(ImportError::Integrity);
        }
        let path = root.join(relative);
        let canonical = canonical_existing(&path).map_err(|_| ImportError::Integrity)?;
        if !canonical.starts_with(root) {
            return Err(ImportError::Integrity);
        }
        let bytes = read_bounded(&canonical, MAX_CONTEXT_JSON_BYTES)?;
        if bytes.len() != reference.byte_count || sha256_hex(&bytes) != reference.sha256 {
            return Err(ImportError::Integrity);
        }
        self.snapshots
            .push(FileSnapshot::from_bytes(canonical, &bytes));
        Ok(bytes)
    }

    fn bound_scrollback(&mut self, text: String) -> Vec<u8> {
        let original = text.as_bytes();
        if original.len() <= MAX_SCROLLBACK_BYTES {
            return original.to_vec();
        }
        self.summary.truncated_contexts += 1;
        let mut start = original.len() - MAX_SCROLLBACK_BYTES;
        while !text.is_char_boundary(start) {
            start += 1;
        }
        if let Some(newline) = text[start..].find('\n') {
            let candidate = start + newline + 1;
            if candidate < text.len() {
                start = candidate;
            }
        }
        text.as_bytes()[start..].to_vec()
    }
}

fn convert_layout(
    value: &JsonValue,
    seen: &mut HashSet<u64>,
    terminals: &mut Vec<(String, u64, Option<String>)>,
    summary: &mut ImportSummary,
) -> Result<SavedSplitNode, ImportError> {
    let object = value.as_object().ok_or(ImportError::Malformed(
        "the Swift split layout is malformed",
    ))?;
    let version = match object.get("version") {
        None => 1,
        Some(value) => value.as_u64().ok_or(ImportError::Malformed(
            "the Swift split layout version is malformed",
        ))?,
    };
    if version > 1 {
        return Err(ImportError::Unsupported(
            "the Swift split layout version is unsupported",
        ));
    }
    let kind = object
        .get("kind")
        .and_then(JsonValue::as_str)
        .ok_or(ImportError::Malformed(
            "the Swift split layout is missing its pane kind",
        ))?;
    let id_text = object
        .get("id")
        .and_then(JsonValue::as_str)
        .ok_or(ImportError::Malformed(
            "the Swift split layout is missing a stable id",
        ))?;
    let id = uuid_to_u64(parse_uuid(id_text)?);
    if !seen.insert(id) {
        return Err(ImportError::Malformed(
            "the Swift split layout contains duplicate ids",
        ));
    }
    let optional_string = |key: &str| -> Result<Option<String>, ImportError> {
        match object.get(key) {
            None | Some(JsonValue::Null) => Ok(None),
            Some(JsonValue::String(value)) => Ok(Some(value.clone())),
            _ => Err(ImportError::Malformed(
                "the Swift split layout contains an invalid path",
            )),
        }
    };
    let layout = match kind {
        "terminal" => {
            let directory = optional_string("directory")?;
            terminals.push((id_text.to_owned(), id, directory.clone()));
            SavedSplitNode::Terminal { id, directory }
        }
        "textEditor" => SavedSplitNode::Editor {
            id,
            path: optional_string("textEditorPath")?,
        },
        "filePreview" => SavedSplitNode::Preview {
            id,
            path: optional_string("previewFilePath")?,
        },
        "diffViewer" => SavedSplitNode::Diff {
            id,
            file: optional_string("diffFilePath")?,
            directory: optional_string("diffDirectory")?,
            mode: optional_string("diffMode")?,
        },
        "repositoryPane" => SavedSplitNode::Repository {
            id,
            directory: optional_string("repoDirectory")?,
        },
        "dashboard" => {
            if object
                .get("dashboardRepoGroupID")
                .and_then(JsonValue::as_str)
                .is_some()
            {
                summary.dropped_dashboard_group_ids += 1;
            }
            SavedSplitNode::Dashboard {
                id,
                directory: None,
            }
        }
        "split" => {
            let direction = match object.get("direction").and_then(JsonValue::as_str) {
                Some("horizontal") => SavedAxis::Horizontal,
                Some("vertical") => SavedAxis::Vertical,
                _ => {
                    return Err(ImportError::Malformed(
                        "the Swift split direction is invalid",
                    ));
                }
            };
            let ratio = object
                .get("ratio")
                .and_then(JsonValue::as_f64)
                .filter(|ratio| ratio.is_finite() && *ratio > 0.0 && *ratio < 1.0)
                .ok_or(ImportError::Malformed("the Swift split ratio is invalid"))?;
            let first = object.get("first").filter(|item| !item.is_null()).ok_or(
                ImportError::Malformed("the Swift split is missing its first child"),
            )?;
            let second = object.get("second").filter(|item| !item.is_null()).ok_or(
                ImportError::Malformed("the Swift split is missing its second child"),
            )?;
            SavedSplitNode::Split {
                id,
                axis: direction,
                ratios: vec![ratio as f32, (1.0 - ratio) as f32],
                children: vec![
                    convert_layout(first, seen, terminals, summary)?,
                    convert_layout(second, seen, terminals, summary)?,
                ],
            }
        }
        _ => {
            return Err(ImportError::Unsupported(
                "the Swift split layout contains an unsupported pane kind",
            ));
        }
    };
    Ok(layout)
}

fn selected_tab_index(tabs: &[SwiftTab]) -> Result<usize, ImportError> {
    if tabs.is_empty() {
        return Ok(0);
    }
    let mut index_selection = None;
    for (position, tab) in tabs.iter().enumerate() {
        if let Some(index) = tab.selected_index {
            if index >= tabs.len() {
                return Err(ImportError::Malformed(
                    "the Swift selected tab index is out of range",
                ));
            }
            let selected = if index == position { position } else { index };
            if index_selection
                .replace(selected)
                .is_some_and(|previous| previous != selected)
            {
                return Err(ImportError::Malformed(
                    "the Swift window has conflicting selected tab indexes",
                ));
            }
        }
    }
    let mut id_selection = None;
    let ids: HashSet<&str> = tabs
        .iter()
        .filter_map(|tab| tab.selected_tab_id.as_deref())
        .collect();
    if ids.len() > 1 {
        let marked: Vec<usize> = tabs
            .iter()
            .enumerate()
            .filter(|(_, tab)| {
                tab.selected_tab_id
                    .as_deref()
                    .is_some_and(|id| tab.tab_id.as_deref() == Some(id))
            })
            .map(|(index, _)| index)
            .collect();
        if marked.len() == 1 {
            id_selection = Some(marked[0]);
        } else {
            return Err(ImportError::Malformed(
                "the Swift window has conflicting selected tab ids",
            ));
        }
    } else if let Some(id) = ids.into_iter().next() {
        id_selection = tabs
            .iter()
            .position(|tab| tab.tab_id.as_deref() == Some(id));
        if id_selection.is_none() {
            return Err(ImportError::Malformed(
                "the Swift selected tab id is missing from its window",
            ));
        }
    }
    if index_selection.is_some() && id_selection.is_some() && index_selection != id_selection {
        return Err(ImportError::Malformed(
            "the Swift selected tab id and index disagree",
        ));
    }
    Ok(id_selection.or(index_selection).unwrap_or(0))
}

fn parse_uuid(value: &str) -> Result<Uuid, ImportError> {
    Uuid::parse_str(value)
        .map_err(|_| ImportError::Malformed("the Swift restore source contains an invalid id"))
}

/// Swift persists UUIDs while Next's compact restore schema stores u64 pane
/// ids. This stable mapping preserves identity across dry-runs and retries.
fn uuid_to_u64(id: Uuid) -> u64 {
    let bytes = id.as_bytes();
    u64::from_be_bytes(bytes[8..16].try_into().expect("UUID has sixteen bytes"))
}

fn parse_token_override(value: &str) -> Result<TabTokenOptOverride, ImportError> {
    match value {
        "default" => Ok(TabTokenOptOverride::Default),
        "forceOn" => Ok(TabTokenOptOverride::ForceOn),
        "forceOff" => Ok(TabTokenOptOverride::ForceOff),
        _ => Err(ImportError::Unsupported(
            "the Swift token optimization override is unsupported",
        )),
    }
}

fn restored_status(value: &str) -> Result<String, ImportError> {
    match value {
        "idle" | "done" | "running" | "exited" => Ok(value.to_owned()),
        "waitingForInput" | "approvalRequired" | "stuck" => Ok("idle".to_owned()),
        _ => Err(ImportError::Unsupported(
            "the Swift pane status is unsupported",
        )),
    }
}

fn parse_iso8601_unix(value: &str) -> Result<f64, ImportError> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .map_err(|_| ImportError::Malformed("the Swift tab creation date is invalid"))?;
    let unix = parsed.timestamp() as f64 + parsed.timestamp_subsec_nanos() as f64 / 1e9;
    if unix.is_finite() {
        Ok(unix)
    } else {
        Err(ImportError::Malformed(
            "the Swift tab creation date is invalid",
        ))
    }
}

fn canonical_existing(path: &Path) -> Result<PathBuf, std::io::Error> {
    fs::canonicalize(path)
}

fn fallback_uuid(window_index: usize, tab_index: usize) -> Uuid {
    // Reserve a deterministic synthetic range for legacy states that never
    // persisted a pane UUID. The stable window/tab position makes dry-runs
    // and retries produce the same pane identity.
    let high = 0xf000_0000_0000_0000u64 | (window_index as u64 & 0x0fff_ffff_ffff_ffff);
    let low = (tab_index as u64).saturating_add(1);
    Uuid::from_u128(((high as u128) << 64) | low as u128)
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("swift-restore-import-{nonce}"));
        fs::create_dir_all(path.join("bundle/current")).unwrap();
        fs::create_dir_all(path.join("bundle/contexts/windows/0/tabs/a/panes")).unwrap();
        path
    }

    fn ref_for(path: &Path, relative: &str) -> JsonValue {
        let bytes = fs::read(path.join("bundle").join(relative)).unwrap();
        serde_json::json!({
            "path": relative,
            "sha256": sha256_hex(&bytes),
            "byteCount": bytes.len(),
        })
    }

    fn write_fixture(root: &Path) -> SwiftRestoreSource {
        let tab_id = "00000000-0000-0000-0000-000000000001";
        let pane_a = "00000000-0000-0000-0000-00000000000a";
        let pane_b = "00000000-0000-0000-0000-00000000000b";
        let tab_context = serde_json::json!({
            "schemaVersion": 1,
            "tabID": tab_id,
            "scrollbackContent": "legacy context",
            "commandBlocks": [{"command":"private-fixture"}],
            "previewSnapshotPNGData": null,
        });
        let pane_context = serde_json::json!({
            "schemaVersion": 1,
            "paneID": pane_a,
            "scrollbackContent": "pane history",
        });
        fs::write(
            root.join("bundle/contexts/windows/0/tabs/a/context.json"),
            serde_json::to_vec(&tab_context).unwrap(),
        )
        .unwrap();
        fs::write(
            root.join(format!(
                "bundle/contexts/windows/0/tabs/a/panes/{pane_a}.json"
            )),
            serde_json::to_vec(&pane_context).unwrap(),
        )
        .unwrap();
        let tab_ref = ref_for(root, "contexts/windows/0/tabs/a/context.json");
        let pane_ref = ref_for(
            root,
            &format!("contexts/windows/0/tabs/a/panes/{pane_a}.json"),
        );
        let manifest = serde_json::json!({
            "schemaVersion": 1,
            "savedAt": "2026-10-14T10:00:00Z",
            "reason": "autosave",
            "sourceFingerprint": "fixture",
            "saveToken": "new",
            "previousIndexSaveToken": "old",
            "windows": [
                [{
                    "tabID": tab_id,
                    "selectedTabID": tab_id,
                    "customTitle": "Workspace",
                    "color": "blue",
                    "directory": "/tmp/workspace",
                    "selectedIndex": 0,
                    "tokenOptOverride": "forceOn",
                    "splitLayout": {
                        "version": 1,
                        "kind": "split",
                        "id": "00000000-0000-0000-0000-0000000000ff",
                        "direction": "horizontal",
                        "ratio": 0.4,
                        "first": {"version": 1, "kind": "terminal", "id": pane_a, "directory": "/tmp/a"},
                        "second": {"version": 1, "kind": "terminal", "id": pane_b, "directory": "/tmp/b"}
                    },
                    "focusedPaneID": pane_b,
                    "paneIdentities": [
                        {"paneID": pane_a, "directory": "/tmp/a", "aiProvider": "claude", "aiSessionId": "abc-123", "aiSessionIdSource": "observed", "contextRef": pane_ref},
                        {"paneID": pane_b, "directory": "/tmp/b", "contextRef": null}
                    ],
                    "createdAt": "2026-10-14T09:00:00Z",
                    "contextRef": tab_ref
                }],
                [{
                    "tabID": "00000000-0000-0000-0000-000000000002",
                    "selectedTabID": "00000000-0000-0000-0000-000000000002",
                    "customTitle": null,
                    "color": "orange",
                    "directory": "/tmp/other",
                    "selectedIndex": 0,
                    "paneIdentities": [],
                    "splitLayout": null
                }]
            ]
        });
        fs::write(
            root.join("bundle/current/manifest.json"),
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
        let preferences = PlistValue::Dictionary(plist::Dictionary::new());
        preferences
            .to_file_xml(root.join("preferences.plist"))
            .unwrap();
        SwiftRestoreSource {
            bundle_root: root.join("bundle"),
            preferences_file: root.join("preferences.plist"),
        }
    }

    #[test]
    fn imports_nested_bundle_windows_context_split_identity_selection_and_ai() {
        let root = fixture();
        let source = write_fixture(&root);
        let plan = prepare_swift_import(&source).unwrap().unwrap();
        assert_eq!(plan.summary.windows, 2);
        assert_eq!(plan.summary.tabs, 2);
        assert_eq!(plan.summary.panes, 3);
        assert_eq!(
            plan.session.windows[0].tabs[0].custom_title.as_deref(),
            Some("Workspace")
        );
        assert_eq!(
            plan.session.windows[0].tabs[0].token_opt_override,
            Some(TabTokenOptOverride::ForceOn)
        );
        assert_eq!(
            plan.session.windows[0].tabs[0].focused_pane,
            Some(uuid_to_u64(
                parse_uuid("00000000-0000-0000-0000-00000000000b").unwrap()
            ))
        );
        assert!(matches!(
            plan.session.windows[0].tabs[0].layout.as_ref(),
            Some(SavedSplitNode::Split { .. })
        ));
        assert_eq!(
            plan.session.windows[0].tabs[0].panes[0]
                .ai_provider
                .as_deref(),
            Some("claude")
        );
        assert!(
            plan.session.windows[0].tabs[0].panes[0]
                .ai_resume_command
                .as_deref()
                .unwrap()
                .contains("resume")
        );
        assert_eq!(plan.scrollback.values().next().unwrap(), b"pane history");
        assert_eq!(plan.summary.dropped_tab_preview_contexts, 1);
        validate_source_snapshot(&plan).unwrap();
    }

    #[test]
    fn rejects_unknown_bundle_and_layout_versions_and_changed_sidecars() {
        let root = fixture();
        let source = write_fixture(&root);
        let mut manifest: JsonValue = serde_json::from_slice(
            &fs::read(source.bundle_root.join("current/manifest.json")).unwrap(),
        )
        .unwrap();
        manifest["schemaVersion"] = serde_json::json!(2);
        fs::write(
            source.bundle_root.join("current/manifest.json"),
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
        assert!(matches!(
            prepare_swift_import(&source),
            Err(ImportError::Unsupported(_))
        ));
    }

    #[test]
    fn snapshot_validation_detects_mutation_without_exposing_context() {
        let root = fixture();
        let source = write_fixture(&root);
        let plan = prepare_swift_import(&source).unwrap().unwrap();
        fs::write(source.bundle_root.join("current/manifest.json"), b"{}").unwrap();
        assert_eq!(
            validate_source_snapshot(&plan),
            Err(ImportError::SnapshotChanged)
        );
    }

    #[test]
    fn validates_every_referenced_context_before_returning_a_plan() {
        for relative in [
            "contexts/windows/0/tabs/a/context.json",
            "contexts/windows/0/tabs/a/panes/00000000-0000-0000-0000-00000000000a.json",
        ] {
            let root = fixture();
            let source = write_fixture(&root);
            fs::write(
                source.bundle_root.join(relative),
                b"tampered fixture context",
            )
            .unwrap();
            assert!(matches!(
                prepare_swift_import(&source),
                Err(ImportError::Integrity)
            ));
        }
    }

    #[test]
    fn imports_nested_multi_window_preferences_and_tracks_missing_manifest() {
        let root = fixture();
        let source = SwiftRestoreSource {
            bundle_root: root.join("bundle"),
            preferences_file: root.join("preferences.plist"),
        };
        let tab_id = "00000000-0000-0000-0000-000000000021";
        let pane_id = "00000000-0000-0000-0000-000000000022";
        let tab = serde_json::json!({
            "tabID": tab_id,
            "selectedTabID": tab_id,
            "customTitle": "Index tab",
            "color": "purple",
            "directory": "/tmp/index",
            "selectedIndex": 0,
            "scrollbackContent": "index context",
            "paneStates": [{
                "paneID": pane_id,
                "directory": "/tmp/index",
                "scrollbackContent": "pane index context",
                "aiProvider": "claude",
                "aiSessionId": "abc-123",
                "lastInputAt": 0
            }]
        });
        let data = serde_json::to_vec(&serde_json::json!({"windows": [[tab]]})).unwrap();
        let mut dictionary = plist::Dictionary::new();
        dictionary.insert(MULTI_WINDOW_KEY.into(), PlistValue::Data(data));
        dictionary.insert(
            INDEX_TOKEN_KEY.into(),
            PlistValue::String("index-current".into()),
        );
        PlistValue::Dictionary(dictionary)
            .to_file_xml(&source.preferences_file)
            .unwrap();

        let plan = prepare_swift_import(&source).unwrap().unwrap();
        assert_eq!(plan.summary.windows, 1);
        assert_eq!(plan.summary.tabs, 1);
        assert_eq!(plan.summary.panes, 1);
        assert_eq!(plan.session.windows[0].selected, 0);
        assert_eq!(
            plan.session.windows[0].tabs[0].custom_title.as_deref(),
            Some("Index tab")
        );
        assert_eq!(
            plan.scrollback.values().next().unwrap(),
            b"pane index context"
        );
        assert_eq!(
            plan.session.windows[0].tabs[0].panes[0].last_input_at,
            Some(SWIFT_REFERENCE_UNIX_SECONDS)
        );
        validate_source_snapshot(&plan).unwrap();

        fs::write(
            source.bundle_root.join("current/manifest.json"),
            b"appeared during import",
        )
        .unwrap();
        assert_eq!(
            validate_source_snapshot(&plan),
            Err(ImportError::SnapshotChanged)
        );
    }

    #[test]
    fn converts_swift_reference_dates_and_rejects_future_split_versions() {
        let decoded = serde_json::from_str::<PaneState>(
            r#"{"paneID":"00000000-0000-0000-0000-00000000000a","directory":"/tmp","lastInputAt":0}"#,
        ).unwrap();
        assert_eq!(decoded.last_input_at, Some(SWIFT_REFERENCE_UNIX_SECONDS));
        let mut ids = HashSet::new();
        let error = convert_layout(
            &serde_json::json!({"version":2,"kind":"terminal","id":"00000000-0000-0000-0000-00000000000a"}),
            &mut ids,
            &mut Vec::new(),
            &mut ImportSummary::default(),
        ).unwrap_err();
        assert!(matches!(error, ImportError::Unsupported(_)));
    }
}
