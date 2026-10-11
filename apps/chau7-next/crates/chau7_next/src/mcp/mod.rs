//! MCP server (`apps/chau7-macos/Sources/Chau7/MCP/`): AI agents (Claude
//! Code, Codex, Cursor, Windsurf) list, open, drive and read tabs, query AI
//! run telemetry and keep per-repo notes through a Unix socket.
//!
//! - [`server`]: the socket (`DataRoot::mcp_socket`, `~/.chau7-next/mcp.sock`)
//!   on a background thread, one thread per client running the JSON-RPC
//!   session of `chau7_next_core::mcp::protocol`.
//! - [`tools`]: the tools, one file per family (telemetry, tabs, repo,
//!   runtime). Anything touching tabs or settings runs on the GPUI main
//!   thread through [`MainThread`]; the client thread waits for the answer.
//! - [`approval`]: the command filter verdicts and the dialogs (tab creation,
//!   command approval).
//! - [`install`]: copies the bridge (`chau7-next-mcp-bridge`) to
//!   `DataRoot::bin_dir` and registers it as `chau7-next` in the AI CLI
//!   configs, on every launch.
//! - [`sources`]: hooks the Telemetry and History ports plug their stores
//!   into (empty until then).
//!
//! Chau7 Next never binds the Swift app's socket nor touches its `chau7`
//! entries (`docs/rust-port/DUAL-SHIP.md`).

pub mod approval;
mod approval_window;
pub mod control;
mod install;
mod server;
pub mod sources;
pub mod tools;
pub mod windows;

use std::path::PathBuf;

use futures::StreamExt;
use futures::channel::{mpsc, oneshot};
use gpui::{App, Global};

use crate::workspace::AppData;

/// Work for the main thread, sent by a client thread.
type Job = Box<dyn FnOnce(&mut App) + Send>;

/// Runs closures on the GPUI main thread for the client threads, which block
/// until the answer comes back. Cheap to clone.
#[derive(Clone)]
pub struct MainThread {
    jobs: mpsc::UnboundedSender<Job>,
}

impl MainThread {
    /// Start the main-thread loop that runs the jobs.
    pub(crate) fn start(cx: &mut App) -> Self {
        let (jobs, mut rx) = mpsc::unbounded::<Job>();
        cx.spawn(async move |cx| {
            while let Some(job) = rx.next().await {
                cx.update(|cx| job(cx));
            }
        })
        .detach();
        Self { jobs }
    }

    /// A main thread whose jobs go to `jobs` (tests that never call it).
    #[cfg(test)]
    pub fn for_tests(jobs: mpsc::UnboundedSender<Job>) -> Self {
        Self { jobs }
    }

    /// Run `f` on the main thread and return its result. `None` when the
    /// app is going away.
    pub fn call<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut App) -> T + Send + 'static,
    ) -> Option<T> {
        self.call_async(move |cx, reply| {
            let _ = reply.send(f(cx));
        })
    }

    /// Like [`Self::call`], for work that answers later (a dialog): `f` gets
    /// the reply sender and may hand it to a task.
    pub fn call_async<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut App, oneshot::Sender<T>) + Send + 'static,
    ) -> Option<T> {
        let (tx, rx) = oneshot::channel();
        self.jobs
            .unbounded_send(Box::new(move |cx| f(cx, tx)))
            .ok()?;
        futures::executor::block_on(rx).ok()
    }
}

/// The running server.
struct McpServer {
    socket: PathBuf,
}

impl Global for McpServer {}

/// Start the MCP server, install the bridge and register it (`MCPServerManager.start`).
pub fn start(cx: &mut App) {
    let root = cx.global::<AppData>().root.clone();
    let main = MainThread::start(cx);
    windows::start(cx);
    let socket = root.mcp_socket();
    let install_root = root.clone();
    let spawned = std::thread::Builder::new()
        .name("chau7-next-mcp-install".into())
        .spawn(move || install::install_and_register(&install_root));
    if let Err(err) = spawned {
        log::error!("MCPServer: install thread: {err}");
    }
    server::spawn(socket.clone(), main);
    cx.set_global(McpServer { socket });
}

/// Remove the socket file at quit (`_stop`).
pub fn stop(cx: &App) {
    if let Some(server) = cx.try_global::<McpServer>() {
        crate::platform::local_socket::remove(&server.socket);
        log::info!("MCPServer: stopped");
    }
}
