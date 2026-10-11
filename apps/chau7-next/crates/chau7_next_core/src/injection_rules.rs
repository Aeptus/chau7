//! AI request context rules. Swift's terminal injection gate is inactive;
//! supported routed requests are mutated by the shared Go proxy.
//! Global edits and repository overrides belong exclusively to Next.
use crate::data_root::DataRoot;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc, Condvar, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Position {
    #[default]
    Prepend,
    Append,
    System,
}
impl Position {
    pub const ALL: [Self; 3] = [Self::Prepend, Self::Append, Self::System];
    pub fn label(self) -> &'static str {
        match self {
            Self::Prepend => "Prepend to prompt",
            Self::Append => "Append to prompt",
            Self::System => "System prompt",
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Trigger {
    AfterClear,
    AfterCompact,
    EveryPrompt,
    FirstSessionPrompt,
}
impl Trigger {
    pub const ALL: [Self; 4] = [
        Self::EveryPrompt,
        Self::FirstSessionPrompt,
        Self::AfterCompact,
        Self::AfterClear,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Self::EveryPrompt => "Every prompt",
            Self::FirstSessionPrompt => "First session prompt",
            Self::AfterCompact => "After /compact",
            Self::AfterClear => "After /clear",
        }
    }
}
fn default_triggers() -> BTreeSet<Trigger> {
    [Trigger::EveryPrompt].into()
}
fn decode_triggers<'de, D: serde::Deserializer<'de>>(d: D) -> Result<BTreeSet<Trigger>, D::Error> {
    let set = BTreeSet::deserialize(d)?;
    Ok(if set.is_empty() {
        default_triggers()
    } else {
        set
    })
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rule {
    #[serde(skip, default = "Uuid::new_v4")]
    pub id: Uuid,
    pub repository: String,
    pub content: String,
    #[serde(default)]
    pub position: Position,
    #[serde(default = "default_triggers", deserialize_with = "decode_triggers")]
    pub triggers: BTreeSet<Trigger>,
}
impl Rule {
    pub fn new(repository: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            repository: repository.into(),
            content: String::new(),
            position: Position::default(),
            triggers: default_triggers(),
        }
    }
    pub fn normalize(&mut self) {
        if self.triggers.is_empty() {
            self.triggers = default_triggers();
        }
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct RulesFile {
    pub rules: Vec<Rule>,
}
impl RulesFile {
    pub fn global(&self) -> Option<&Rule> {
        self.rules.iter().find(|r| r.repository == "*")
    }
    pub fn set_global(&mut self, rule: Option<Rule>) {
        if let Some(mut rule) = rule {
            rule.repository = "*".into();
            rule.normalize();
            if let Some(old) = self.rules.iter_mut().find(|r| r.repository == "*") {
                rule.id = old.id;
                *old = rule;
            } else {
                self.rules.push(rule);
            }
        } else {
            self.rules.retain(|r| r.repository != "*");
        }
    }
    pub fn upsert(&mut self, mut rule: Rule) -> Result<(), String> {
        rule.repository = rule.repository.trim().into();
        if rule.repository.is_empty() || rule.repository == "*" {
            return Err(
                "Enter a repository name or absolute path; use All Repositories for a global rule."
                    .into(),
            );
        }
        rule.normalize();
        if let Some(old) = self.rules.iter_mut().find(|r| r.id == rule.id) {
            *old = rule;
        } else {
            let at = self
                .rules
                .iter()
                .position(|r| r.repository == "*")
                .unwrap_or(self.rules.len());
            self.rules.insert(at, rule);
        }
        Ok(())
    }
    pub fn remove(&mut self, id: Uuid) {
        self.rules.retain(|r| r.id != id);
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LocalOverride {
    #[serde(default)]
    pub disabled: bool,
    #[serde(flatten)]
    pub rule: Rule,
}
#[derive(Clone, Debug)]
pub struct LocalRule {
    pub rule: Option<Rule>,
    pub overridden: bool,
}
pub fn local_path(root: &DataRoot, repo: &Path) -> PathBuf {
    root.repo_overlay_dir(repo).join("injection.json")
}
const MAX_BYTES: u64 = 4 * 1024 * 1024;
fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<Option<T>, String> {
    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(format!("{} exceeds the rule file limit", path.display()));
    }
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|e| format!("{}: {e}", path.display()))
}
pub fn load(root: &DataRoot) -> Result<RulesFile, String> {
    Ok(read_json(&root.proxy_injection_rules_file())?.unwrap_or_default())
}
pub fn load_local(root: &DataRoot, repo: &Path) -> Result<LocalRule, String> {
    if let Some(over) = read_json::<LocalOverride>(&local_path(root, repo))? {
        return Ok(LocalRule {
            rule: if over.disabled { None } else { Some(over.rule) },
            overridden: true,
        });
    }
    let original = DataRoot::repo_metadata_file(repo).with_file_name("injection.json");
    Ok(LocalRule {
        rule: read_json(&original)?,
        overridden: false,
    })
}
fn atomic_json<T: Serialize>(path: &Path, anchor: &Path, value: &T) -> Result<(), String> {
    let parent = path.parent().ok_or("Missing rules directory")?;
    if !path.starts_with(anchor) {
        return Err("Rule path is outside Next storage".into());
    }
    for ancestor in path.ancestors().take_while(|p| p.starts_with(anchor)) {
        if let Ok(meta) = std::fs::symlink_metadata(ancestor) {
            if meta.file_type().is_symlink() {
                return Err("A rule storage path is a symbolic link".into());
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if meta.file_attributes() & 0x400 != 0 {
                    return Err("A rule storage path is a reparse point".into());
                }
            }
        }
    }
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(parent).map_err(|e| e.to_string())?;
    let temp = path.with_extension(format!("{}.tmp", Uuid::new_v4()));
    let result = (|| {
        let bytes = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp).map_err(|e| e.to_string())?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        std::fs::rename(&temp, path).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    result
}
pub fn save(root: &DataRoot, rules: &RulesFile) -> Result<(), String> {
    atomic_json(&root.proxy_injection_rules_file(), root.config_dir(), rules)
}
pub fn save_local(root: &DataRoot, repo: &Path, rule: Option<Rule>) -> Result<(), String> {
    if !repo.is_absolute() {
        return Err("Repository override requires an absolute directory".into());
    }
    let disabled = rule.is_none();
    let mut rule = rule.unwrap_or_else(|| Rule::new(repo.to_string_lossy()));
    rule.repository = repo.to_string_lossy().into();
    rule.normalize();
    atomic_json(
        &local_path(root, repo),
        root.state_dir(),
        &LocalOverride { disabled, rule },
    )
}

/// One serial worker coalesces edits and drains the final snapshot on close.
pub struct Writer {
    state: Arc<(Mutex<Pending>, Condvar)>,
    owners: Arc<AtomicUsize>,
}
#[derive(Default)]
struct Pending {
    global: Option<RulesFile>,
    locals: BTreeMap<PathBuf, Option<Rule>>,
    closed: bool,
    error: Option<String>,
}
impl Writer {
    pub fn new(root: DataRoot) -> Self {
        let state = Arc::new((Mutex::new(Pending::default()), Condvar::new()));
        let worker = state.clone();
        std::thread::spawn(move || {
            loop {
                let (lock, ready) = &*worker;
                let mut pending = lock.lock().unwrap_or_else(|e| e.into_inner());
                while pending.global.is_none() && pending.locals.is_empty() && !pending.closed {
                    pending = ready.wait(pending).unwrap_or_else(|e| e.into_inner());
                }
                if pending.global.is_none() && pending.locals.is_empty() && pending.closed {
                    break;
                }
                let global = pending.global.take();
                let locals = std::mem::take(&mut pending.locals);
                drop(pending);
                let mut error = None;
                if let Some(rules) = global {
                    error = save(&root, &rules).err();
                }
                for (repo, rule) in locals {
                    if let Err(e) = save_local(&root, &repo, rule) {
                        error = Some(e);
                    }
                }
                if error.is_some() {
                    lock.lock().unwrap_or_else(|e| e.into_inner()).error = error;
                }
            }
        });
        Self {
            state,
            owners: Arc::new(AtomicUsize::new(1)),
        }
    }
    pub fn save(&self, rules: RulesFile) {
        let mut state = self.state.0.lock().unwrap_or_else(|e| e.into_inner());
        state.global = Some(rules);
        self.state.1.notify_one();
    }
    pub fn save_local(&self, repo: PathBuf, rule: Option<Rule>) -> Result<(), String> {
        let mut state = self.state.0.lock().unwrap_or_else(|e| e.into_inner());
        if state.locals.len() >= 128 && !state.locals.contains_key(&repo) {
            return Err("Too many pending repository rules".into());
        }
        state.locals.insert(repo, rule);
        self.state.1.notify_one();
        Ok(())
    }
    pub fn take_error(&self) -> Option<String> {
        self.state
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .error
            .take()
    }
}
impl Clone for Writer {
    fn clone(&self) -> Self {
        self.owners.fetch_add(1, Ordering::Relaxed);
        Self {
            state: self.state.clone(),
            owners: self.owners.clone(),
        }
    }
}
impl Drop for Writer {
    fn drop(&mut self) {
        if self.owners.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.state
                .0
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .closed = true;
            self.state.1.notify_one();
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionEvent {
    AfterCompact,
    AfterClear,
}
impl SessionEvent {
    pub fn detect(line: &str) -> Option<Self> {
        match line.split_whitespace().next()?.to_lowercase().as_str() {
            "/compact" => Some(Self::AfterCompact),
            "/clear" => Some(Self::AfterClear),
            _ => None,
        }
    }
}
pub fn accepted(status: &str, input_visible: bool, submitted: bool, running: bool) -> bool {
    matches!(status, "sent" | "skipped")
        || (status == "sent_unverified" && !input_visible && submitted && running)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (PathBuf, DataRoot, PathBuf) {
        let home = std::env::temp_dir().join(format!("next-context-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        let repo = home.join("repo");
        std::fs::create_dir(&repo).unwrap();
        (home, root, repo)
    }
    #[test]
    fn legacy_defaults_normalize_and_ids_are_transient() {
        let rule: Rule =
            serde_json::from_str(r#"{"repository":"my-repo","content":"context","triggers":[]}"#)
                .unwrap();
        assert_eq!(rule.position, Position::Prepend);
        assert_eq!(rule.triggers, default_triggers());
        let text = serde_json::to_string(&rule).unwrap();
        assert!(!text.contains("\"id\""));
        assert_ne!(serde_json::from_str::<Rule>(&text).unwrap().id, rule.id);
    }
    #[test]
    fn specific_rules_precede_wildcard_and_edits_preserve_priority() {
        let mut file = RulesFile::default();
        file.set_global(Some(Rule::new("*")));
        let mut first = Rule::new("one");
        file.upsert(first.clone()).unwrap();
        file.upsert(Rule::new("two")).unwrap();
        first.content = "updated".into();
        file.upsert(first.clone()).unwrap();
        assert_eq!(
            file.rules
                .iter()
                .map(|r| r.repository.as_str())
                .collect::<Vec<_>>(),
            vec!["one", "two", "*"]
        );
        assert_eq!(file.rules[0].content, "updated");
        file.remove(first.id);
        file.set_global(None);
        assert_eq!(file.rules.len(), 1);
        assert!(file.upsert(Rule::new("*")).is_err());
        assert!(file.upsert(Rule::new("  ")).is_err());
    }
    #[test]
    fn override_and_disable_never_change_original_local_rule() {
        let (home, root, repo) = fixture();
        let original = DataRoot::repo_metadata_file(&repo).with_file_name("injection.json");
        std::fs::create_dir_all(original.parent().unwrap()).unwrap();
        let bytes = serde_json::to_vec(&Rule::new("original")).unwrap();
        std::fs::write(&original, &bytes).unwrap();
        assert!(!load_local(&root, &repo).unwrap().overridden);
        let mut rule = Rule::new("replacement");
        rule.content = "own context".into();
        save_local(&root, &repo, Some(rule)).unwrap();
        let local = load_local(&root, &repo).unwrap();
        assert!(local.overridden);
        assert_eq!(local.rule.unwrap().content, "own context");
        save_local(&root, &repo, None).unwrap();
        let local = load_local(&root, &repo).unwrap();
        assert!(local.overridden);
        assert!(local.rule.is_none());
        assert_eq!(std::fs::read(&original).unwrap(), bytes);
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn malformed_override_does_not_silently_fall_back() {
        let (home, root, repo) = fixture();
        let path = local_path(&root, &repo);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "broken").unwrap();
        assert!(load_local(&root, &repo).is_err());
        assert!(save_local(&root, Path::new("relative"), None).is_err());
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn final_global_snapshot_drains_after_last_owner_closes() {
        let (home, root, _) = fixture();
        let writer = Writer::new(root.clone());
        let clone = writer.clone();
        for i in 0..100 {
            let mut file = RulesFile::default();
            let mut rule = Rule::new("*");
            rule.content = i.to_string();
            file.set_global(Some(rule));
            writer.save(file);
        }
        drop(writer);
        let mut file = RulesFile::default();
        let mut rule = Rule::new("*");
        rule.content = "final".into();
        file.set_global(Some(rule));
        clone.save(file);
        drop(clone);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if load(&root)
                .ok()
                .and_then(|f| f.global().map(|r| r.content.clone()))
                .as_deref()
                == Some("final")
            {
                break;
            }
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        std::fs::remove_dir_all(home).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn managed_symlink_target_is_rejected() {
        let (home, root, repo) = fixture();
        let escape = home.join("outside");
        std::fs::create_dir(&escape).unwrap();
        std::fs::create_dir_all(root.repo_overlays_dir()).unwrap();
        std::os::unix::fs::symlink(&escape, root.repo_overlay_dir(&repo)).unwrap();
        assert!(save_local(&root, &repo, Some(Rule::new("context"))).is_err());
        assert!(!escape.join("injection.json").exists());
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn slash_detection_and_accepted_policy_match_current_swift() {
        assert_eq!(
            SessionEvent::detect(" /COMPACT more context"),
            Some(SessionEvent::AfterCompact)
        );
        assert_eq!(
            SessionEvent::detect("/clear\n"),
            Some(SessionEvent::AfterClear)
        );
        assert_eq!(SessionEvent::detect("/clearer"), None);
        assert!(accepted("sent", true, false, false));
        assert!(accepted("skipped", true, false, false));
        assert!(accepted("sent_unverified", false, true, true));
        assert!(!accepted("sent_unverified", true, true, true));
        assert!(!accepted("sent_unverified", false, false, true));
        assert!(!accepted("unknown", false, true, true));
    }
}
