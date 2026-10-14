//! Explicit, headless restore import. Source profiles are never written.
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::session_restore::MAX_SCROLLBACK_BYTES;
use chau7_next_core::session_restore::models::SavedSession;
use chau7_next_core::session_restore::transaction::{ContextRef, SourceDecision, source_decision};
use chau7_next_core::swift_restore_import::{self, PreparedSwiftImport, SwiftRestoreSource};
use serde::Deserialize;

const MAX_MANIFEST: u64 = 16 * 1024 * 1024;
type Result<T> = std::result::Result<T, String>;

#[derive(Clone)]
struct Snapshot {
    path: PathBuf,
    content: Option<ContextRef>,
}
impl Snapshot {
    fn read(path: &Path, limit: u64) -> Result<(Option<Vec<u8>>, Self)> {
        let bytes = match File::open(path) {
            Ok(file) => {
                if !file
                    .metadata()
                    .map_err(|_| "Cannot inspect restore source")?
                    .is_file()
                {
                    return Err("Restore source is not a file".into());
                }
                let mut bytes = Vec::new();
                file.take(limit + 1)
                    .read_to_end(&mut bytes)
                    .map_err(|_| "Cannot read restore source")?;
                if bytes.len() as u64 > limit {
                    return Err("Restore source exceeds size bound".into());
                }
                Some(bytes)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return Err("Cannot open restore source".into()),
        };
        let snapshot = Self {
            path: path.into(),
            content: bytes.as_deref().map(ContextRef::new),
        };
        Ok((bytes, snapshot))
    }
    fn validate(&self) -> Result<()> {
        let (_, current) = Self::read(&self.path, MAX_MANIFEST)?;
        if self.content != current.content {
            return Err(
                "Restore source changed during import; retry after saving it normally".into(),
            );
        }
        Ok(())
    }
}

#[derive(Deserialize)]
struct NextIndex {
    #[serde(default)]
    save_token: Option<String>,
    #[serde(default)]
    explicit_clear: bool,
    #[serde(flatten)]
    session: SavedSession,
}
#[derive(Deserialize)]
struct NextBundle {
    schema_version: u32,
    save_token: String,
    previous_index_token: Option<String>,
    #[serde(default)]
    explicit_clear: bool,
    session: SavedSession,
    contexts: BTreeMap<u64, ContextRef>,
}
struct PreparedNext {
    session: SavedSession,
    scrollback: BTreeMap<u64, Vec<u8>>,
    config: Option<Vec<u8>>,
    snapshots: Vec<Snapshot>,
}

enum Prepared {
    Swift(PreparedSwiftImport),
    Next(PreparedNext),
}
impl Prepared {
    fn session(&self) -> &SavedSession {
        match self {
            Self::Swift(p) => &p.session,
            Self::Next(p) => &p.session,
        }
    }
    fn scrollback(&self) -> &BTreeMap<u64, Vec<u8>> {
        match self {
            Self::Swift(p) => &p.scrollback,
            Self::Next(p) => &p.scrollback,
        }
    }
    fn validate(&self) -> Result<()> {
        match self {
            Self::Swift(p) => {
                swift_restore_import::validate_source_snapshot(p).map_err(|e| e.to_string())
            }
            Self::Next(p) => p.snapshots.iter().try_for_each(Snapshot::validate),
        }
    }
    fn report(&self, dry_run: bool) -> serde_json::Value {
        let windows = &self.session().windows;
        let warnings = match self {
            Self::Swift(p) => {
                serde_json::json!({"truncated_contexts":p.summary.truncated_contexts,"dropped_unsupported_ai_identities":p.summary.dropped_unsupported_ai_identities,"dropped_tab_preview_contexts":p.summary.dropped_tab_preview_contexts,"dropped_dashboard_group_ids":p.summary.dropped_dashboard_group_ids})
            }
            Self::Next(_) => serde_json::json!({}),
        };
        serde_json::json!({"source":match self {Self::Swift(_)=>"swift",Self::Next(_)=>"next"},"dry_run":dry_run,"windows":windows.len(),"tabs":windows.iter().map(|w|w.tabs.len()).sum::<usize>(),"panes":windows.iter().flat_map(|w|&w.tabs).map(|t|t.panes.len()).sum::<usize>(),"context_bytes":self.scrollback().values().map(Vec::len).sum::<usize>(),"warnings":warnings})
    }
}
fn swift_source(home: &Path) -> SwiftRestoreSource {
    let source = DataRoot::with_home(home.into(), false);
    SwiftRestoreSource {
        bundle_root: source.swift_restore_bundle_root(),
        preferences_file: source.swift_preferences_file(),
    }
}
fn validate_session(session: &SavedSession) -> Result<()> {
    if session.version != 1 {
        return Err("Unsupported Next session version".into());
    }
    let mut ids = HashSet::new();
    let mut tabs = HashSet::new();
    for window in &session.windows {
        if !window.tabs.is_empty() && window.selected >= window.tabs.len() {
            return Err("Saved window selection is invalid".into());
        }
        for tab in &window.tabs {
            if tab.uuid.is_some_and(|id| !tabs.insert(id)) {
                return Err("Duplicate saved tab identity".into());
            }
            for pane in &tab.panes {
                if !ids.insert(pane.id) {
                    return Err("Duplicate saved pane identity".into());
                }
            }
            if let Some(layout) = &tab.layout {
                let visual = layout.terminal_ids();
                if visual.len() != tab.panes.len()
                    || visual
                        .iter()
                        .any(|id| !tab.panes.iter().any(|p| p.id == *id))
                {
                    return Err("Saved split layout does not match its panes".into());
                }
            }
            if tab
                .focused_pane
                .is_some_and(|id| !tab.panes.iter().any(|p| p.id == id))
            {
                return Err("Saved focused pane is missing".into());
            }
        }
    }
    Ok(())
}
fn prepare_next(root: &DataRoot) -> Result<Option<PreparedNext>> {
    let (index, index_snapshot) = Snapshot::read(&root.session_file(), MAX_MANIFEST)?;
    let (bundle, bundle_snapshot) = Snapshot::read(
        &root.state_dir().join("TabRestoreBundles/current.json"),
        MAX_MANIFEST,
    )?;
    let index = index
        .as_deref()
        .map(serde_json::from_slice::<NextIndex>)
        .transpose()
        .map_err(|_| "Next session index is malformed")?;
    let bundle = bundle
        .as_deref()
        .map(serde_json::from_slice::<NextBundle>)
        .transpose()
        .map_err(|_| "Next restore bundle is malformed")?;
    if bundle.as_ref().is_some_and(|b| b.schema_version != 1) {
        return Err("Unsupported Next restore bundle version".into());
    }
    let mut snapshots = vec![index_snapshot, bundle_snapshot];
    let use_bundle = bundle.as_ref().is_some_and(|b| {
        source_decision(
            Some(&b.save_token),
            b.previous_index_token.as_deref(),
            index.as_ref().and_then(|i| i.save_token.as_deref()),
        ) != SourceDecision::IndexCurrent
    });
    let (session, clear) = if use_bundle {
        let b = bundle.as_ref().expect("selected bundle exists");
        (b.session.clone(), b.explicit_clear)
    } else if let Some(i) = index {
        (i.session, i.explicit_clear)
    } else {
        return Ok(None);
    };
    validate_session(&session)?;
    if clear || session.windows.iter().all(|w| w.tabs.is_empty()) {
        return Ok(None);
    }
    let mut scrollback = BTreeMap::new();
    for pane in session
        .windows
        .iter()
        .flat_map(|w| &w.tabs)
        .flat_map(|t| &t.panes)
        .filter(|p| p.scrollback)
    {
        let path = if use_bundle {
            let reference = bundle
                .as_ref()
                .and_then(|b| b.contexts.get(&pane.id))
                .ok_or("Missing Next context reference")?;
            if !reference.valid_name() || reference.byte_count > MAX_SCROLLBACK_BYTES {
                return Err("Invalid Next context reference".into());
            }
            root.state_dir()
                .join("TabRestoreBundles/contexts")
                .join(format!("{}.txt", reference.sha256))
        } else {
            root.scrollback_dir().join(format!("{}.txt", pane.id))
        };
        let (bytes, snapshot) = Snapshot::read(&path, MAX_SCROLLBACK_BYTES as u64)?;
        let bytes = bytes.ok_or("Missing Next scrollback context")?;
        if std::str::from_utf8(&bytes).is_err() {
            return Err("Next scrollback is not UTF-8".into());
        }
        if use_bundle
            && !bundle
                .as_ref()
                .and_then(|b| b.contexts.get(&pane.id))
                .is_some_and(|r| r.verifies(&bytes))
        {
            return Err("Next context integrity check failed".into());
        }
        snapshots.push(snapshot);
        scrollback.insert(pane.id, bytes);
    }
    let (config, config_snapshot) = Snapshot::read(&root.config_file(), MAX_MANIFEST)?;
    if let Some(config) = &config {
        std::str::from_utf8(config).map_err(|_| "Next configuration is not UTF-8")?;
    }
    snapshots.push(config_snapshot);
    let prepared = PreparedNext {
        session,
        scrollback,
        config,
        snapshots,
    };
    prepared.snapshots.iter().try_for_each(Snapshot::validate)?;
    Ok(Some(prepared))
}
fn has_target_state(root: &DataRoot) -> Result<bool> {
    for path in [
        root.session_file(),
        root.state_dir().join("TabRestoreBundles"),
        root.tab_state_backups_dir(),
        root.scrollback_dir(),
    ] {
        match fs::symlink_metadata(path) {
            Ok(_) => return Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("Cannot inspect destination state".into()),
        }
    }
    Ok(false)
}

/// Production must ask for a source before opening an empty replacement profile.
pub fn requires_source_choice(root: &DataRoot) -> Result<bool> {
    if has_target_state(root)? {
        return Ok(false);
    }
    let source = swift_source(root.home());
    if swift_restore_import::has_swift_restore_source(&source).map_err(|e| e.to_string())? {
        match swift_restore_import::prepare_swift_import(&source) {
            Ok(Some(_)) | Err(_) => return Ok(true),
            Ok(None) => {}
        }
    }
    let next = DataRoot::with_home(root.home().into(), false);
    if root.state_dir() == next.state_dir() {
        return Ok(false);
    }
    match prepare_next(&next) {
        Ok(value) => Ok(value.is_some()),
        Err(_) => Ok(true),
    }
}
struct Lock(File);
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}
fn lock_destination(root: &DataRoot) -> Result<Lock> {
    fs::create_dir_all(root.state_dir()).map_err(|_| "Cannot create destination state folder")?;
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(root.instance_lock_file())
        .map_err(|_| "Cannot open destination instance lock")?;
    file.try_lock()
        .map_err(|_| "Destination is in use by an app or another importer")?;
    Ok(Lock(file))
}
struct Staging(PathBuf);
impl Drop for Staging {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn publish(root: &DataRoot, plan: &Prepared) -> Result<()> {
    let _lock = lock_destination(root)?;
    if has_target_state(root)? {
        return Err("Destination already has restore data; nothing was overwritten".into());
    }
    plan.validate()?;
    let stage = Staging(
        root.state_dir()
            .join(format!(".restore-import-{}", uuid::Uuid::new_v4())),
    );
    let staging_root = DataRoot::with_home(stage.0.clone(), true);
    fs::create_dir_all(staging_root.scrollback_dir())
        .map_err(|_| "Cannot stage restore context")?;
    for (id, bytes) in plan.scrollback() {
        crate::session_store::atomic_write(
            &staging_root.scrollback_dir().join(format!("{id}.txt")),
            bytes,
        )
        .map_err(|_| "Cannot stage restore context")?;
    }
    crate::session_store::save(&staging_root, plan.session())
        .map_err(|_| "Cannot prepare durable restore transaction")?;
    crate::session_store::atomic_write(
        &staging_root
            .state_dir()
            .join("TabRestoreBundles/import-receipt.json"),
        &serde_json::to_vec_pretty(&plan.report(false))
            .map_err(|_| "Cannot encode import receipt")?,
    )
    .map_err(|_| "Cannot stage import receipt")?;
    plan.validate()?;
    if has_target_state(root)? {
        return Err("Destination changed during import; nothing was overwritten".into());
    }
    // The complete manifest and immutable contexts become visible together.
    // Even a crash before the lightweight index leaves a restorable bundle.
    fs::rename(
        staging_root.state_dir().join("TabRestoreBundles"),
        root.state_dir().join("TabRestoreBundles"),
    )
    .map_err(|_| "Cannot publish complete restore bundle")?;
    #[cfg(unix)]
    File::open(root.state_dir())
        .and_then(|f| f.sync_all())
        .map_err(|_| "Cannot sync restore bundle publication")?;
    let index = fs::read(staging_root.session_file())
        .map_err(|_| "Published bundle is valid but its index must be recovered on next launch")?;
    crate::session_store::atomic_write(&root.session_file(), &index)
        .map_err(|_| "Published bundle is valid but its index must be recovered on next launch")?;
    if let Prepared::Next(next) = plan
        && let Some(config) = &next.config
    {
        // Never replace a target configuration, including one created separately.
        if !root.config_file().exists() {
            fs::create_dir_all(root.config_dir())
                .map_err(|_| "Restore published; configuration copy failed")?;
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            match options.open(root.config_file()) {
                Ok(mut file) => {
                    use std::io::Write;
                    file.write_all(config)
                        .and_then(|_| file.sync_all())
                        .map_err(|_| "Restore published; configuration copy failed")?;
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err("Restore published; configuration copy failed".into()),
            }
        }
    }
    Ok(())
}
#[derive(Debug, PartialEq)]
struct Options {
    source: String,
    home: PathBuf,
    dry_run: bool,
}
fn parse_options(args: &[String]) -> Result<Options> {
    let mut source = None;
    let mut home = None;
    let mut dry_run = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--import-chau7-restoration" if source.is_none() => {
                i += 1;
                source = args.get(i).cloned();
            }
            "--source-home" if home.is_none() => {
                i += 1;
                home = args.get(i).map(PathBuf::from);
            }
            "--dry-run" if !dry_run => dry_run = true,
            _ => return Err("Unknown or duplicate restore import argument".into()),
        }
        i += 1;
    }
    let source = source
        .filter(|s| matches!(s.as_str(), "swift" | "next"))
        .ok_or("Select exactly one restore source: swift or next")?;
    let home = home
        .filter(|p| p.is_absolute())
        .ok_or("--source-home must be an explicit absolute home directory")?;
    Ok(Options {
        source,
        home,
        dry_run,
    })
}
fn execute(root: &DataRoot, options: Options) -> Result<serde_json::Value> {
    if has_target_state(root)? {
        return Err("Destination already has restore data; nothing was overwritten".into());
    }
    let plan = if options.source == "swift" {
        Prepared::Swift(
            swift_restore_import::prepare_swift_import(&swift_source(&options.home))
                .map_err(|e| e.to_string())?
                .ok_or("Swift source contains no saved windows")?,
        )
    } else {
        let source = DataRoot::with_home(options.home, false);
        if source.state_dir() == root.state_dir() {
            return Err("Source and destination profiles must differ".into());
        }
        Prepared::Next(prepare_next(&source)?.ok_or("Next source contains no saved windows")?)
    };
    plan.validate()?;
    if !options.dry_run {
        publish(root, &plan)?;
    }
    Ok(plan.report(options.dry_run))
}
/// Returns before any GUI, helper registration, or normal application startup.
pub fn run_cli_if_requested(root: &DataRoot) -> Option<i32> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if !args.iter().any(|s| s == "--import-chau7-restoration") {
        return None;
    }
    match parse_options(&args).and_then(|options| execute(root, options)) {
        Ok(report) => {
            println!("{report}");
            Some(0)
        }
        Err(error) => {
            eprintln!("Restore import refused: {error}");
            Some(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Staging, DataRoot, DataRoot) {
        let dir = Staging(
            std::env::temp_dir().join(format!("chau7-import-test-{}", uuid::Uuid::new_v4())),
        );
        let target = DataRoot::with_channel(dir.0.join("target"), true, true);
        let source = DataRoot::with_home(dir.0.join("source"), false);
        (dir, target, source)
    }
    fn write_source(source: &DataRoot) {
        use chau7_next_core::session_restore::models::{SavedPane, SavedTab, SavedWindow};
        let session = SavedSession {
            version: 1,
            windows: vec![SavedWindow {
                width: 800.,
                height: 600.,
                tabs: vec![SavedTab {
                    panes: vec![SavedPane {
                        id: 1,
                        scrollback: true,
                        ..Default::default()
                    }],
                    focused_pane: Some(1),
                    ..Default::default()
                }],
                ..Default::default()
            }],
        };
        fs::create_dir_all(source.scrollback_dir()).unwrap();
        fs::write(
            source.scrollback_dir().join("1.txt"),
            "synthetic transcript\n",
        )
        .unwrap();
        crate::session_store::save(source, &session).unwrap();
    }
    #[test]
    fn explicit_source_and_absolute_home_are_required() {
        assert!(parse_options(&["--import-chau7-restoration".into(), "next".into()]).is_err());
        assert!(
            parse_options(&[
                "--import-chau7-restoration".into(),
                "both".into(),
                "--source-home".into(),
                "/tmp/x".into()
            ])
            .is_err()
        );
    }
    #[test]
    fn dry_run_has_no_destination_effect_and_apply_is_once_only() {
        let (_dir, target, source) = fixture();
        write_source(&source);
        let options = || Options {
            source: "next".into(),
            home: source.home().into(),
            dry_run: true,
        };
        let before = fs::read(source.session_file()).unwrap();
        let summary = execute(&target, options()).unwrap();
        assert_eq!(summary["tabs"], 1);
        assert!(!target.state_dir().exists());
        assert!(!target.config_dir().exists());
        execute(
            &target,
            Options {
                dry_run: false,
                ..options()
            },
        )
        .unwrap();
        assert_eq!(
            crate::session_store::load(&target).unwrap().windows.len(),
            1
        );
        assert_eq!(
            fs::read(target.scrollback_dir().join("1.txt")).unwrap(),
            b"synthetic transcript\n"
        );
        assert_eq!(fs::read(source.session_file()).unwrap(), before);
        assert!(execute(&target, options()).is_err());
    }
    #[test]
    fn changed_or_corrupt_source_is_rejected_before_publication() {
        let (_dir, target, source) = fixture();
        write_source(&source);
        let plan = Prepared::Next(prepare_next(&source).unwrap().unwrap());
        fs::write(source.session_file(), b"{}").unwrap();
        assert!(publish(&target, &plan).is_err());
        assert!(!target.session_file().exists());
    }
    #[test]
    fn destination_lock_blocks_import_without_activation_or_overwrite() {
        let (_dir, target, source) = fixture();
        write_source(&source);
        let plan = Prepared::Next(prepare_next(&source).unwrap().unwrap());
        let _guard = lock_destination(&target).unwrap();
        assert!(publish(&target, &plan).is_err());
        assert!(!target.session_file().exists());
    }
}
