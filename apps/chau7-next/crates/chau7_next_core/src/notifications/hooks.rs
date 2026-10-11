//! Owned CLI notification helpers. Installation plans write only Next paths.
//! Claude adds a session-only `--settings` overlay; Codex composes literal
//! notify argv. Provider configurations and Swift helpers remain read only.
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::{data_root::DataRoot, shell_integration::codex_wrapper_dir};

pub const CLAUDE_HELPER: &str = "chau7-next-claude-hook";
pub const CODEX_HELPER: &str = "chau7-next-codex-notify";
pub const HOOK_EVENTS: [&str; 12] = [
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Notification",
    "Stop",
    "StopFailure",
    "SubagentStop",
    "SessionStart",
    "SessionEnd",
    "Elicitation",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookProvider {
    Claude,
    Codex,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookArtifact {
    pub path: PathBuf,
    pub content: String,
    pub executable: bool,
}

fn literal(path: &Path) -> String {
    serde_json::to_string(&path.to_string_lossy()).expect("path JSON")
}

pub fn claude_helper(events_file: &Path, projects_dir: &Path) -> String {
    include_str!("claude_hook.py")
        .replace(r#""__CHAU7_NEXT_EVENTS_FILE__""#, &literal(events_file))
        .replace(
            r#""__CHAU7_NEXT_CLAUDE_PROJECTS__""#,
            &literal(projects_dir),
        )
}

pub fn codex_helper(events_file: &Path) -> String {
    include_str!("codex_notify.py")
        .replace(r#""__CHAU7_NEXT_EVENTS_FILE__""#, &literal(events_file))
}

fn command(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}

fn owns_hook(hook: &Value, helper: &Path) -> bool {
    hook.get("command")
        .and_then(Value::as_str)
        .is_some_and(|value| value == command(helper) || value == helper.to_string_lossy())
}

/// Replace only our exact helper command. Preserve other commands in a mixed
/// entry, including Swift's helper and names merely containing `chau7`.
pub fn claude_overlay(previous: Option<&[u8]>, helper: &Path) -> Result<String, String> {
    let mut settings = match previous {
        Some(bytes) => {
            serde_json::from_slice::<Value>(bytes).map_err(|_| "Invalid Claude overlay JSON")?
        }
        None => json!({}),
    };
    let object = settings
        .as_object_mut()
        .ok_or("Claude overlay must be an object")?;
    let hooks = object
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("Claude hooks must be an object")?;
    for event in HOOK_EVENTS {
        let entries = hooks
            .entry(event)
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .ok_or("Claude hook entries must be arrays")?;
        for entry in entries.iter_mut() {
            if let Some(inner) = entry.get_mut("hooks").and_then(Value::as_array_mut) {
                inner.retain(|hook| !owns_hook(hook, helper));
            }
        }
        entries.retain(|entry| {
            entry
                .get("hooks")
                .and_then(Value::as_array)
                .is_none_or(|inner| !inner.is_empty())
        });
        entries.push(json!({"matcher":"", "hooks":[{"type":"command","command":command(helper)}]}));
    }
    serde_json::to_string_pretty(&settings).map_err(|error| error.to_string())
}

pub fn claude_overlay_installed(bytes: &[u8], helper: &Path) -> bool {
    let Ok(settings) = serde_json::from_slice::<Value>(bytes) else {
        return false;
    };
    HOOK_EVENTS.iter().all(|event| {
        settings
            .get("hooks")
            .and_then(|hooks| hooks.get(*event))
            .and_then(Value::as_array)
            .is_some_and(|entries| {
                entries.iter().any(|entry| {
                    entry
                        .get("hooks")
                        .and_then(Value::as_array)
                        .is_some_and(|inner| inner.iter().any(|hook| owns_hook(hook, helper)))
                })
            })
    })
}

/// These are the only writable installation targets. Shell startup already
/// discovers this owned bin directory even with proxy analytics disabled.
pub fn artifacts(
    root: &DataRoot,
    provider: HookProvider,
    previous_overlay: Option<&[u8]>,
) -> Result<Vec<HookArtifact>, String> {
    let bin = codex_wrapper_dir(&root.shell_integration_dir());
    let artifact = |path, content, executable| HookArtifact {
        path,
        content,
        executable,
    };
    match provider {
        HookProvider::Claude => {
            let helper = bin.join(CLAUDE_HELPER);
            Ok(vec![
                artifact(
                    helper.clone(),
                    claude_helper(
                        &root.next_claude_hook_events_file(),
                        &root.claude_projects_dir(),
                    ),
                    true,
                ),
                artifact(
                    root.claude_hook_overlay(),
                    claude_overlay(previous_overlay, &helper)?,
                    false,
                ),
                artifact(
                    bin.join("chau7-next-claude-wrapper.py"),
                    include_str!("claude_wrapper.py").replace(
                        r#""__CHAU7_NEXT_OVERLAY__""#,
                        &literal(&root.claude_hook_overlay()),
                    ),
                    false,
                ),
                artifact(
                    bin.join("claude"),
                    include_str!("claude_wrapper.sh").to_string(),
                    true,
                ),
            ])
        }
        HookProvider::Codex => Ok(vec![artifact(
            bin.join(CODEX_HELPER),
            codex_helper(&root.ai_events_log()),
            true,
        )]),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallationStatus {
    NotInstalled,
    Installed,
    Modified,
}

impl InstallationStatus {
    pub fn label(self) -> &'static str {
        match self {
            Self::NotInstalled => "Not installed",
            Self::Installed => "Installed for Next sessions",
            Self::Modified => "Owned installation was modified",
        }
    }
}

fn manifest_path(root: &DataRoot, provider: HookProvider) -> PathBuf {
    root.notification_hooks_dir().join(match provider {
        HookProvider::Claude => "claude-manifest.json",
        HookProvider::Codex => "codex-manifest.json",
    })
}

fn digest(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(bytes))
}

pub fn installation_status(root: &DataRoot, provider: HookProvider) -> InstallationStatus {
    use InstallationStatus::*;
    let Ok(expected) = artifacts(root, provider, None) else {
        return Modified;
    };
    let manifest_path = manifest_path(root, provider);
    let Ok(bytes) = std::fs::read(&manifest_path) else {
        return if !manifest_path.exists()
            && expected
                .iter()
                .all(|item| !item.path.exists() && !item.path.is_symlink())
        {
            NotInstalled
        } else {
            Modified
        };
    };
    let Ok(manifest) = serde_json::from_slice::<std::collections::BTreeMap<String, String>>(&bytes)
    else {
        return Modified;
    };
    if manifest_path.is_symlink() || manifest.len() != expected.len() {
        return Modified;
    }
    for artifact in expected {
        let Ok(relative) = artifact.path.strip_prefix(root.config_dir()) else {
            return Modified;
        };
        let key = relative.to_string_lossy().replace('\\', "/");
        let Ok(content) = std::fs::read(&artifact.path) else {
            return Modified;
        };
        if artifact.path.is_symlink() || manifest.get(&key) != Some(&digest(&content)) {
            return Modified;
        }
        #[cfg(unix)]
        if artifact.executable {
            use std::os::unix::fs::PermissionsExt;
            if std::fs::metadata(&artifact.path).is_err_and(|_| true)
                || std::fs::metadata(&artifact.path)
                    .is_ok_and(|metadata| metadata.permissions().mode() & 0o100 == 0)
            {
                return Modified;
            }
        }
    }
    Installed
}

fn write_owned(path: &Path, bytes: &[u8], executable: bool) -> std::io::Result<()> {
    use std::io::Write;
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::other("Missing installation parent"))?;
    std::fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".next-hook-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(std::fs::Permissions::from_mode(if executable {
                0o700
            } else {
                0o600
            }))?;
        }
        #[cfg(not(unix))]
        let _ = executable;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}

/// Install only the fixed owned targets, refusing to replace modified files.
/// The digest manifest never grants authority over paths supplied by its JSON.
pub fn install(root: &DataRoot, provider: HookProvider) -> Result<(), String> {
    if installation_status(root, provider) == InstallationStatus::Modified {
        return Err("Preserving modified notification helpers; review the owned installation before replacing it.".into());
    }
    let previous = std::fs::read(root.claude_hook_overlay()).ok();
    let desired = artifacts(root, provider, previous.as_deref())?;
    let snapshots = desired
        .iter()
        .map(|item| {
            (
                item.path.clone(),
                std::fs::read(&item.path).ok(),
                item.executable,
            )
        })
        .collect::<Vec<_>>();
    let mut manifest = std::collections::BTreeMap::new();
    let result = (|| {
        for item in &desired {
            let relative = item
                .path
                .strip_prefix(root.config_dir())
                .map_err(|_| "Hook target escaped Next configuration")?;
            manifest.insert(
                relative.to_string_lossy().replace('\\', "/"),
                digest(item.content.as_bytes()),
            );
            write_owned(&item.path, item.content.as_bytes(), item.executable)
                .map_err(|error| error.to_string())?;
        }
        let bytes = serde_json::to_vec_pretty(&manifest).map_err(|error| error.to_string())?;
        write_owned(&manifest_path(root, provider), &bytes, false)
            .map_err(|error| error.to_string())
    })();
    if result.is_err() {
        for (path, previous, executable) in snapshots {
            if let Some(bytes) = previous {
                let _ = write_owned(&path, &bytes, executable);
            } else {
                let _ = std::fs::remove_file(path);
            }
        }
    }
    result
}

pub fn uninstall(root: &DataRoot, provider: HookProvider) -> Result<(), String> {
    match installation_status(root, provider) {
        InstallationStatus::NotInstalled => return Ok(()),
        InstallationStatus::Modified => {
            return Err("Preserving modified notification helpers; no files were removed.".into());
        }
        InstallationStatus::Installed => {}
    }
    for item in artifacts(root, provider, None)? {
        std::fs::remove_file(item.path).map_err(|error| error.to_string())?;
    }
    std::fs::remove_file(manifest_path(root, provider)).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data_root::SWIFT_CLAUDE_HOOK_HELPER;

    #[cfg(unix)]
    #[test]
    fn generated_helpers_and_cli_composition_pass_isolated_fixtures() {
        let folder = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/notifications");
        let output = std::process::Command::new("python3")
            .arg(folder.join("hooks_test.py"))
            .arg("-q")
            .env("NEXT_TEST_SOURCE", folder)
            .output()
            .expect("Python 3 runs the isolated hook fixture suite");
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn overlay_preserves_swift_mixed_hooks_and_permissions_and_is_idempotent() {
        let helper = Path::new("/owned/a'b/next-hook");
        let previous = json!({"permissions":{"deny":["Bash(rm *)"]}, "hooks":{"Stop":[{"matcher":".*", "hooks":[{"type":"command","command":format!("/legacy/{SWIFT_CLAUDE_HOOK_HELPER}")},{"type":"command","command":command(helper)},{"type":"command","command":"custom-chau7-metrics"}]}]}});
        let once = claude_overlay(Some(previous.to_string().as_bytes()), helper).unwrap();
        let twice = claude_overlay(Some(once.as_bytes()), helper).unwrap();
        assert_eq!(once, twice);
        let value: Value = serde_json::from_str(&once).unwrap();
        assert_eq!(value["permissions"], previous["permissions"]);
        assert_eq!(
            value["hooks"]["Stop"][0]["hooks"].as_array().unwrap().len(),
            2
        );
        assert_eq!(
            value["hooks"]["Stop"][0]["hooks"][0]["command"],
            format!("/legacy/{SWIFT_CLAUDE_HOOK_HELPER}")
        );
        assert!(claude_overlay_installed(once.as_bytes(), helper));
        assert!(!claude_overlay_installed(
            once.as_bytes(),
            Path::new("/another/helper")
        ));
    }

    #[test]
    fn install_uninstall_preserves_provider_bytes_and_refuses_modified_helpers() {
        let directory =
            std::env::temp_dir().join(format!("next-hooks-install-{}", uuid::Uuid::new_v4()));
        let root = DataRoot::with_home(directory.clone(), true);
        let provider_file = directory.join("provider-settings.json");
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(&provider_file, b"exact provider bytes\n").unwrap();
        for provider in [HookProvider::Claude, HookProvider::Codex] {
            assert_eq!(
                installation_status(&root, provider),
                InstallationStatus::NotInstalled
            );
            install(&root, provider).unwrap();
            assert_eq!(
                installation_status(&root, provider),
                InstallationStatus::Installed
            );
            install(&root, provider).unwrap();
            let target = artifacts(&root, provider, None).unwrap().remove(0).path;
            let content = std::fs::read(&target).unwrap();
            std::fs::write(&target, b"custom modified helper").unwrap();
            assert_eq!(
                installation_status(&root, provider),
                InstallationStatus::Modified
            );
            assert!(uninstall(&root, provider).is_err());
            assert!(install(&root, provider).is_err());
            assert_eq!(std::fs::read(&target).unwrap(), b"custom modified helper");
            std::fs::write(&target, content).unwrap();
            uninstall(&root, provider).unwrap();
            assert_eq!(
                installation_status(&root, provider),
                InstallationStatus::NotInstalled
            );
        }
        assert_eq!(
            std::fs::read(&provider_file).unwrap(),
            b"exact provider bytes\n"
        );
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn invalid_overlay_fails_without_mutating_other_settings() {
        for value in [
            "bad",
            "[]",
            r#"{"hooks":false}"#,
            r#"{"hooks":{"Stop":false}}"#,
        ] {
            assert!(claude_overlay(Some(value.as_bytes()), Path::new("/own/helper")).is_err());
        }
    }

    #[test]
    fn plans_have_owned_targets_and_escaped_paths_only() {
        let root = DataRoot::with_home(PathBuf::from("/tmp/test user's home"), true);
        for provider in [HookProvider::Claude, HookProvider::Codex] {
            for artifact in artifacts(&root, provider, None).unwrap() {
                assert!(artifact.path.starts_with(root.config_dir()));
                assert!(!artifact.content.contains("__CHAU7_NEXT_"));
            }
        }
        let script = claude_helper(
            Path::new("/tmp/quoted\"line\n/events"),
            Path::new("/provider/projects"),
        );
        assert!(script.contains(r#"EVENTS_FILE = "/tmp/quoted\"line\n/events""#));
    }
}
