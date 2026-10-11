//! Validate, stage, back up and atomically promote skills with rollback.
use super::{inspector, manifest, models::*, planner, validator};
use crate::data_root::DataRoot;
use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::{
    io,
    path::{Path, PathBuf},
};
use uuid::Uuid;
#[derive(Debug, Clone)]
pub struct Options {
    pub force: bool,
    pub installed_at: String,
    pub temporary_directory_root: PathBuf,
    pub backup_directory_root: PathBuf,
}
impl Options {
    pub fn for_root(root: &DataRoot) -> Self {
        Self {
            force: false,
            installed_at: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
            temporary_directory_root: root.skill_staging_dir(),
            backup_directory_root: root.skill_backups_dir(),
        }
    }
}
impl Default for Options {
    fn default() -> Self {
        Self::for_root(&DataRoot::from_env())
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallResult {
    pub initial_plan: Plan,
    pub final_state: InstallState,
    pub did_mutate: bool,
    pub backup_path: Option<PathBuf>,
    pub manifest: Option<Manifest>,
    pub issues: Vec<Issue>,
}
fn refusal(plan: Plan, snapshot: &Snapshot) -> InstallResult {
    InstallResult {
        final_state: plan.state,
        issues: plan.issues.clone(),
        initial_plan: plan,
        did_mutate: false,
        backup_path: None,
        manifest: snapshot.manifest.clone(),
    }
}
fn remove(path: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => std::fs::remove_dir_all(path),
        Ok(_) => std::fs::remove_file(path),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}
struct Cleanup(PathBuf);
impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = remove(&self.0);
    }
}
fn copy_item(source: &Path, dest: &Path, exclude_metadata: bool) -> io::Result<()> {
    let kind = std::fs::symlink_metadata(source)?.file_type();
    if kind.is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Skill tree contains a symbolic link",
        ));
    }
    if kind.is_dir() {
        std::fs::create_dir(dest)?;
        for entry in std::fs::read_dir(source)? {
            let entry = entry?;
            let name = entry.file_name();
            if exclude_metadata && name.to_str().is_some_and(manifest::excluded) {
                continue;
            }
            copy_item(&entry.path(), &dest.join(name), exclude_metadata)?;
        }
    } else if kind.is_file() {
        std::fs::copy(source, dest)?;
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Skill tree contains a special file",
        ));
    }
    Ok(())
}
fn backup(target: &Target, options: &Options) -> io::Result<PathBuf> {
    std::fs::create_dir_all(&options.backup_directory_root)?;
    let safe: String = options
        .installed_at
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '-'
            }
        })
        .collect();
    let base = format!("{}-{safe}", target.skill_id.0);
    let mut candidate = options.backup_directory_root.join(&base);
    let mut suffix = 2;
    while candidate.exists() {
        candidate = options
            .backup_directory_root
            .join(format!("{base}-{suffix}"));
        suffix += 1;
    }
    if let Err(error) = copy_item(&target.skill_directory(), &candidate, false) {
        let _ = remove(&candidate);
        return Err(error);
    }
    Ok(candidate)
}
pub fn inspect_plan(
    source: &Source,
    target: &Target,
    provider: &Detection,
) -> io::Result<(Plan, Snapshot)> {
    let mut issues = validator::validate(&source.root_directory);
    let files = if has_errors(&issues) {
        FileHashes::new()
    } else {
        match manifest::managed_file_hashes(&source.root_directory) {
            Ok(files) => files,
            Err(error) => {
                issues.push(Issue::error(
                    "unreadable-source",
                    error.to_string(),
                    &source.root_directory,
                ));
                FileHashes::new()
            }
        }
    };
    let snapshot = inspector::installed_snapshot(target)?;
    Ok((
        planner::plan(source, target, &files, &issues, provider, &snapshot),
        snapshot,
    ))
}
pub fn install(
    source: &Source,
    target: &Target,
    provider: &Detection,
    options: &Options,
) -> io::Result<InstallResult> {
    install_with(
        source,
        target,
        provider,
        options,
        |_| Ok(()),
        |from, to| std::fs::rename(from, to),
    )
}
fn install_with(
    source: &Source,
    target: &Target,
    provider: &Detection,
    options: &Options,
    inspect_stage: impl FnOnce(&Path) -> io::Result<()>,
    promote: impl FnOnce(&Path, &Path) -> io::Result<()>,
) -> io::Result<InstallResult> {
    let (plan, snapshot) = inspect_plan(source, target, provider)?;
    if plan.action == PlanAction::NoOp {
        return Ok(refusal(plan, &snapshot));
    }
    if plan.action == PlanAction::Refuse
        && !(options.force
            && plan.state == InstallState::UnmanagedConflict
            && !snapshot.swift_owned)
    {
        return Ok(refusal(plan, &snapshot));
    }
    let files = manifest::managed_file_hashes(&source.root_directory)?;
    std::fs::create_dir_all(&options.temporary_directory_root)?;
    let container = options
        .temporary_directory_root
        .join(format!("chau7-next-skill-install-{}", Uuid::new_v4()));
    std::fs::create_dir(&container)?;
    let _cleanup = Cleanup(container.clone());
    let staged = container.join(&target.skill_id.0);
    copy_item(&source.root_directory, &staged, true)?;
    let value = manifest::manifest(source, target, &options.installed_at, files.clone());
    std::fs::write(staged.join(MANIFEST_NAME), manifest::manifest_data(&value)?)?;
    inspect_stage(&staged)?;
    let mut issues = validator::validate(&staged);
    if manifest::managed_file_hashes(&staged)? != files {
        issues.push(Issue::error(
            "source-changed-during-install",
            "Staged source differs from the validated files.",
            &staged,
        ));
    }
    if has_errors(&issues) {
        let mut result = refusal(plan, &snapshot);
        result.final_state = InstallState::InvalidSource;
        result.issues = issues;
        return Ok(result);
    }
    let dir = target.skill_directory();
    let parent = dir
        .parent()
        .ok_or_else(|| io::Error::other("Target has no parent"))?;
    std::fs::create_dir_all(parent)?;
    // Final promotion is always on the target filesystem, even when state is elsewhere.
    let promotion = parent.join(format!(".chau7-next-skill-promote-{}", Uuid::new_v4()));
    let _promote_cleanup = Cleanup(promotion.clone());
    copy_item(&staged, &promotion, false)?;
    let fresh = inspector::installed_snapshot(target)?;
    if fresh != snapshot {
        let mut result = refusal(plan, &fresh);
        result.final_state = InstallState::Modified;
        result.issues = vec![Issue::error(
            "target-changed-during-install",
            "Target changed while installation was staged; preserving current files.",
            &dir,
        )];
        return Ok(result);
    }
    let backup_path = if snapshot.target_exists {
        Some(backup(target, options)?)
    } else {
        None
    };
    let rollback = parent.join(format!(".chau7-next-skill-replace-{}", Uuid::new_v4()));
    if snapshot.target_exists {
        std::fs::rename(&dir, &rollback)?;
    }
    if let Err(error) = promote(&promotion, &dir) {
        if snapshot.target_exists {
            remove(&dir)?;
            std::fs::rename(&rollback, &dir).map_err(|rollback_error| {
                io::Error::other(format!(
                    "Promotion failed: {error}; rollback retained at {}: {rollback_error}",
                    rollback.display()
                ))
            })?;
        }
        return Err(error);
    }
    if snapshot.target_exists {
        let _ = remove(&rollback);
    }
    let (final_plan, _) = inspect_plan(source, target, provider)?;
    Ok(InstallResult {
        initial_plan: plan,
        final_state: final_plan.state,
        did_mutate: true,
        backup_path,
        manifest: Some(value),
        issues: final_plan.issues,
    })
}
/// Uninstall uses the same ownership and modification policy as installation.
pub fn uninstall(
    source: &Source,
    target: &Target,
    provider: &Detection,
    force: bool,
) -> io::Result<(InstallState, bool)> {
    let (plan, snapshot) = inspect_plan(source, target, provider)?;
    if plan.state == InstallState::Missing {
        return Ok((InstallState::Missing, false));
    }
    let allowed = matches!(plan.state, InstallState::Installed | InstallState::Stale)
        || (force
            && matches!(
                plan.state,
                InstallState::Modified | InstallState::UnmanagedConflict | InstallState::Broken
            ));
    if !allowed || snapshot.swift_owned {
        return Ok((plan.state, false));
    }
    if inspector::installed_snapshot(target)? != snapshot {
        return Ok((InstallState::Modified, false));
    }
    remove(&target.skill_directory())?;
    Ok((plan.state, true))
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        source: Source,
        target: Target,
        detection: Detection,
        options: Options,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("next-skills-{}", Uuid::new_v4()));
            std::fs::create_dir_all(&root).unwrap();
            let source_dir = root.join("sources/demo");
            std::fs::create_dir_all(&source_dir).unwrap();
            std::fs::write(
                source_dir.join("SKILL.md"),
                "---\nname: demo\ndescription: Demo skill\n---\nInstructions\n",
            )
            .unwrap();
            let source = Source {
                id: SkillId::new("demo"),
                kind: SourceKind::Bundled,
                root_directory: source_dir,
                version: Some("1.0.0".into()),
            };
            let target = super::super::targets::target(
                source.id.clone(),
                Provider::claude(),
                Scope::User,
                &root.join("home"),
                &root,
            );
            let detection = Detection {
                provider: Provider::claude(),
                is_available: true,
                reasons: vec!["explicitly_requested".into()],
                provider_root: root.join("home/.claude"),
                executable_name: "claude".into(),
            };
            let options = Options::for_root(&DataRoot::with_home(root.join("home"), true));
            Self {
                root,
                source,
                target,
                detection,
                options,
            }
        }
        fn run(&self) -> InstallResult {
            install(&self.source, &self.target, &self.detection, &self.options).unwrap()
        }
        fn change_source(&self) {
            std::fs::write(
                self.source.root_directory.join("SKILL.md"),
                "---\nname: demo\ndescription: Demo v2\n---\nUpdated\n",
            )
            .unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn installation_noop_update_and_backup_preserve_source_and_manifest() {
        let f = Fixture::new();
        let before = manifest::managed_file_hashes(&f.source.root_directory).unwrap();
        let result = f.run();
        assert!(result.did_mutate);
        assert_eq!(result.final_state, InstallState::Installed);
        assert_eq!(
            manifest::managed_file_hashes(&f.source.root_directory).unwrap(),
            before
        );
        assert!(!f.source.root_directory.join(MANIFEST_NAME).exists());
        let result = f.run();
        assert!(!result.did_mutate);
        assert_eq!(result.initial_plan.action, PlanAction::NoOp);
        f.change_source();
        let result = f.run();
        assert_eq!(result.initial_plan.state, InstallState::Stale);
        assert!(result.backup_path.unwrap().join(MANIFEST_NAME).is_file());
        let snapshot = inspector::installed_snapshot(&f.target).unwrap();
        assert_eq!(snapshot.manifest.unwrap().managed_by, MANAGER);
    }
    #[test]
    fn unmanaged_requires_force_and_modified_files_are_never_overwritten() {
        let mut f = Fixture::new();
        std::fs::create_dir_all(f.target.skill_directory()).unwrap();
        std::fs::write(f.target.skill_directory().join("SKILL.md"), "user original").unwrap();
        assert_eq!(f.run().final_state, InstallState::UnmanagedConflict);
        f.options.force = true;
        let result = f.run();
        assert!(result.did_mutate);
        assert_eq!(
            std::fs::read_to_string(result.backup_path.unwrap().join("SKILL.md")).unwrap(),
            "user original"
        );
        std::fs::write(f.target.skill_directory().join("SKILL.md"), "user edits").unwrap();
        let result = f.run();
        assert_eq!(result.final_state, InstallState::Modified);
        assert!(!result.did_mutate);
        assert_eq!(
            std::fs::read_to_string(f.target.skill_directory().join("SKILL.md")).unwrap(),
            "user edits"
        );
    }
    #[test]
    fn swift_owned_target_is_preserved_even_with_explicit_force() {
        let mut f = Fixture::new();
        std::fs::create_dir_all(f.target.skill_directory()).unwrap();
        let marker = DataRoot::swift_skill_manifest_path(&f.target.skill_directory());
        std::fs::write(&marker, "production metadata").unwrap();
        std::fs::write(
            f.target.skill_directory().join("SKILL.md"),
            "production source",
        )
        .unwrap();
        f.options.force = true;
        assert!(!f.run().did_mutate);
        assert!(
            !uninstall(&f.source, &f.target, &f.detection, true)
                .unwrap()
                .1
        );
        assert_eq!(
            std::fs::read_to_string(marker).unwrap(),
            "production metadata"
        );
    }
    #[test]
    fn promotion_failure_rolls_back_and_staged_validation_failure_preserves_target() {
        let f = Fixture::new();
        f.run();
        let before = std::fs::read(f.target.skill_directory().join("SKILL.md")).unwrap();
        f.change_source();
        let error = install_with(
            &f.source,
            &f.target,
            &f.detection,
            &f.options,
            |_| Ok(()),
            |_, _| Err(io::Error::other("injected promotion failure")),
        )
        .unwrap_err();
        assert!(error.to_string().contains("injected"));
        assert_eq!(
            std::fs::read(f.target.skill_directory().join("SKILL.md")).unwrap(),
            before
        );
        let result = install_with(
            &f.source,
            &f.target,
            &f.detection,
            &f.options,
            |stage| std::fs::write(stage.join("SKILL.md"), "invalid"),
            |from, to| std::fs::rename(from, to),
        )
        .unwrap();
        assert_eq!(result.final_state, InstallState::InvalidSource);
        assert!(!result.did_mutate);
        assert_eq!(
            std::fs::read(f.target.skill_directory().join("SKILL.md")).unwrap(),
            before
        );
        assert!(
            std::fs::read_dir(&f.options.temporary_directory_root)
                .unwrap()
                .next()
                .is_none()
        );
    }
    #[test]
    fn invalid_unsupported_broken_mismatched_and_unknown_schema_refuse() {
        let mut f = Fixture::new();
        f.detection.is_available = false;
        assert_eq!(f.run().final_state, InstallState::UnsupportedProvider);
        f.detection.is_available = true;
        std::fs::write(f.source.root_directory.join("SKILL.md"), "invalid").unwrap();
        assert_eq!(f.run().final_state, InstallState::InvalidSource);
        f.change_source();
        f.run();
        std::fs::write(f.target.manifest_path(), "invalid").unwrap();
        assert_eq!(f.run().final_state, InstallState::Broken);
    }
    #[test]
    fn uninstall_refuses_edits_and_removes_only_own_managed_target() {
        let f = Fixture::new();
        f.run();
        std::fs::write(f.target.skill_directory().join("SKILL.md"), "user edits").unwrap();
        assert_eq!(
            uninstall(&f.source, &f.target, &f.detection, false).unwrap(),
            (InstallState::Modified, false)
        );
        assert_eq!(
            uninstall(&f.source, &f.target, &f.detection, true).unwrap(),
            (InstallState::Modified, true)
        );
        assert_eq!(
            uninstall(&f.source, &f.target, &f.detection, false).unwrap(),
            (InstallState::Missing, false)
        );
    }
}
