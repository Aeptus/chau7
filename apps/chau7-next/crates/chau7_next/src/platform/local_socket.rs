//! Local stream sockets for the MCP server (`MCPServerManager`: Unix domain
//! socket, owner-only).
//!
//! Unix (macOS, Linux): a Unix domain socket, bound inside a folder made
//! owner-only (0700) so the socket is never reachable by others, then made
//! owner-only itself (0600). A stale socket file is removed before binding; a
//! live one (another running instance answers) is left alone and binding
//! fails. Windows: not
//! supported yet; [`Listener::bind`] returns [`super::PlatformError::Unsupported`].

use std::io::{Read, Write};
use std::path::Path;

use super::Result;

/// One client connection.
pub trait Connection: Read + Write + Send {
    /// A second handle on the same connection (one thread reads while
    /// another writes).
    fn try_clone_box(&self) -> std::io::Result<Box<dyn Connection>>;
    /// Close both directions.
    fn shutdown(&self);
}

pub struct Listener {
    #[cfg(unix)]
    inner: std::os::unix::net::UnixListener,
}

#[cfg(unix)]
impl Connection for std::os::unix::net::UnixStream {
    fn try_clone_box(&self) -> std::io::Result<Box<dyn Connection>> {
        Ok(Box::new(self.try_clone()?))
    }

    fn shutdown(&self) {
        let _ = std::os::unix::net::UnixStream::shutdown(self, std::net::Shutdown::Both);
    }
}

impl Listener {
    /// Bind `path` (removing a stale socket file first) and listen.
    #[cfg(unix)]
    pub fn bind(path: &Path) -> Result<Self> {
        use std::os::unix::fs::PermissionsExt;
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
            if let Err(err) = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            {
                return Err(super::PlatformError::Failed(format!(
                    "make {} private: {err}",
                    dir.display()
                )));
            }
        }
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            return Err(super::PlatformError::Failed(format!(
                "{} is in use by another running instance",
                path.display()
            )));
        }
        let _ = std::fs::remove_file(path);
        let inner = std::os::unix::net::UnixListener::bind(path)
            .map_err(|e| super::PlatformError::Failed(format!("bind {}: {e}", path.display())))?;
        if let Err(err) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
            log::warn!("MCP socket permissions: {err}");
        }
        Ok(Self { inner })
    }

    #[cfg(not(unix))]
    pub fn bind(_path: &Path) -> Result<Self> {
        super::unsupported("Unix domain sockets (MCP server)")
    }

    /// Wait for the next client.
    #[cfg(unix)]
    pub fn accept(&self) -> std::io::Result<Box<dyn Connection>> {
        let (stream, _) = self.inner.accept()?;
        Ok(Box::new(stream))
    }

    #[cfg(not(unix))]
    pub fn accept(&self) -> std::io::Result<Box<dyn Connection>> {
        Err(std::io::Error::other("unsupported"))
    }
}

/// Remove the socket file (quit).
pub fn remove(path: &Path) {
    let _ = std::fs::remove_file(path);
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};

    #[test]
    fn binds_owner_only_and_replaces_stale_files() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("c7n-sock-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mcp.sock");
        std::fs::write(&path, "stale").unwrap();
        let listener = Listener::bind(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let dir_mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700);
        let handle = std::thread::spawn(move || {
            let mut conn = listener.accept().unwrap();
            let mut reader = BufReader::new(conn.try_clone_box().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            conn.write_all(line.to_uppercase().as_bytes()).unwrap();
        });
        let mut client = std::os::unix::net::UnixStream::connect(&path).unwrap();
        client.write_all(b"ping\n").unwrap();
        let mut answer = String::new();
        BufReader::new(client).read_line(&mut answer).unwrap();
        assert_eq!(answer, "PING\n");
        handle.join().unwrap();
        remove(&path);
        assert!(!path.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_live_socket_is_not_stolen() {
        let dir = std::env::temp_dir().join(format!("c7n-sock-live-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("mcp.sock");
        let first = Listener::bind(&path).unwrap();
        assert!(Listener::bind(&path).is_err());
        assert!(path.exists());
        drop(first);
        // Nobody listens any more: the stale file is replaced.
        assert!(Listener::bind(&path).is_ok());
        remove(&path);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
