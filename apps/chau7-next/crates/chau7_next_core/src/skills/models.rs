use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::{collections::BTreeMap, path::PathBuf};

pub const MANAGER: &str = "chau7-next";
pub const MANIFEST_NAME: &str = ".chau7-next-skill.json";
pub const SCHEMA_VERSION: u32 = 1;
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SkillId(pub String);
impl SkillId {
    pub fn new(v: impl AsRef<str>) -> Self {
        Self(v.as_ref().trim().to_string())
    }
}
impl Serialize for SkillId {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.0)
    }
}
impl<'de> Deserialize<'de> for SkillId {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Self::new(String::deserialize(d)?))
    }
}
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Provider(pub String);
impl Provider {
    pub fn new(v: impl AsRef<str>) -> Self {
        Self(v.as_ref().trim().to_lowercase())
    }
    pub fn claude() -> Self {
        Self::new("claude")
    }
    pub fn codex() -> Self {
        Self::new("codex")
    }
    pub fn supported(&self) -> bool {
        matches!(self.0.as_str(), "claude" | "codex")
    }
    pub fn display_name(&self) -> &str {
        match self.0.as_str() {
            "claude" => "Claude",
            "codex" => "Codex",
            "gemini" => "Gemini",
            _ => &self.0,
        }
    }
}
impl Serialize for Provider {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.0)
    }
}
impl<'de> Deserialize<'de> for Provider {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Self::new(String::deserialize(d)?))
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    Bundled,
    User,
    Repo,
    External,
}
impl SourceKind {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Bundled => "bundled",
            Self::User => "user",
            Self::Repo => "repo",
            Self::External => "external",
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub id: SkillId,
    pub kind: SourceKind,
    pub root_directory: PathBuf,
    pub version: Option<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    User,
    Repo,
}
impl Scope {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Repo => "repo",
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    #[serde(rename = "skillID")]
    pub skill_id: SkillId,
    pub provider: Provider,
    pub scope: Scope,
    pub root_directory: PathBuf,
}
impl Target {
    pub fn id(&self) -> String {
        format!(
            "{}:{}:{}",
            self.provider.0,
            self.scope.raw_value(),
            self.skill_id.0
        )
    }
    pub fn skill_directory(&self) -> PathBuf {
        self.root_directory.join(&self.skill_id.0)
    }
    pub fn manifest_path(&self) -> PathBuf {
        self.skill_directory().join(MANIFEST_NAME)
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallState {
    Missing,
    Installed,
    Stale,
    Modified,
    Broken,
    UnmanagedConflict,
    UnsupportedProvider,
    InvalidSource,
}
impl InstallState {
    pub fn display(self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::Installed => "installed",
            Self::Stale => "stale",
            Self::Modified => "modified",
            Self::Broken => "broken",
            Self::UnmanagedConflict => "unmanaged conflict",
            Self::UnsupportedProvider => "unsupported provider",
            Self::InvalidSource => "invalid source",
        }
    }
    pub fn fails_command(self) -> bool {
        matches!(
            self,
            Self::Modified
                | Self::Broken
                | Self::UnmanagedConflict
                | Self::UnsupportedProvider
                | Self::InvalidSource
        )
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileHash {
    pub algorithm: String,
    pub value: String,
}
impl FileHash {
    pub fn sha256(value: String) -> Self {
        Self {
            algorithm: "sha256".into(),
            value,
        }
    }
    pub fn new(raw: &str) -> Self {
        let (a, v) = raw.split_once(':').unwrap_or(("sha256", raw));
        Self {
            algorithm: a.trim().to_lowercase(),
            value: v.trim().to_string(),
        }
    }
    pub fn raw_value(&self) -> String {
        format!("{}:{}", self.algorithm, self.value)
    }
}
impl Serialize for FileHash {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.raw_value())
    }
}
impl<'de> Deserialize<'de> for FileHash {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Self::new(&String::deserialize(d)?))
    }
}
pub type FileHashes = BTreeMap<String, FileHash>;
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    pub schema_version: u32,
    pub managed_by: String,
    pub skill_id: SkillId,
    pub skill_version: Option<String>,
    pub provider: Provider,
    pub scope: Scope,
    pub source_path: Option<PathBuf>,
    pub source_hash: FileHash,
    pub installed_at: String,
    pub files: FileHashes,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Warning,
    Error,
}
impl Severity {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Issue {
    pub severity: Severity,
    pub code: String,
    pub message: String,
    pub path: Option<PathBuf>,
}
impl Issue {
    pub fn error(code: &str, message: impl Into<String>, path: impl Into<PathBuf>) -> Self {
        Self {
            severity: Severity::Error,
            code: code.into(),
            message: message.into(),
            path: Some(path.into()),
        }
    }
}
pub fn has_errors(issues: &[Issue]) -> bool {
    issues.iter().any(|i| i.severity == Severity::Error)
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanAction {
    Install,
    Update,
    NoOp,
    Refuse,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub source: Source,
    pub target: Target,
    pub state: InstallState,
    pub action: PlanAction,
    pub issues: Vec<Issue>,
    pub requires_confirmation: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Snapshot {
    pub target_exists: bool,
    pub manifest: Option<Manifest>,
    pub file_hashes: FileHashes,
    pub issues: Vec<Issue>,
    pub swift_owned: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Detection {
    pub provider: Provider,
    pub is_available: bool,
    pub reasons: Vec<String>,
    pub provider_root: PathBuf,
    pub executable_name: String,
}
