//! Bridge installation and AI CLI registration
//! (`MCPServerManager.installBridgeIfNeeded`, `registerMCPWithAllTools`).
//!
//! On every launch the bridge built next to the app binary (inside the app
//! bundle, or `target/<profile>/` for `cargo run`) is copied to
//! `DataRoot::bin_dir` (mode 755), then registered as `chau7-next` with its
//! socket in `args` for stdio-only clients. Codex and Claude Code use the
//! shared authenticated HTTP listener when available, without launching a bridge.

use std::path::{Path, PathBuf};

use chau7_next_core::data_root::{DataRoot, MCP_SERVER_NAME};
use chau7_next_core::mcp::client_config::{self, Client, HttpEntry, Outcome, ServerEntry};
use chau7_next_core::mcp::{BRIDGE_BINARY_NAME, bridge_args};

fn bridge_file_name() -> String {
    format!("{BRIDGE_BINARY_NAME}{}", std::env::consts::EXE_SUFFIX)
}

/// The bridge shipped with this app: next to the executable.
fn bundled_bridge() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let candidate = exe.parent()?.join(bridge_file_name());
    candidate.is_file().then_some(candidate)
}

/// Copy `source` to `dest` through a temporary file and a rename, so a
/// running bridge keeps its old file.
fn install_file(source: &Path, dest: &Path) -> std::io::Result<()> {
    let dir = dest.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(
        ".{}.tmp-{}",
        bridge_file_name(),
        std::process::id()
    ));
    std::fs::copy(source, &tmp)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(&tmp, dest).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

pub(super) fn install_and_register(root: &DataRoot, http: Option<&HttpEntry>) {
    if !cfg!(unix) {
        // No Unix sockets: the bridge could not connect, so AI CLIs are
        // not pointed at it.
        log::info!("MCPServer: not registered (no Unix domain sockets on this OS)");
        return;
    }
    let dest = root.bin_dir().join(bridge_file_name());
    if let Some(source) = bundled_bridge() {
        if let Err(err) = install_file(&source, &dest) {
            log::error!("MCPServer: failed to install {BRIDGE_BINARY_NAME}: {err}");
        }
    } else {
        log::info!("MCPServer: {BRIDGE_BINARY_NAME} not found next to the app (dev build?)");
    }
    let entry = ServerEntry {
        command: dest.to_string_lossy().into_owned(),
        args: bridge_args(&root.mcp_socket()),
    };
    for client in Client::ALL {
        let outcome = if let Some(http) =
            http.filter(|_| matches!(client, Client::Codex | Client::ClaudeCode))
        {
            client_config::register_http(client, root.home(), MCP_SERVER_NAME, http)
        } else if dest.is_file() {
            client_config::register(client, root.home(), MCP_SERVER_NAME, &entry)
        } else {
            continue;
        };
        let path = client.config_path(root.home());
        match outcome {
            Outcome::Written => log::info!(
                "MCPServer: registered with {} config at {}",
                client.name(),
                path.display()
            ),
            Outcome::Unchanged => log::debug!("MCPServer: {} config up to date", client.name()),
            Outcome::NotInstalled => {}
            Outcome::SkippedInvalid => log::warn!(
                "MCPServer: skipping {} - file exists but is not a valid config",
                path.display()
            ),
            Outcome::Failed(err) => log::error!(
                "MCPServer: failed to register with {}: {err}",
                client.name()
            ),
        }
    }
}
