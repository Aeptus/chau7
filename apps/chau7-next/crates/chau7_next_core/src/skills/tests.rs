use super::*;
use crate::data_root::DataRoot;
use std::{collections::BTreeMap, path::PathBuf};
use uuid::Uuid;
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("next-skill-contract-{}", Uuid::new_v4()));
        std::fs::create_dir_all(path.join("demo")).unwrap();
        Self(path)
    }
    fn source(&self) -> Source {
        Source {
            id: SkillId::new("demo"),
            kind: SourceKind::Bundled,
            root_directory: self.0.join("demo"),
            version: Some("1.0.0".into()),
        }
    }
    fn write(&self, text: &str) {
        std::fs::write(self.0.join("demo/SKILL.md"), text).unwrap();
    }
    fn valid(&self) {
        self.write("---\nname: demo\ndescription: Example\n---\nBody\n");
    }
    fn target(&self) -> Target {
        targets::target(
            SkillId::new("demo"),
            Provider::claude(),
            Scope::User,
            &self.0.join("home"),
            &self.0,
        )
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
#[test]
fn normalized_models_and_algorithm_prefixed_hashes_have_stable_json() {
    let id: SkillId = serde_json::from_str("\"  demo  \"").unwrap();
    assert_eq!(id, SkillId::new("demo"));
    assert_eq!(serde_json::to_string(&id).unwrap(), "\"demo\"");
    let provider: Provider = serde_json::from_str("\" CoDeX \"").unwrap();
    assert_eq!(provider, Provider::codex());
    assert_eq!(Provider::new(" future ").0, "future");
    let hash: FileHash = serde_json::from_str("\" SHA256 : deadbeef \"").unwrap();
    assert_eq!(hash.raw_value(), "sha256:deadbeef");
    assert_eq!(
        serde_json::to_string(&FileHash::new("123")).unwrap(),
        "\"sha256:123\""
    );
    for state in [
        InstallState::Missing,
        InstallState::Installed,
        InstallState::Stale,
        InstallState::Modified,
        InstallState::Broken,
        InstallState::UnmanagedConflict,
        InstallState::UnsupportedProvider,
        InstallState::InvalidSource,
    ] {
        let json = serde_json::to_string(&state).unwrap();
        assert_eq!(serde_json::from_str::<InstallState>(&json).unwrap(), state);
    }
}
#[test]
fn validator_matches_current_frontmatter_optional_folders_and_kebab_names() {
    let f = Fixture::new();
    assert_eq!(
        validator::validate(&f.0.join("missing"))[0].code,
        "missing-folder"
    );
    assert_eq!(
        validator::validate(&f.source().root_directory)[0].code,
        "missing-skill-md"
    );
    for (input, code) in [
        ("Body", "missing-frontmatter"),
        ("---\nname: demo", "unterminated-frontmatter"),
        ("---\nname: demo\n---", "missing-description"),
        ("---\ndescription: Test\n---", "missing-name"),
        ("---\nname: DEMO\ndescription: Test\n---", "invalid-name"),
        (
            "---\nname: other\ndescription: Test\n---",
            "directory-name-mismatch",
        ),
    ] {
        f.write(input);
        assert!(
            validator::validate(&f.source().root_directory)
                .iter()
                .any(|i| i.code == code),
            "{code}"
        );
    }
    f.write("\u{feff}---\r\nname: 'demo'\r\ndescription: \"Example\"\r\nprovider-option: true\r\n---\r\nBody");
    assert!(validator::validate(&f.source().root_directory).is_empty());
    for name in ["assets", "references", "scripts"] {
        let path = f.source().root_directory.join(name);
        std::fs::write(&path, "not a folder").unwrap();
        assert!(
            validator::validate(&f.source().root_directory)
                .iter()
                .any(|i| i.code == "optional-path-not-directory")
        );
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(path).unwrap();
    }
    assert!(validator::validate(&f.source().root_directory).is_empty());
    for name in ["demo", "a1", "demo-skill-2"] {
        assert!(validator::valid_name(name));
    }
    for name in [
        "", "-demo", "demo-", "a--b", "Demo", "a_b", "../demo", "démo",
    ] {
        assert!(!validator::valid_name(name));
    }
}
#[test]
fn manifest_hashes_exclude_own_and_swift_markers_and_include_relative_paths() {
    let f = Fixture::new();
    f.valid();
    let source = f.source();
    std::fs::write(source.root_directory.join(MANIFEST_NAME), "own metadata").unwrap();
    std::fs::write(source.root_directory.join(".DS_Store"), "metadata").unwrap();
    std::fs::write(
        DataRoot::swift_skill_manifest_path(&source.root_directory),
        "read-only production metadata",
    )
    .unwrap();
    let files = manifest::managed_file_hashes(&source.root_directory).unwrap();
    assert_eq!(files.len(), 1);
    assert!(files.contains_key("SKILL.md"));
    assert_eq!(
        manifest::hash(b"hello").value,
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    );
    let a = BTreeMap::from([
        ("a".into(), manifest::hash(b"x")),
        ("b".into(), manifest::hash(b"y")),
    ]);
    let b = BTreeMap::from([
        ("b".into(), manifest::hash(b"y")),
        ("a".into(), manifest::hash(b"x")),
    ]);
    assert_eq!(manifest::source_hash(&a), manifest::source_hash(&b));
    assert_ne!(
        manifest::source_hash(&BTreeMap::from([("a".into(), manifest::hash(b"x"))])),
        manifest::source_hash(&BTreeMap::from([("b".into(), manifest::hash(b"x"))]))
    );
    let value = manifest::manifest(&source, &f.target(), "2026-10-11T00:00:00Z", files);
    let data = manifest::manifest_data(&value).unwrap();
    let json: serde_json::Value = serde_json::from_slice(&data).unwrap();
    for key in [
        "schema_version",
        "managed_by",
        "skill_id",
        "skill_version",
        "provider",
        "scope",
        "source_path",
        "source_hash",
        "installed_at",
        "files",
    ] {
        assert!(json.get(key).is_some(), "{key}");
    }
    assert_eq!(json["managed_by"], MANAGER);
    assert_eq!(json["skill_id"], "demo");
    assert_eq!(json["schema_version"], 1);
    assert_eq!(serde_json::from_slice::<Manifest>(&data).unwrap(), value);
}
#[test]
fn provider_native_roots_explicit_detection_and_unsupported_provider_are_deliberate() {
    let f = Fixture::new();
    let home = f.0.join("home");
    let repo = f.0.join("repo");
    for provider in [Provider::claude(), Provider::codex()] {
        for scope in [Scope::User, Scope::Repo] {
            let t = targets::target(SkillId::new("demo"), provider.clone(), scope, &home, &repo);
            let root = if scope == Scope::User { &home } else { &repo };
            assert_eq!(
                t.skill_directory(),
                root.join(format!(".{}/skills/demo", provider.0))
            );
            assert_eq!(t.id(), format!("{}:{}:demo", provider.0, scope.raw_value()));
        }
    }
    assert!(!targets::detect(Provider::codex(), &home, &repo, Scope::User, "", false).is_available);
    let d = targets::detect(Provider::codex(), &home, &repo, Scope::User, "", true);
    assert!(d.is_available);
    assert_eq!(d.reasons, ["explicitly_requested"]);
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    let d = targets::detect(Provider::codex(), &home, &repo, Scope::User, "", true);
    assert_eq!(d.reasons, ["provider_root_exists", "explicitly_requested"]);
    assert!(
        !targets::detect(Provider::new("gemini"), &home, &repo, Scope::User, "", true).is_available
    );
}
#[test]
fn planner_priorities_warnings_modification_and_manifest_target_metadata_match_swift() {
    let f = Fixture::new();
    f.valid();
    let source = f.source();
    let target = f.target();
    let files = manifest::managed_file_hashes(&source.root_directory).unwrap();
    let available = targets::detect(Provider::claude(), &f.0, &f.0, Scope::User, "", true);
    let plan = planner::plan(
        &source,
        &target,
        &files,
        &[],
        &available,
        &Snapshot::default(),
    );
    assert_eq!(plan.state, InstallState::Missing);
    assert_eq!(plan.action, PlanAction::Install);
    let warning = Issue {
        severity: Severity::Warning,
        code: "warning".into(),
        message: "Warning".into(),
        path: None,
    };
    assert_eq!(
        planner::plan(
            &source,
            &target,
            &files,
            &[warning],
            &available,
            &Snapshot::default()
        )
        .action,
        PlanAction::Install
    );
    let value = manifest::manifest(&source, &target, "t", files.clone());
    let mut installed = Snapshot {
        target_exists: true,
        manifest: Some(value),
        file_hashes: files.clone(),
        ..Snapshot::default()
    };
    assert_eq!(
        planner::plan(&source, &target, &files, &[], &available, &installed).action,
        PlanAction::NoOp
    );
    let mut newer = files.clone();
    newer.insert("new.md".into(), manifest::hash(b"new"));
    assert_eq!(
        planner::plan(&source, &target, &newer, &[], &available, &installed).state,
        InstallState::Stale
    );
    installed
        .file_hashes
        .insert("user.md".into(), manifest::hash(b"user"));
    assert_eq!(
        planner::plan(&source, &target, &newer, &[], &available, &installed).state,
        InstallState::Modified
    );
    let issue = Issue::error("bad", "Invalid", &source.root_directory);
    assert_eq!(
        planner::plan(&source, &target, &files, &[issue], &available, &installed).state,
        InstallState::InvalidSource
    );
}
#[test]
fn inspector_rejects_broken_mismatched_and_unsupported_manifests() {
    let f = Fixture::new();
    f.valid();
    let source = f.source();
    let target = f.target();
    std::fs::create_dir_all(target.skill_directory()).unwrap();
    assert!(
        inspector::installed_snapshot(&target)
            .unwrap()
            .manifest
            .is_none()
    );
    std::fs::write(target.manifest_path(), "bad").unwrap();
    assert_eq!(
        inspector::installed_snapshot(&target).unwrap().issues[0].code,
        "broken-manifest"
    );
    let files = manifest::managed_file_hashes(&source.root_directory).unwrap();
    let value = manifest::manifest(&source, &target, "t", files);
    for (field, code) in [
        ("skill_id", "manifest-skill-id-mismatch"),
        ("provider", "manifest-provider-mismatch"),
        ("scope", "manifest-scope-mismatch"),
        ("schema_version", "manifest-schema-mismatch"),
    ] {
        let mut json = serde_json::to_value(&value).unwrap();
        json[field] = match field {
            "schema_version" => serde_json::json!(99),
            "scope" => serde_json::json!("repo"),
            _ => serde_json::json!("other"),
        };
        std::fs::write(target.manifest_path(), serde_json::to_vec(&json).unwrap()).unwrap();
        let snapshot = inspector::installed_snapshot(&target).unwrap();
        assert!(snapshot.manifest.is_none());
        assert!(snapshot.issues.iter().any(|i| i.code == code));
    }
}
#[cfg(unix)]
#[test]
fn executable_detection_permissions_source_links_and_target_links_are_checked() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let f = Fixture::new();
    let bin = f.0.join("bin");
    std::fs::create_dir(&bin).unwrap();
    let cli = bin.join("codex");
    std::fs::write(&cli, "stub").unwrap();
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o644)).unwrap();
    let path = std::env::join_paths([&bin])
        .unwrap()
        .to_string_lossy()
        .into_owned();
    assert!(!targets::executable_exists("codex", &path));
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(targets::executable_exists("codex", &path));
    f.valid();
    symlink(&cli, f.source().root_directory.join("linked")).unwrap();
    assert!(manifest::managed_file_hashes(&f.source().root_directory).is_err());
    let target = f.target();
    std::fs::create_dir_all(&target.root_directory).unwrap();
    symlink(&f.source().root_directory, target.skill_directory()).unwrap();
    let snapshot = inspector::installed_snapshot(&target).unwrap();
    assert!(
        snapshot
            .issues
            .iter()
            .any(|i| i.code == "target-is-symlink")
    );
}

#[test]
fn bundled_next_skills_validate_and_have_distinct_identities() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../resources/skills");
    for name in ["chau7-next-build", "chau7-next-mcp"] {
        assert!(validator::validate(&root.join(name)).is_empty());
    }
}

#[cfg(unix)]
#[test]
fn broken_links_and_linked_installed_files_are_broken_not_missing() {
    use std::os::unix::fs::symlink;
    let fixture = Fixture::new();
    fixture.valid();
    let target = fixture.target();
    std::fs::create_dir_all(&target.root_directory).unwrap();
    symlink(fixture.0.join("absent"), target.skill_directory()).unwrap();
    let snapshot = inspector::installed_snapshot(&target).unwrap();
    assert!(snapshot.target_exists);
    assert_eq!(snapshot.issues[0].code, "target-is-symlink");
    std::fs::remove_file(target.skill_directory()).unwrap();
    std::fs::create_dir(target.skill_directory()).unwrap();
    symlink(
        fixture.source().root_directory.join("SKILL.md"),
        target.skill_directory().join("SKILL.md"),
    )
    .unwrap();
    let snapshot = inspector::installed_snapshot(&target).unwrap();
    assert_eq!(snapshot.issues[0].code, "unreadable-target");
}

#[cfg(unix)]
#[test]
fn standalone_installer_preserves_swift_helpers_and_forwards_arguments() {
    use std::{os::unix::fs::PermissionsExt, process::Command};
    let fixture = Fixture::new();
    let home = fixture.0.join("test home");
    let bin = home.join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    for name in ["chau7", "chau7-cli"] {
        std::fs::write(bin.join(name), "production helper").unwrap();
    }
    let product = fixture.0.join("fake product");
    std::fs::write(&product, "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\"\n").unwrap();
    std::fs::set_permissions(&product, std::fs::Permissions::from_mode(0o755)).unwrap();
    let workspace = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    for _ in 0..2 {
        let output = Command::new("bash")
            .arg(workspace.join("scripts/install-chau7-next-cli.sh"))
            .env("HOME", &home)
            .env("CHAU7_NEXT_CLI_SKIP_BUILD", "1")
            .env("CHAU7_NEXT_CLI_INSTALL_DIR", &bin)
            .env("CHAU7_NEXT_CLI_PRODUCT_BIN", &product)
            .env(
                "CHAU7_NEXT_CLI_SKILLS_SOURCE",
                workspace.join("resources/skills"),
            )
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let arguments = [
        "skills",
        "validate",
        "path with spaces",
        "$literal",
        "back`tick",
    ];
    let output = Command::new(bin.join("chau7-next"))
        .args(arguments)
        .env_remove("CHAU7_NEXT_CLI_BIN")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .collect::<Vec<_>>(),
        arguments
    );
    for name in ["chau7", "chau7-cli"] {
        assert_eq!(
            std::fs::read_to_string(bin.join(name)).unwrap(),
            "production helper"
        );
    }
    for name in ["chau7-next-build", "chau7-next-mcp"] {
        assert_eq!(
            std::fs::read(
                bin.parent()
                    .unwrap()
                    .join("share/chau7-next/skills")
                    .join(name)
                    .join("SKILL.md")
            )
            .unwrap(),
            std::fs::read(
                workspace
                    .join("resources/skills")
                    .join(name)
                    .join("SKILL.md")
            )
            .unwrap()
        );
    }
}

#[cfg(unix)]
#[test]
fn bundled_installer_uses_sibling_artifacts_without_checkout_or_cargo() {
    use std::{ffi::OsString, os::unix::fs::PermissionsExt, process::Command};

    let fixture = Fixture::new();
    let bundle = fixture.0.join("bundle with spaces/Chau7 Next.app");
    let contents = bundle.join("Contents");
    let resources = contents.join("Resources");
    let macos = contents.join("MacOS");
    std::fs::create_dir_all(resources.join("Skills")).unwrap();
    std::fs::create_dir_all(&macos).unwrap();

    let workspace = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    std::fs::copy(
        workspace.join("scripts/install-chau7-next-cli.sh"),
        resources.join("install-chau7-next-cli.sh"),
    )
    .unwrap();
    for name in ["chau7-next-build", "chau7-next-mcp"] {
        let source = workspace
            .join("resources/skills")
            .join(name)
            .join("SKILL.md");
        let target = resources.join("Skills").join(name);
        std::fs::create_dir_all(&target).unwrap();
        std::fs::copy(source, target.join("SKILL.md")).unwrap();
    }

    let bundled_cli = macos.join("chau7-next-cli");
    std::fs::write(&bundled_cli, "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\"\n").unwrap();
    std::fs::set_permissions(&bundled_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    let app_binary = macos.join("Chau7 Next");
    std::fs::write(&app_binary, "Swift app binary sentinel").unwrap();

    let home = fixture.0.join("test home");
    let bin = home.join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    for name in ["chau7", "chau7-cli"] {
        std::fs::write(bin.join(name), "Swift production helper").unwrap();
    }
    for name in ["chau7-next", "chau7-next-cli"] {
        std::fs::write(bin.join(name), "old Next destination").unwrap();
    }
    let swift_state = home.join(".chau7/swift-state.json");
    std::fs::create_dir_all(swift_state.parent().unwrap()).unwrap();
    std::fs::write(&swift_state, "preserve Swift state").unwrap();

    let skills_destination = home.join(".local/share/chau7-next/skills");
    std::fs::create_dir_all(&skills_destination).unwrap();
    std::fs::write(
        skills_destination.join("existing-user-file"),
        "preserve installed data",
    )
    .unwrap();

    let fake_bin = fixture.0.join("fake commands");
    std::fs::create_dir_all(&fake_bin).unwrap();
    let cargo_marker = fixture.0.join("cargo was called");
    let fake_cargo = fake_bin.join("cargo");
    std::fs::write(
        &fake_cargo,
        "#!/bin/sh\nprintf 'called\\n' >> \"$CARGO_CALL_MARKER\"\nexit 97\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake_cargo, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut path = OsString::from(fake_bin.as_os_str());
    path.push(":");
    path.push(std::env::var_os("PATH").unwrap_or_default());

    let output = Command::new("/bin/bash")
        .arg(resources.join("install-chau7-next-cli.sh"))
        .env("HOME", &home)
        .env("PATH", &path)
        .env("CARGO_CALL_MARKER", &cargo_marker)
        .env_remove("CHAU7_NEXT_CLI_SKIP_BUILD")
        .env_remove("CHAU7_NEXT_CLI_PRODUCT_BIN")
        .env_remove("CHAU7_NEXT_CLI_SKILLS_SOURCE")
        .env_remove("CHAU7_NEXT_CLI_INSTALL_DIR")
        .env_remove("CHAU7_NEXT_CLI_BIN")
        .env_remove("CARGO_TARGET_DIR")
        .env_remove("CARGO_BUILD_TARGET")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "status={} stdout={} stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!cargo_marker.exists(), "bundle installation invoked Cargo");
    assert_eq!(
        std::fs::read_to_string(bin.join("chau7-next-cli")).unwrap(),
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\"\n"
    );
    assert_eq!(
        std::fs::read_to_string(app_binary).unwrap(),
        "Swift app binary sentinel"
    );
    assert_eq!(
        std::fs::read_to_string(swift_state).unwrap(),
        "preserve Swift state"
    );
    for name in ["chau7", "chau7-cli"] {
        assert_eq!(
            std::fs::read_to_string(bin.join(name)).unwrap(),
            "Swift production helper"
        );
    }
    assert_eq!(
        std::fs::read_to_string(skills_destination.join("existing-user-file")).unwrap(),
        "preserve installed data"
    );

    let arguments = [
        "skills",
        "validate",
        "path with spaces",
        "$literal",
        "backtick",
    ];
    let output = Command::new(bin.join("chau7-next"))
        .args(arguments)
        .env_remove("CHAU7_NEXT_CLI_BIN")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .collect::<Vec<_>>(),
        arguments
    );
    for name in ["chau7-next-build", "chau7-next-mcp"] {
        assert_eq!(
            std::fs::read(skills_destination.join(name).join("SKILL.md")).unwrap(),
            std::fs::read(
                workspace
                    .join("resources/skills")
                    .join(name)
                    .join("SKILL.md")
            )
            .unwrap()
        );
    }
}
