//! The `chau7-proxy` process (`ProxyManager.start` / `stop` and its binary
//! lookup).
//!
//! The proxy is the Go program in `services/chau7-proxy`, shipped
//! next to the app binary by `scripts/bundle-macos.sh`. It always gets
//! Chau7 Next's own ports, database, socket and certificate
//! (`chau7_next_core::proxy::proxy_env`), so it never touches the Swift
//! app's proxy.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::proxy::{PROXY_BINARY, proxy_env};

use crate::remote::agent::{is_executable, sources_newer_than};

/// The Go sources, when this build runs from a checkout (development only).
fn source_dir() -> Option<PathBuf> {
    if !cfg!(debug_assertions) {
        return None;
    }
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../services")
        .join(PROXY_BINARY);
    dir.join("go.mod").is_file().then_some(dir)
}

/// The binary in the app bundle: next to the executable (`Contents/MacOS`)
/// or in `Contents/Resources`.
fn bundled_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    [
        dir.join(PROXY_BINARY),
        dir.join("../Resources").join(PROXY_BINARY),
    ]
    .into_iter()
    .find(|p| is_executable(p))
}

fn set_executable(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(err) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)) {
            log::warn!("Failed to set binary permissions: {err}");
        }
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// `go build -o <output> .` in the proxy sources.
fn go_build(source: &Path, output: &Path) -> bool {
    if let Some(dir) = output.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    match Command::new("go")
        .args(["build", "-o"])
        .arg(output)
        .arg(".")
        .current_dir(source)
        .env("CGO_ENABLED", "0")
        .output()
    {
        Ok(out) if out.status.success() => true,
        Ok(out) => {
            log::error!(
                "Proxy build failed: {}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            false
        }
        Err(err) => {
            log::warn!("Proxy build: cannot run go: {err}");
            false
        }
    }
}

/// Find the proxy binary (`proxyBinaryPath`): the bundled one, else (in
/// development) a fresh `go build`, else a binary built by hand in the
/// checkout.
pub fn binary_path(root: &DataRoot) -> Result<PathBuf, String> {
    if let Some(bundled) = bundled_binary() {
        return Ok(bundled);
    }
    if let Some(source) = source_dir() {
        let output = root.proxy_dev_binary();
        if sources_newer_than(&source, &output) && go_build(&source, &output) {
            return Ok(output);
        }
        if is_executable(&output) {
            return Ok(output);
        }
        let candidates = [
            source.join("build").join("darwin").join(PROXY_BINARY),
            source.join(PROXY_BINARY),
        ];
        if let Some(found) = candidates.into_iter().find(|p| is_executable(p)) {
            return Ok(found);
        }
    }
    Err("Proxy binary not found. Please build chau7-proxy first.".into())
}

/// A running proxy.
pub struct ProxyProcess {
    child: Child,
}

impl ProxyProcess {
    /// Start the proxy in its data folder; output goes to the log.
    pub fn spawn(
        binary: &Path,
        root: &DataRoot,
        port: u16,
        log_prompts: bool,
    ) -> Result<Self, String> {
        set_executable(binary);
        let dir = root.proxy_dir();
        let _ = std::fs::create_dir_all(&dir);
        // Swift removes the socket file here, which unlinks its own IPC
        // server's socket (bound earlier at launch) so the proxy can no
        // longer reach it. Chau7 Next's IPC server removes a stale file when
        // it binds, so nothing is removed here.
        let mut command = Command::new(binary);
        command
            .current_dir(&dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (key, value) in proxy_env(root, port, log_prompts) {
            command.env(key, value);
        }
        let mut child = command
            .spawn()
            .map_err(|err| format!("Failed to start proxy: {err}"))?;
        if let Some(out) = child.stdout.take() {
            forward_lines(out, false);
        }
        if let Some(err) = child.stderr.take() {
            forward_lines(err, true);
        }
        log::info!("Proxy started on port {port}");
        Ok(Self { child })
    }

    /// `Some(status)` once the process exited.
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

    /// Stop this owned helper with the Swift SIGTERM, SIGINT, then kill schedule.
    pub fn stop(self) {
        crate::process_termination::terminate_proxy_child(self.child);
    }
}

fn forward_lines(stream: impl std::io::Read + Send + 'static, is_stderr: bool) {
    let _ = std::thread::Builder::new()
        .name("proxy-log".into())
        .spawn(move || {
            for line in BufReader::new(stream).lines().map_while(Result::ok) {
                crate::incidents::proxy_output(&line);
                if is_stderr {
                    log::warn!("Proxy stderr: {line}");
                } else {
                    log::debug!("Proxy stdout: {line}");
                }
            }
        });
}
