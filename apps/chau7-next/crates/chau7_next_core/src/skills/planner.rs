use super::{manifest, models::*};
pub fn plan(
    source: &Source,
    target: &Target,
    files: &FileHashes,
    issues: &[Issue],
    provider: &Detection,
    installed: &Snapshot,
) -> Plan {
    let mut result = Plan {
        source: source.clone(),
        target: target.clone(),
        state: InstallState::Missing,
        action: PlanAction::Install,
        issues: Vec::new(),
        requires_confirmation: false,
    };
    if has_errors(issues) {
        result.state = InstallState::InvalidSource;
        result.action = PlanAction::Refuse;
        result.issues = issues.to_vec();
        return result;
    }
    if source.id != target.skill_id || !super::validator::valid_name(&target.skill_id.0) {
        result.state = InstallState::InvalidSource;
        result.action = PlanAction::Refuse;
        result.issues.push(Issue::error(
            "invalid-install-target",
            "Skill identity must match a valid target folder name.",
            target.skill_directory(),
        ));
        return result;
    }
    if !provider.is_available || !target.provider.supported() {
        result.state = InstallState::UnsupportedProvider;
        result.action = PlanAction::Refuse;
        result.issues.push(Issue::error(
            "unsupported-provider",
            format!(
                "{} is not available for skill installs.",
                provider.provider.display_name()
            ),
            &provider.provider_root,
        ));
        return result;
    }
    if !installed.target_exists {
        return result;
    }
    if installed.swift_owned {
        result.state = InstallState::UnmanagedConflict;
        result.action = PlanAction::Refuse;
        result.issues.push(Issue::error(
            "swift-owned-target",
            "Existing skill is owned by the production application and must be preserved.",
            target.skill_directory(),
        ));
        return result;
    }
    if !installed.issues.is_empty() {
        result.state = InstallState::Broken;
        result.action = PlanAction::Refuse;
        result.issues = installed.issues.clone();
        return result;
    }
    let Some(manifest) = &installed.manifest else {
        result.state = InstallState::UnmanagedConflict;
        result.action = PlanAction::Refuse;
        result.requires_confirmation = true;
        result.issues.push(Issue::error(
            "unmanaged-conflict",
            "Target skill directory exists but is not managed by Chau7 Next.",
            target.skill_directory(),
        ));
        return result;
    };
    if manifest.files != installed.file_hashes {
        result.state = InstallState::Modified;
        result.action = PlanAction::Refuse;
        result.requires_confirmation = true;
        result.issues.push(Issue {
            severity: Severity::Warning,
            code: "installed-files-modified".into(),
            message: "Installed skill files differ from the Next manifest.".into(),
            path: Some(target.skill_directory()),
        });
        return result;
    }
    if manifest.source_hash == manifest::source_hash(files) {
        result.state = InstallState::Installed;
        result.action = PlanAction::NoOp;
    } else {
        result.state = InstallState::Stale;
        result.action = PlanAction::Update;
    }
    result
}
