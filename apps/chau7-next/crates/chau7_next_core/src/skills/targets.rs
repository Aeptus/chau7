use super::models::*;
use std::path::Path;
pub fn target(id: SkillId, provider: Provider, scope: Scope, home: &Path, repo: &Path) -> Target {
    let root = if scope == Scope::User { home } else { repo };
    let root_directory = root.join(format!(".{}", provider.0)).join("skills");
    Target {
        skill_id: id,
        provider,
        scope,
        root_directory,
    }
}
pub fn detect(
    provider: Provider,
    home: &Path,
    repo: &Path,
    scope: Scope,
    path: &str,
    explicit: bool,
) -> Detection {
    let root = if scope == Scope::User { home } else { repo };
    let provider_root = root.join(format!(".{}", provider.0));
    let mut reasons = Vec::new();
    if provider_root.is_dir() {
        reasons.push("provider_root_exists".into());
    }
    if executable_exists(&provider.0, path) {
        reasons.push("provider_cli_exists".into());
    }
    if explicit {
        reasons.push("explicitly_requested".into());
    }
    Detection {
        is_available: provider.supported() && !reasons.is_empty(),
        executable_name: provider.0.clone(),
        provider,
        provider_root,
        reasons,
    }
}
pub fn executable_exists(name: &str, path: &str) -> bool {
    std::env::split_paths(path)
        .filter(|p| !p.as_os_str().is_empty())
        .any(|dir| {
            let file = dir.join(format!("{name}{}", std::env::consts::EXE_SUFFIX));
            if !file.is_file() {
                return false;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::metadata(file).is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
            }
            #[cfg(not(unix))]
            {
                true
            }
        })
}
