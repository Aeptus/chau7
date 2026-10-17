//! All current Swift skill commands, using only Next ownership and state.
use super::{installer, manifest, models::*, targets, validator};
use crate::data_root::{DataRoot, HOME_ROOT_ENV};
use std::{
    collections::HashMap,
    io,
    path::{Component, Path, PathBuf},
};
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Result {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}
impl Result {
    fn success(stdout: String) -> Self {
        Self {
            exit_code: 0,
            stdout,
            stderr: String::new(),
        }
    }
    fn failure(stderr: String) -> Self {
        Self {
            exit_code: 1,
            stdout: String::new(),
            stderr: format!("{stderr}\n"),
        }
    }
}
pub struct Runner {
    pub environment: HashMap<String, String>,
    pub current_directory: PathBuf,
    pub executable: Option<PathBuf>,
}
impl Default for Runner {
    fn default() -> Self {
        Self {
            environment: std::env::vars().collect(),
            current_directory: std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
            executable: std::env::current_exe().ok(),
        }
    }
}
struct Options {
    source_root: PathBuf,
    home: PathBuf,
    repo: PathBuf,
    scope: Scope,
    providers: Vec<Provider>,
    explicit: bool,
    subject: Option<String>,
    force: bool,
}
impl Runner {
    pub fn run(&self, args: &[String]) -> Result {
        match args.first().map(String::as_str) {
            None | Some("-h" | "--help" | "help") => Result::success(usage()),
            Some("--version" | "version") => {
                Result::success(format!("Chau7 Next CLI {}\n", env!("CARGO_PKG_VERSION")))
            }
            Some("skills") => match args.get(1).map(String::as_str) {
                None | Some("-h" | "--help" | "help") => Result::success(skills_usage()),
                Some(
                    command @ ("list" | "doctor" | "validate" | "install" | "update" | "sync"
                    | "uninstall" | "diff"),
                ) => self
                    .skills(command, &args[2..])
                    .unwrap_or_else(|e| Result::failure(e.to_string())),
                Some(other) => Result::failure(format!(
                    "Unknown skills command: {other}\n\n{}",
                    skills_usage()
                )),
            },
            Some(other) => Result::failure(format!("Unknown command: {other}\n\n{}", usage())),
        }
    }
    fn options(&self, args: &[String], allow_path: bool) -> io::Result<Options> {
        let real_home = self
            .environment
            .get("HOME")
            .or_else(|| self.environment.get("USERPROFILE"))
            .map(PathBuf::from)
            .unwrap_or_else(|| DataRoot::from_env().home().to_path_buf());
        let mut home = self
            .environment
            .get("CHAU7_NEXT_HOME")
            .or_else(|| self.environment.get(HOME_ROOT_ENV))
            .map(PathBuf::from)
            .unwrap_or(real_home);
        let mut repo = self
            .environment
            .get("CHAU7_NEXT_REPO_ROOT")
            .map(PathBuf::from);
        let mut source = None;
        let mut scope = Scope::User;
        let mut providers = vec![Provider::claude(), Provider::codex()];
        let mut explicit = false;
        let mut subject: Option<String> = None;
        let mut force = false;
        let mut index = 0;
        while index < args.len() {
            let arg = &args[index];
            match arg.as_str() {
                "--source-root" | "--home" | "--repo" | "--scope" | "--provider" => {
                    index += 1;
                    let value = args
                        .get(index)
                        .ok_or_else(|| error(format!("Missing value for {arg}")))?;
                    match arg.as_str() {
                        "--source-root" => source = Some(PathBuf::from(value)),
                        "--home" => home = PathBuf::from(value),
                        "--repo" => repo = Some(PathBuf::from(value)),
                        "--scope" => {
                            scope = match value.to_lowercase().as_str() {
                                "user" => Scope::User,
                                "repo" => Scope::Repo,
                                _ => return Err(error(format!("Unsupported scope: {value}"))),
                            }
                        }
                        "--provider" => {
                            providers = match value.to_lowercase().as_str() {
                                "all" => vec![Provider::claude(), Provider::codex()],
                                "claude" => vec![Provider::claude()],
                                "codex" => vec![Provider::codex()],
                                _ => return Err(error(format!("Unsupported provider: {value}"))),
                            };
                            explicit = true;
                        }
                        _ => unreachable!(),
                    }
                }
                "--force" => force = true,
                _ if arg.starts_with("--") => return Err(error(format!("Unknown option: {arg}"))),
                _ => {
                    if let Some(old) = &mut subject {
                        if allow_path {
                            old.push(' ');
                            old.push_str(arg);
                        } else {
                            return Err(error(format!("Unexpected argument: {arg}")));
                        }
                    } else {
                        subject = Some(arg.clone());
                    }
                }
            }
            index += 1;
        }
        if !allow_path
            && subject
                .as_ref()
                .is_some_and(|s| s != "all" && !validator::valid_name(s))
        {
            return Err(error("Skill id must be lowercase kebab-case"));
        }
        let home = self.resolve(&home);
        let repo = repo
            .map(|p| self.resolve(&p))
            .unwrap_or_else(|| repository_root(&self.current_directory));
        let source_root = source.map(|p| self.resolve(&p)).unwrap_or_else(|| {
            if scope == Scope::Repo {
                DataRoot::repo_skills_source(&repo)
            } else {
                self.environment
                    .get("CHAU7_NEXT_SKILLS_SOURCE_ROOT")
                    .map(|v| self.resolve(Path::new(v)))
                    .unwrap_or_else(|| self.default_source_root())
            }
        });
        Ok(Options {
            source_root,
            home,
            repo,
            scope,
            providers,
            explicit,
            subject,
            force,
        })
    }
    fn resolve(&self, path: &Path) -> PathBuf {
        let text = path.to_string_lossy();
        let home = self
            .environment
            .get("HOME")
            .or_else(|| self.environment.get("USERPROFILE"))
            .map(PathBuf::from)
            .unwrap_or_else(|| DataRoot::from_env().home().to_path_buf());
        let path = if text == "~" {
            home
        } else if let Some(tail) = text.strip_prefix("~/") {
            home.join(tail)
        } else {
            path.to_path_buf()
        };
        normalize(if path.is_absolute() {
            path
        } else {
            self.current_directory.join(path)
        })
    }
    fn default_source_root(&self) -> PathBuf {
        if let Some(parent) = self.executable.as_ref().and_then(|p| p.parent()) {
            for candidate in [
                parent.join("../Resources/Skills"),
                parent.join("../share/chau7-next/skills"),
            ] {
                if candidate.is_dir() {
                    return normalize(candidate);
                }
            }
        }
        for parent in self.current_directory.ancestors() {
            for suffix in ["resources/skills", "apps/chau7-next/resources/skills"] {
                let candidate = parent.join(suffix);
                if candidate.is_dir() {
                    return candidate;
                }
            }
        }
        self.current_directory.join("resources/skills")
    }
    fn sources(&self, opts: &Options, allow_path: bool) -> io::Result<Vec<Source>> {
        if allow_path
            && let Some(subject) = opts
                .subject
                .as_ref()
                .filter(|s| s.as_str() != "all" && (s.contains('/') || s.contains('\\')))
        {
            let root = self.resolve(Path::new(subject));
            let id = root
                .file_name()
                .and_then(|s| s.to_str())
                .ok_or_else(|| error("Invalid source folder name"))?;
            return Ok(vec![Source {
                id: SkillId::new(id),
                kind: SourceKind::External,
                root_directory: root,
                version: None,
            }]);
        }
        let ids = if let Some(subject) = opts.subject.as_ref().filter(|s| s.as_str() != "all") {
            vec![subject.clone()]
        } else {
            if !opts.source_root.is_dir() {
                return Err(error(format!(
                    "Skills source root does not exist: {}",
                    opts.source_root.display()
                )));
            }
            let mut ids = Vec::new();
            for e in std::fs::read_dir(&opts.source_root)? {
                let e = e?;
                let name = e.file_name();
                let name = name
                    .to_str()
                    .ok_or_else(|| error("Skill folder name is not UTF-8"))?;
                if !name.starts_with('.') && e.path().is_dir() {
                    ids.push(name.to_string());
                }
            }
            ids.sort();
            ids
        };
        Ok(ids
            .into_iter()
            .map(|id| Source {
                root_directory: opts.source_root.join(&id),
                id: SkillId::new(id),
                kind: if opts.scope == Scope::Repo {
                    SourceKind::Repo
                } else {
                    SourceKind::Bundled
                },
                version: if opts.scope == Scope::Repo {
                    None
                } else {
                    Some("1.0.0".into())
                },
            })
            .collect())
    }
    fn skills(&self, command: &str, args: &[String]) -> io::Result<Result> {
        let opts = self.options(args, command == "validate")?;
        let sources = self.sources(&opts, command == "validate")?;
        let width = sources
            .iter()
            .map(|s| s.id.0.chars().count())
            .max()
            .unwrap_or(0);
        let title = match command {
            "list" | "doctor" => "Chau7 Next Skills".to_string(),
            other => format!(
                "Chau7 Next Skills {}",
                match other {
                    "validate" => "Validate",
                    "install" => "Install",
                    "update" => "Update",
                    "sync" => "Sync",
                    "uninstall" => "Uninstall",
                    "diff" => "Diff",
                    _ => unreachable!(),
                }
            ),
        };
        let mut lines = vec![title, String::new()];
        let mut failed = false;
        if matches!(command, "list" | "doctor" | "validate") {
            if command == "doctor" {
                lines.push("Sources:".into());
            }
            for source in &sources {
                let issues = validator::validate(&source.root_directory);
                let invalid = has_errors(&issues);
                if command == "validate" {
                    failed |= invalid;
                    lines.push(format!(
                        "- {:width$} {}",
                        source.id.0,
                        if invalid { "invalid" } else { "valid" }
                    ));
                    for issue in issues {
                        lines.push(issue_line(&issue));
                    }
                } else {
                    lines.push(format!(
                        "- {:width$} {} {}",
                        source.id.0,
                        source.kind.raw_value(),
                        if invalid { "invalid" } else { "valid" }
                    ));
                }
            }
            if command != "doctor" {
                return Ok(Result {
                    exit_code: i32::from(failed),
                    stdout: lines.join("\n") + "\n",
                    stderr: String::new(),
                });
            }
        }
        for provider in &opts.providers {
            if command == "doctor" {
                lines.push(String::new());
            }
            lines.push(format!(
                "{} {}:",
                provider.display_name(),
                opts.scope.raw_value()
            ));
            let detection = targets::detect(
                provider.clone(),
                &opts.home,
                &opts.repo,
                opts.scope,
                self.environment
                    .get("PATH")
                    .map(String::as_str)
                    .unwrap_or(""),
                opts.explicit,
            );
            for source in &sources {
                let target = targets::target(
                    source.id.clone(),
                    provider.clone(),
                    opts.scope,
                    &opts.home,
                    &opts.repo,
                );
                let (plan, snapshot) = installer::inspect_plan(source, &target, &detection)?;
                match command {
                    "doctor" => {
                        lines.push(format!("- {:width$} {}", source.id.0, plan.state.display()))
                    }
                    "diff" => {
                        lines.push(format!("- {} {}", source.id.0, plan.state.display()));
                        lines.push(format!(
                            "  source_hash: {}",
                            manifest::source_hash(&manifest::managed_file_hashes(
                                &source.root_directory
                            )?)
                            .raw_value()
                        ));
                        if let Some(value) = snapshot.manifest {
                            lines.push(format!(
                                "  installed_source_hash: {}",
                                value.source_hash.raw_value()
                            ));
                            lines.push(format!(
                                "  installed_files: {}",
                                if snapshot.file_hashes == value.files {
                                    "unchanged"
                                } else {
                                    "modified"
                                }
                            ));
                        } else {
                            lines.push("  installed_source_hash: none".into());
                        }
                        failed |= plan.state.fails_command();
                    }
                    "uninstall" => {
                        let (state, mutated) =
                            installer::uninstall(source, &target, &detection, opts.force)?;
                        let display = if mutated {
                            "uninstalled".into()
                        } else if state == InstallState::Missing {
                            "missing".into()
                        } else {
                            failed = true;
                            format!("refused {}", state.display())
                        };
                        lines.push(format!("- {} {display}", source.id.0));
                    }
                    "install" | "update" | "sync" => {
                        let should_run = command == "install"
                            || (command == "update" && plan.state == InstallState::Stale)
                            || (command == "sync"
                                && matches!(
                                    plan.state,
                                    InstallState::Missing
                                        | InstallState::Stale
                                        | InstallState::UnmanagedConflict
                                ));
                        let result = if should_run {
                            let mut options = installer::Options::for_root(&DataRoot::with_home(
                                opts.home.clone(),
                                true,
                            ));
                            options.force = opts.force;
                            Some(installer::install(source, &target, &detection, &options)?)
                        } else {
                            None
                        };
                        let final_state =
                            result.as_ref().map(|r| r.final_state).unwrap_or(plan.state);
                        failed |= final_state.fails_command();
                        lines.push(format!("- {} {}", source.id.0, final_state.display()));
                        if let Some(path) = result.as_ref().and_then(|r| r.backup_path.as_ref()) {
                            lines.push(format!("  backup: {}", path.display()));
                        }
                        for issue in result
                            .as_ref()
                            .map(|r| r.issues.as_slice())
                            .unwrap_or(&plan.issues)
                        {
                            lines.push(issue_line(issue));
                        }
                    }
                    _ => unreachable!(),
                }
            }
            if command != "doctor" {
                lines.push(String::new());
            }
        }
        Ok(Result {
            exit_code: if command == "doctor" {
                0
            } else {
                i32::from(failed)
            },
            stdout: lines.join("\n") + if command == "doctor" { "\n" } else { "" },
            stderr: String::new(),
        })
    }
}
fn issue_line(issue: &Issue) -> String {
    format!(
        "  {}: {} {}",
        issue.severity.raw_value(),
        issue.code,
        issue
            .path
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_default()
    )
}
fn error(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}
fn normalize(path: PathBuf) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                if out.file_name().is_some_and(|n| n != "..") {
                    out.pop();
                } else if !out.has_root() {
                    out.push(c.as_os_str());
                }
            }
            _ => out.push(c.as_os_str()),
        }
    }
    out
}
fn repository_root(start: &Path) -> PathBuf {
    for p in start.ancestors() {
        if p.join(".git").exists() {
            return p.to_path_buf();
        }
    }
    normalize(start.to_path_buf())
}
fn usage() -> String {
    format!(
        "Chau7 Next CLI\n\nUsage:\n  chau7-next skills <command>\n  chau7-next-cli skills <command>\n\n{}",
        skills_usage()
    )
}
fn skills_usage() -> String {
    "Skills commands:\n  chau7-next skills list [--scope user|repo] [--source-root PATH] [--repo PATH]\n  chau7-next skills doctor [--scope user|repo] [--source-root PATH] [--home PATH] [--repo PATH]\n  chau7-next skills install [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH] [--force]\n  chau7-next skills update [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH]\n  chau7-next skills uninstall [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH] [--force]\n  chau7-next skills validate [skill-id|all|PATH] [--scope user|repo] [--source-root PATH] [--repo PATH]\n  chau7-next skills diff [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH]\n  chau7-next skills sync [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH] [--force]\n\nDirect binary form:\n  chau7-next-cli skills <command>\n\nRepo scope defaults:\n  source: <repo>/.chau7/skills/<skill-id> (read only)\n  targets: <repo>/.claude/skills/<skill-id>, <repo>/.codex/skills/<skill-id>\n\nNext state overrides: CHAU7_NEXT_HOME, CHAU7_NEXT_HOME_ROOT, CHAU7_NEXT_REPO_ROOT, CHAU7_NEXT_SKILLS_SOURCE_ROOT.\n".into()
}
#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;
    struct Fixture {
        root: PathBuf,
        runner: Runner,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("next-cli-{}", Uuid::new_v4()));
            let sources = root.join("sources");
            std::fs::create_dir_all(&sources).unwrap();
            for id in ["demo-a", "demo-b"] {
                let folder = sources.join(id);
                std::fs::create_dir(&folder).unwrap();
                std::fs::write(
                    folder.join("SKILL.md"),
                    format!("---\nname: {id}\ndescription: Example\n---\nInstructions\n"),
                )
                .unwrap();
            }
            let runner = Runner {
                environment: HashMap::from([
                    (
                        "CHAU7_NEXT_HOME".into(),
                        root.join("home").to_string_lossy().into_owned(),
                    ),
                    (
                        "CHAU7_NEXT_SKILLS_SOURCE_ROOT".into(),
                        sources.to_string_lossy().into_owned(),
                    ),
                    ("PATH".into(), String::new()),
                ]),
                current_directory: root.clone(),
                executable: None,
            };
            Self { root, runner }
        }
        fn run(&self, args: &[&str]) -> Result {
            self.runner
                .run(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn all_help_version_errors_and_parser_constraints() {
        let f = Fixture::new();
        assert!(f.run(&[]).stdout.contains("chau7-next-cli"));
        assert!(
            f.run(&["--version"])
                .stdout
                .contains(env!("CARGO_PKG_VERSION"))
        );
        for args in [
            vec!["unknown"],
            vec!["skills", "unknown"],
            vec!["skills", "install", "--provider", "gemini"],
            vec!["skills", "list", "--scope", "unknown"],
            vec!["skills", "list", "--home"],
            vec!["skills", "list", "--unknown"],
            vec!["skills", "install", "demo-a", "demo-b"],
            vec!["skills", "install", "../escape"],
        ] {
            let result = f.run(&args);
            assert_eq!(result.exit_code, 1, "{args:?}");
            assert!(!result.stderr.is_empty());
        }
    }
    #[test]
    fn list_doctor_validate_and_path_validation_report_full_state() {
        let f = Fixture::new();
        assert!(
            f.run(&["skills", "list"])
                .stdout
                .contains("demo-a bundled valid")
        );
        let r = f.run(&["skills", "doctor"]);
        assert_eq!(r.exit_code, 0);
        assert!(r.stdout.contains("unsupported provider"));
        assert_eq!(f.run(&["skills", "validate"]).exit_code, 0);
        assert_eq!(
            f.run(&["skills", "validate", "sources/demo-a"]).exit_code,
            0
        );
        std::fs::create_dir(f.root.join("sources/invalid")).unwrap();
        assert_eq!(f.run(&["skills", "validate", "all"]).exit_code, 1);
        assert!(
            f.run(&["skills", "list", "--source-root", "absent"])
                .stderr
                .contains("does not exist")
        );
    }
    #[test]
    fn explicit_provider_install_default_detection_update_sync_diff_and_uninstall() {
        let f = Fixture::new();
        assert_eq!(f.run(&["skills", "install", "demo-a"]).exit_code, 1);
        let a = ["skills", "install", "demo-a", "--provider", "claude"];
        assert_eq!(f.run(&a).exit_code, 0);
        let home = f.root.join("home");
        assert!(home.join(".claude/skills/demo-a").is_dir());
        assert!(!home.join(".codex/skills/demo-a").exists());
        let diff = f.run(&["skills", "diff", "demo-a", "--provider", "claude"]);
        assert_eq!(diff.exit_code, 0);
        assert!(diff.stdout.contains("installed_files: unchanged"));
        std::fs::write(
            f.root.join("sources/demo-a/SKILL.md"),
            "---\nname: demo-a\ndescription: v2\n---\nUpdated\n",
        )
        .unwrap();
        assert!(
            f.run(&["skills", "diff", "demo-a", "--provider", "claude"])
                .stdout
                .contains("stale")
        );
        assert_eq!(
            f.run(&["skills", "update", "all", "--provider", "claude"])
                .exit_code,
            0
        );
        assert!(!home.join(".claude/skills/demo-b").exists());
        assert_eq!(
            f.run(&["skills", "sync", "all", "--provider", "claude"])
                .exit_code,
            0
        );
        assert!(home.join(".claude/skills/demo-b").exists());
        assert_eq!(
            f.run(&["skills", "uninstall", "all", "--provider", "claude"])
                .exit_code,
            0
        );
        assert!(!home.join(".claude/skills/demo-a").exists());
    }
    #[test]
    fn unmanaged_force_modified_guard_and_provider_all_are_independent() {
        let f = Fixture::new();
        let dest = f.root.join("home/.claude/skills/demo-a");
        std::fs::create_dir_all(&dest).unwrap();
        std::fs::write(dest.join("SKILL.md"), "unmanaged").unwrap();
        assert_eq!(
            f.run(&["skills", "install", "demo-a", "--provider", "claude"])
                .exit_code,
            1
        );
        assert_eq!(
            f.run(&[
                "skills",
                "install",
                "demo-a",
                "--provider",
                "claude",
                "--force"
            ])
            .exit_code,
            0
        );
        std::fs::write(dest.join("SKILL.md"), "user changes").unwrap();
        assert_eq!(
            f.run(&[
                "skills",
                "sync",
                "demo-a",
                "--provider",
                "claude",
                "--force"
            ])
            .exit_code,
            1
        );
        assert_eq!(
            std::fs::read_to_string(dest.join("SKILL.md")).unwrap(),
            "user changes"
        );
        assert_eq!(
            f.run(&["skills", "install", "demo-b", "--provider", "all"])
                .exit_code,
            0
        );
        assert!(f.root.join("home/.codex/skills/demo-b").exists());
    }
    #[test]
    fn repo_scope_preserves_read_only_source_and_uses_own_home_state() {
        let f = Fixture::new();
        let repo = f.root.join("repo");
        let source = DataRoot::repo_skills_source(&repo).join("repo-skill");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(
            source.join("SKILL.md"),
            "---\nname: repo-skill\ndescription: Repo skill\n---\nInstructions\n",
        )
        .unwrap();
        let repo_arg = repo.to_string_lossy();
        let r = f.run(&[
            "skills",
            "sync",
            "all",
            "--scope",
            "repo",
            "--repo",
            &repo_arg,
            "--provider",
            "codex",
        ]);
        assert_eq!(r.exit_code, 0, "{}", r.stderr);
        assert!(repo.join(".codex/skills/repo-skill").is_dir());
        assert!(!source.join(MANIFEST_NAME).exists());
        assert!(
            f.run(&[
                "skills",
                "doctor",
                "--scope",
                "repo",
                "--repo",
                &repo_arg,
                "--provider",
                "codex"
            ])
            .stdout
            .contains("repo-skill installed")
        );
    }
}
