use super::models::*;
use crate::data_root::DataRoot;
use sha2::{Digest, Sha256};
use std::{io, path::Path};
pub fn hash(data: &[u8]) -> FileHash {
    FileHash::sha256(
        Sha256::digest(data)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
    )
}
pub fn excluded(name: &str) -> bool {
    name == MANIFEST_NAME
        || name == ".DS_Store"
        || DataRoot::swift_skill_manifest_path(Path::new(""))
            .file_name()
            .is_some_and(|v| v == name)
}
pub fn managed_file_hashes(root: &Path) -> io::Result<FileHashes> {
    let mut files = FileHashes::new();
    if !root.is_dir() {
        return Ok(files);
    }
    walk(root, root, &mut files)?;
    Ok(files)
}
fn walk(root: &Path, dir: &Path, files: &mut FileHashes) -> io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_str().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "Skill filename is not UTF-8")
        })?;
        if excluded(name) {
            continue;
        }
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Skill sources cannot contain symbolic links",
            ));
        }
        if kind.is_dir() {
            walk(root, &path, files)?;
        } else if kind.is_file() {
            let relative = path
                .strip_prefix(root)
                .map_err(io::Error::other)?
                .components()
                .map(|c| {
                    c.as_os_str().to_str().ok_or_else(|| {
                        io::Error::new(io::ErrorKind::InvalidData, "Skill filename is not UTF-8")
                    })
                })
                .collect::<io::Result<Vec<_>>>()?
                .join("/");
            files.insert(relative, hash(&std::fs::read(path)?));
        }
    }
    Ok(())
}
pub fn source_hash(files: &FileHashes) -> FileHash {
    let mut hasher = Sha256::new();
    for (path, value) in files {
        hasher.update(path.as_bytes());
        hasher.update([0]);
        hasher.update(value.raw_value().as_bytes());
        hasher.update([0]);
    }
    FileHash::sha256(
        hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
    )
}
pub fn manifest(
    source: &Source,
    target: &Target,
    installed_at: &str,
    files: FileHashes,
) -> Manifest {
    Manifest {
        schema_version: SCHEMA_VERSION,
        managed_by: MANAGER.into(),
        skill_id: source.id.clone(),
        skill_version: source.version.clone(),
        provider: target.provider.clone(),
        scope: target.scope,
        source_path: Some(source.root_directory.clone()),
        source_hash: source_hash(&files),
        installed_at: installed_at.into(),
        files,
    }
}
pub fn manifest_data(manifest: &Manifest) -> io::Result<Vec<u8>> {
    serde_json::to_vec_pretty(manifest).map_err(io::Error::other)
}
