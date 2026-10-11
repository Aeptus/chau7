//! Owner-only relay credential validation shared with the Swift host and Go agent.
//! Secret material stays private and is never included in diagnostics.
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Deserialize;
use std::path::Path;
#[cfg(unix)]
use std::{fs::OpenOptions, io::Read};

pub const MAX_CREDENTIAL_BYTES: u64 = 8192;
pub const PROVISIONING_ERROR: &str = "Remote needs an owner-only credential file matching this device. Run chau7-remote identity --state <Next-state.json>, then chau7-remote provision --bundle <file> --state <Next-state.json>.";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RelayCredentials {
    device_id: String,
    key_id: String,
    mac_secret: String,
    ios_secret: String,
}

/// Public metadata only. Returning this proves both role secrets were validated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedCredentials {
    pub device_id: String,
    pub key_id: String,
}

pub fn valid_identifier(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}

fn strong_secret(value: &str) -> bool {
    value.len() == 43
        && URL_SAFE_NO_PAD
            .decode(value)
            .is_ok_and(|bytes| bytes.len() == 32 && URL_SAFE_NO_PAD.encode(bytes) == value)
}

pub fn validate_bytes(bytes: &[u8], device_id: &str) -> Result<ValidatedCredentials, &'static str> {
    if bytes.len() as u64 > MAX_CREDENTIAL_BYTES || !valid_identifier(device_id, 128) {
        return Err(PROVISIONING_ERROR);
    }
    let credentials: RelayCredentials =
        serde_json::from_slice(bytes).map_err(|_| PROVISIONING_ERROR)?;
    if credentials.device_id != device_id
        || !valid_identifier(&credentials.key_id, 32)
        || !strong_secret(&credentials.mac_secret)
        || !strong_secret(&credentials.ios_secret)
        || credentials.mac_secret == credentials.ios_secret
    {
        return Err(PROVISIONING_ERROR);
    }
    Ok(ValidatedCredentials {
        device_id: credentials.device_id,
        key_id: credentials.key_id,
    })
}

/// Validate the opened descriptor, never a separate racy pathname stat. FIFO,
/// directory, symlink, oversized, foreign-owner and broad-mode files are refused.
#[cfg(unix)]
pub fn load(path: &Path, device_id: &str) -> Result<ValidatedCredentials, &'static str> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| PROVISIONING_ERROR)?;
    let metadata = file.metadata().map_err(|_| PROVISIONING_ERROR)?;
    // SAFETY: getuid has no pointer arguments or preconditions.
    let owner = unsafe { libc::getuid() };
    if !metadata.is_file()
        || metadata.uid() != owner
        || !matches!(metadata.mode() & 0o777, 0o600 | 0o400)
        || metadata.len() > MAX_CREDENTIAL_BYTES
    {
        return Err(PROVISIONING_ERROR);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_CREDENTIAL_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| PROVISIONING_ERROR)?;
    validate_bytes(&bytes, device_id)
}

/// The currently bundled Go relay helper requires Unix owner/mode semantics.
/// Report the unsupported credential boundary rather than claim it was checked.
#[cfg(not(unix))]
pub fn load(_path: &Path, _device_id: &str) -> Result<ValidatedCredentials, &'static str> {
    Err("Remote relay credentials require owner-only Unix file validation on this platform.")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn bundle() -> serde_json::Value {
        serde_json::json!({"device_id":"next-device", "key_id":"key-1",
            "mac_secret":URL_SAFE_NO_PAD.encode([1u8;32]),
            "ios_secret":URL_SAFE_NO_PAD.encode([2u8;32])})
    }
    fn check(value: &serde_json::Value) -> Result<ValidatedCredentials, &'static str> {
        validate_bytes(&serde_json::to_vec(value).unwrap(), "next-device")
    }
    #[test]
    fn accepts_canonical_distinct_role_keys_without_exposing_them() {
        let credentials = check(&bundle()).unwrap();
        assert_eq!(credentials.key_id, "key-1");
        assert!(!format!("{credentials:?}").contains(&URL_SAFE_NO_PAD.encode([1u8; 32])));
    }
    #[test]
    fn rejects_mismatched_identity_and_identifier_boundaries() {
        let mut value = bundle();
        value["device_id"] = "other".into();
        assert!(check(&value).is_err());
        for invalid in ["", "with space", "slash/path", "é", &"a".repeat(33)] {
            let mut value = bundle();
            value["key_id"] = invalid.into();
            assert!(check(&value).is_err());
        }
        assert!(valid_identifier(&"a".repeat(128), 128));
        assert!(!valid_identifier(&"a".repeat(129), 128));
    }
    #[test]
    fn rejects_short_padded_noncanonical_and_duplicate_role_keys() {
        for invalid in [
            "short".to_string(),
            format!("{}=", URL_SAFE_NO_PAD.encode([1u8; 32])),
            URL_SAFE_NO_PAD.encode([1u8; 31]),
            "A".repeat(42) + "B",
        ] {
            let mut value = bundle();
            value["mac_secret"] = invalid.into();
            assert!(check(&value).is_err());
        }
        let mut value = bundle();
        value["ios_secret"] = value["mac_secret"].clone();
        assert!(check(&value).is_err());
    }
    #[test]
    fn rejects_oversize_unknown_fields_and_trailing_json_without_echoing_input() {
        assert_eq!(
            validate_bytes(&vec![b'x'; 8193], "next-device"),
            Err(PROVISIONING_ERROR)
        );
        let mut value = bundle();
        value["unexpected"] = "secret".into();
        assert!(check(&value).is_err());
        let mut bytes = serde_json::to_vec(&bundle()).unwrap();
        bytes.extend_from_slice(b" {}");
        assert_eq!(
            validate_bytes(&bytes, "next-device"),
            Err(PROVISIONING_ERROR)
        );
    }
    #[cfg(unix)]
    #[test]
    fn descriptor_validation_accepts_private_modes_and_rejects_symlinks_fifo_and_size() {
        use std::{
            ffi::CString,
            os::unix::fs::{PermissionsExt, symlink},
        };
        let dir = std::env::temp_dir().join(format!("next-relay-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let file = dir.join("credentials.json");
        std::fs::write(&file, serde_json::to_vec(&bundle()).unwrap()).unwrap();
        for mode in [0o600, 0o400] {
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(mode)).unwrap();
            assert!(load(&file, "next-device").is_ok());
        }
        for mode in [0o644, 0o640, 0o700] {
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(mode)).unwrap();
            assert!(load(&file, "next-device").is_err());
        }
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        let link = dir.join("link");
        symlink(&file, &link).unwrap();
        assert!(load(&link, "next-device").is_err());
        assert!(load(&dir, "next-device").is_err());
        assert!(load(&dir.join("missing"), "next-device").is_err());
        let fifo = dir.join("fifo");
        let c = CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: nul-terminated temporary fixture path, no borrowed storage survives call.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        assert!(load(&fifo, "next-device").is_err());
        std::fs::write(&file, vec![b'x'; 8193]).unwrap();
        assert!(load(&file, "next-device").is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
