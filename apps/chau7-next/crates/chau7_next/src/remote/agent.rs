//! The `chau7-remote` agent process (`startAgent`, `stopAgent` and the
//! binary lookup of `RemoteControlManager.swift`).
//!
//! The agent is the Go helper in `services/chau7-remote`: it holds the relay
//! WebSocket, pairs and encrypts, and connects back to our IPC socket. Chau7
//! Next always passes `CHAU7_REMOTE_STATE` (its own state file) so it never
//! shares a pairing with the Swift app, and a `CHAU7_MAC_NAME` naming
//! "Chau7 Next" so the iPhone can tell the two hosts apart.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::SystemTime;

use chau7_next_core::data_root::{APP_NAME, DataRoot};

/// File name of the agent binary.
pub const AGENT_BINARY: &str = "chau7-remote";

/// `CHAU7_MAC_NAME`: the computer name, marked as Chau7 Next.
pub fn mac_name(host: Option<String>) -> String {
    format!("{} ({APP_NAME})", host.unwrap_or_else(|| "Mac".into()))
}

/// The environment the agent is started with.
pub fn agent_env(root: &DataRoot, relay_url: &str, host: Option<String>) -> Vec<(String, String)> {
    let path = |p: PathBuf| p.to_string_lossy().into_owned();
    vec![
        ("CHAU7_REMOTE_SOCKET".into(), path(root.remote_socket())),
        ("CHAU7_RELAY_URL".into(), relay_url.to_string()),
        ("CHAU7_MAC_NAME".into(), mac_name(host)),
        ("CHAU7_REMOTE_STATE".into(), path(root.remote_state_file())),
        (
            "CHAU7_REMOTE_CREDENTIALS".into(),
            path(root.remote_credentials_file()),
        ),
        // The agent exits when this process goes away.
        ("CHAU7_PARENT_PID".into(), std::process::id().to_string()),
    ]
}

/// The Go sources, when this build runs from a checkout of the repo
/// (development builds only).
fn agent_source_dir() -> Option<PathBuf> {
    if !cfg!(debug_assertions) {
        return None;
    }
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../services")
        .join(AGENT_BINARY);
    dir.join("go.mod").is_file().then_some(dir)
}

/// Binaries built by hand in the checkout (`go build` in the service folder).
fn dev_binaries(source: &Path) -> [PathBuf; 2] {
    [
        source.join(AGENT_BINARY),
        source.join("cmd").join(AGENT_BINARY).join(AGENT_BINARY),
    ]
}

/// The binary shipped in the app bundle: next to the executable
/// (`Contents/MacOS`), or in `Contents/Resources`.
fn bundled_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let candidates = [
        dir.join(AGENT_BINARY),
        dir.join("../Resources").join(AGENT_BINARY),
    ];
    candidates.into_iter().find(|p| is_executable(p))
}

pub fn is_executable(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).ok()?.modified().ok()
}

fn set_executable(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(err) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)) {
            log::warn!("Failed to set remote binary permissions: {err}");
        }
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// Some `.go`, `.mod` or `.sum` file under `source` is newer than `binary`
/// (or there is no binary).
pub fn sources_newer_than(source: &Path, binary: &Path) -> bool {
    let Some(built) = modified(binary) else {
        return true;
    };
    fn walk(dir: &Path, built: SystemTime) -> bool {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return false;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let hidden = path
                .file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with('.'));
            if hidden {
                continue;
            }
            if path.is_dir() {
                if walk(&path, built) {
                    return true;
                }
            } else if matches!(
                path.extension().and_then(|e| e.to_str()),
                Some("go" | "mod" | "sum")
            ) && modified(&path).is_some_and(|m| m > built)
            {
                return true;
            }
        }
        false
    }
    walk(source, built)
}

/// Copy the bundled binary to the installed path when it is missing or
/// different (`syncInstalledRemoteBinary`).
pub fn sync_installed(bundled: &Path, installed: &Path) -> std::io::Result<()> {
    if is_executable(installed) {
        let same = std::fs::read(installed).ok() == std::fs::read(bundled).ok();
        if same {
            return Ok(());
        }
    }
    if let Some(dir) = installed.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let _ = std::fs::remove_file(installed);
    std::fs::copy(bundled, installed)?;
    set_executable(installed);
    Ok(())
}

/// `go build -o <output> ./cmd/chau7-remote` in `source`.
fn go_build(source: &Path, output: &Path) -> Result<(), String> {
    if let Some(dir) = output.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|_| "Failed to create remote agent output directory.".to_string())?;
    }
    let result = Command::new("go")
        .args(["build", "-o"])
        .arg(output)
        .arg(format!("./cmd/{AGENT_BINARY}"))
        .current_dir(source)
        .output()
        .map_err(|_| "Failed to launch Go build for remote agent.".to_string())?;
    if !result.status.success() {
        let mut text = String::from_utf8_lossy(&result.stdout).into_owned();
        text.push_str(&String::from_utf8_lossy(&result.stderr));
        log::error!("Remote agent build failed: {text}");
        let trimmed = text.trim();
        return Err(if trimmed.is_empty() {
            "Remote agent build failed. Make sure Go is installed.".into()
        } else {
            format!("Remote agent build failed. {trimmed}")
        });
    }
    set_executable(output);
    Ok(())
}

/// Find (and if needed install or build) the agent binary
/// (`remoteBinaryPath`). The error is shown as the last error.
pub fn binary_path(root: &DataRoot) -> Result<PathBuf, String> {
    let installed = root.remote_agent_binary();
    let source = agent_source_dir();
    let mut build_error = None;
    // Development: rebuild when the Go sources changed.
    if let Some(source) = &source
        && sources_newer_than(source, &installed)
    {
        match go_build(source, &installed) {
            Ok(()) if is_executable(&installed) => return Ok(installed),
            Ok(()) => {}
            Err(err) => build_error = Some(err),
        }
    }
    if let Some(source) = &source
        && let Some(dev) = dev_binaries(source).into_iter().find(|p| is_executable(p))
    {
        return Ok(dev);
    }
    if let Some(bundled) = bundled_binary() {
        if let Err(err) = sync_installed(&bundled, &installed) {
            log::warn!("Failed to sync bundled remote agent to App Support: {err}");
        }
        return Ok(if is_executable(&installed) {
            installed
        } else {
            bundled
        });
    }
    if is_executable(&installed) {
        return Ok(installed);
    }
    Err(build_error.unwrap_or_else(|| "Remote agent binary not found.".into()))
}

/// A running agent.
pub struct AgentProcess {
    child: Child,
}

impl AgentProcess {
    /// Start the agent in the Chau7 Next state folder; its output goes to
    /// the log.
    pub fn spawn(
        binary: &Path,
        root: &DataRoot,
        relay_url: &str,
        host: Option<String>,
    ) -> Result<Self, String> {
        set_executable(binary);
        std::fs::create_dir_all(root.state_dir())
            .map_err(|_| "Cannot start remote agent: data directory unavailable".to_string())?;
        if let Some(dir) = root.remote_state_file().parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let mut command = Command::new(binary);
        command
            .current_dir(root.state_dir())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (key, value) in agent_env(root, relay_url, host) {
            command.env(key, value);
        }
        let mut child = command
            .spawn()
            .map_err(|err| format!("Failed to start remote agent: {err}"))?;
        if let Some(out) = child.stdout.take() {
            forward_lines(out, false);
        }
        if let Some(err) = child.stderr.take() {
            forward_lines(err, true);
        }
        log::info!("Remote agent started from {}", binary.display());
        Ok(Self { child })
    }

    /// `Some(status)` once the agent exited: its exit code, or the signal
    /// that ended it (Swift `terminationStatus`).
    pub fn try_exit(&mut self) -> Option<i32> {
        match self.child.try_wait() {
            Ok(Some(status)) => {
                #[cfg(unix)]
                {
                    use std::os::unix::process::ExitStatusExt;
                    Some(status.code().or(status.signal()).unwrap_or(-1))
                }
                #[cfg(not(unix))]
                {
                    Some(status.code().unwrap_or(-1))
                }
            }
            Ok(None) => None,
            Err(_) => Some(-1),
        }
    }

    /// SIGTERM, a short wait, then kill (`ManagedProcess.terminate`).
    pub fn stop(mut self) {
        if self.try_exit().is_some() {
            return;
        }
        #[cfg(unix)]
        {
            // SAFETY: plain kill(2) on our own child's pid.
            unsafe {
                libc::kill(self.child.id() as i32, libc::SIGTERM);
            }
            use std::time::{Duration, Instant};
            let deadline = Instant::now() + Duration::from_millis(1500);
            while Instant::now() < deadline {
                if self.try_exit().is_some() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn forward_lines(stream: impl std::io::Read + Send + 'static, is_stderr: bool) {
    let _ = std::thread::Builder::new()
        .name("remote-agent-log".into())
        .spawn(move || {
            for line in BufReader::new(stream).lines().map_while(Result::ok) {
                if is_stderr {
                    log::warn!("Remote stderr: {line}");
                } else {
                    log::debug!("Remote stdout: {line}");
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(name: &str) -> (PathBuf, DataRoot) {
        let home =
            std::env::temp_dir().join(format!("chau7-next-remote-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        (home, root)
    }

    #[test]
    fn env_points_into_our_own_data_root() {
        let (home, root) = temp_root("env");
        let env = agent_env(&root, "wss://relay.test/connect", Some("Studio".into()));
        let get = |k: &str| env.iter().find(|(key, _)| key == k).unwrap().1.clone();
        assert!(get("CHAU7_REMOTE_STATE").starts_with(&*home.to_string_lossy()));
        assert!(get("CHAU7_REMOTE_STATE").contains(".chau7-next"));
        assert!(get("CHAU7_REMOTE_SOCKET").starts_with(&*home.to_string_lossy()));
        assert!(get("CHAU7_REMOTE_CREDENTIALS").starts_with(&*home.to_string_lossy()));
        assert!(get("CHAU7_REMOTE_CREDENTIALS").contains(".chau7-next"));
        assert_eq!(get("CHAU7_PARENT_PID"), std::process::id().to_string());
        assert_eq!(get("CHAU7_RELAY_URL"), "wss://relay.test/connect");
        assert_eq!(get("CHAU7_MAC_NAME"), "Studio (Chau7 Next)");
        assert_eq!(mac_name(None), "Mac (Chau7 Next)");
        let _ = std::fs::remove_dir_all(home);
    }

    #[cfg(unix)]
    #[test]
    fn installed_copy_follows_the_bundled_binary() {
        let (home, root) = temp_root("sync");
        let bundled = home.join("bundled");
        std::fs::write(&bundled, b"v1").unwrap();
        set_executable(&bundled);
        let installed = root.remote_agent_binary();
        sync_installed(&bundled, &installed).unwrap();
        assert!(is_executable(&installed));
        assert_eq!(std::fs::read(&installed).unwrap(), b"v1");
        std::fs::write(&bundled, b"v2").unwrap();
        sync_installed(&bundled, &installed).unwrap();
        assert_eq!(std::fs::read(&installed).unwrap(), b"v2");
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn newer_sources_need_a_rebuild() {
        let (home, _) = temp_root("newer");
        let source = home.join("src");
        std::fs::create_dir_all(source.join("cmd")).unwrap();
        let binary = home.join("bin");
        assert!(sources_newer_than(&source, &binary));
        std::fs::write(&binary, b"x").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(source.join("README.md"), b"doc").unwrap();
        assert!(!sources_newer_than(&source, &binary));
        std::fs::write(source.join("cmd").join("main.go"), b"package main").unwrap();
        assert!(sources_newer_than(&source, &binary));
        let _ = std::fs::remove_dir_all(home);
    }
}
