use super::{manifest, models::*};
use crate::data_root::DataRoot;
use std::{io, path::Path};
pub fn installed_snapshot(target: &Target) -> io::Result<Snapshot> {
    let dir = target.skill_directory();
    let metadata = match std::fs::symlink_metadata(&dir) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Snapshot::default()),
        Err(error) => return Err(error),
    };
    let mut snapshot = Snapshot {
        target_exists: true,
        swift_owned: std::fs::symlink_metadata(DataRoot::swift_skill_manifest_path(&dir)).is_ok(),
        ..Snapshot::default()
    };
    if metadata.file_type().is_symlink() {
        snapshot.issues.push(Issue::error(
            "target-is-symlink",
            "Target skill directory is a symbolic link.",
            &dir,
        ));
        return Ok(snapshot);
    }
    snapshot.file_hashes = match manifest::managed_file_hashes(&dir) {
        Ok(files) => files,
        Err(error) => {
            snapshot
                .issues
                .push(Issue::error("unreadable-target", error.to_string(), &dir));
            return Ok(snapshot);
        }
    };
    let path = target.manifest_path();
    if !path.exists() {
        return Ok(snapshot);
    }
    let value: Manifest = match std::fs::read(&path)
        .and_then(|data| serde_json::from_slice(&data).map_err(io::Error::other))
    {
        Ok(value) => value,
        Err(_) => {
            snapshot.issues.push(Issue::error(
                "broken-manifest",
                "Next skill manifest could not be decoded.",
                &path,
            ));
            return Ok(snapshot);
        }
    };
    if value.managed_by != MANAGER {
        return Ok(snapshot);
    }
    for (bad, code, message) in [
        (
            value.skill_id != target.skill_id,
            "manifest-skill-id-mismatch",
            "Manifest skill_id does not match the install target.",
        ),
        (
            value.provider != target.provider,
            "manifest-provider-mismatch",
            "Manifest provider does not match the install target.",
        ),
        (
            value.scope != target.scope,
            "manifest-scope-mismatch",
            "Manifest scope does not match the install target.",
        ),
        (
            value.schema_version != SCHEMA_VERSION,
            "manifest-schema-mismatch",
            "Manifest schema is unsupported.",
        ),
    ] {
        if bad {
            snapshot.issues.push(Issue::error(code, message, &path));
        }
    }
    if snapshot.issues.is_empty() {
        snapshot.manifest = Some(value);
    }
    Ok(snapshot)
}
pub fn swift_owned(directory: &Path) -> bool {
    std::fs::symlink_metadata(DataRoot::swift_skill_manifest_path(directory)).is_ok()
}
