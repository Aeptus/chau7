use std::io::{self, Read};
use std::path::Path;

use serde::{Deserialize, Serialize};

/// Kept in the app's private profile. Never log or Debug-print this value.
#[derive(Serialize, Deserialize)]
pub(super) struct Credentials {
    pub port: u16,
    pub token: String,
}

impl Credentials {
    pub fn load(path: &Path) -> io::Result<Self> {
        let value = match std::fs::File::open(path).and_then(|file| {
            let mut bytes = Vec::new();
            file.take(4097).read_to_end(&mut bytes)?;
            Ok(bytes)
        }) {
            Ok(bytes) if bytes.len() <= 4096 => serde_json::from_slice::<Self>(&bytes)
                .map_err(|_| io::Error::other("invalid MCP HTTP credentials"))?,
            Ok(_) => return Err(io::Error::other("MCP HTTP credentials exceed limit")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Self {
                port: 0,
                token: format!(
                    "{}{}",
                    uuid::Uuid::new_v4().simple(),
                    uuid::Uuid::new_v4().simple()
                ),
            },
            Err(error) => return Err(error),
        };
        if value.token.len() != 64 || !value.token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(io::Error::other("invalid MCP HTTP token"));
        }
        Ok(value)
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        use std::os::unix::fs::PermissionsExt;
        if path.exists() {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
        crate::atomic_file::write(path, &serde_json::to_vec(self)?)
    }
}
