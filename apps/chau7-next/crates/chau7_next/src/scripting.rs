//! Scripting API server (`Scripting/ScriptingAPI.swift`, SCR-001 to
//! SCR-015): newline-delimited JSON on a Unix socket so shell scripts can
//! list tabs, run commands, read output, open and close tabs, read history,
//! settings and snippets. The protocol and every method are
//! `chau7_next_core::scripting`; this module runs the socket.
//!
//! Swift never starts its server. Chau7 Next starts it when
//! Settings > MCP > "Enable Scripting API" (`scripting_api`) is on and
//! stops it (socket removed) when it is turned off. The socket is
//! `DataRoot::scripting_socket` (`~/Library/Application Support/Chau7
//! Next/scripting.sock` on macOS), owner-only, never the Swift path.
//!
//! Tab methods call the MCP tab tools, as Swift calls
//! `TerminalControlService`: same command filter, limits and answers.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use chau7_next_core::scripting::{
    Incoming, LineBuffer, ScriptingHost, finish_response, handle_request,
};
use gpui::{App, Global};
use serde_json::{Map, Value, json};

use crate::mcp::MainThread;
use crate::mcp::tools::{ToolContext, tabs};
use crate::platform::local_socket::{Connection, Listener};
use crate::settings::Settings;
use crate::workspace::AppData;

/// State shared by the server threads.
struct Shared {
    stop: AtomicBool,
    started: Instant,
    next_client: AtomicU64,
    clients: Mutex<Vec<(u64, Box<dyn Connection>)>>,
}

impl Shared {
    fn client_count(&self) -> i64 {
        self.clients.lock().map(|c| c.len() as i64).unwrap_or(0)
    }
}

struct Running {
    socket: PathBuf,
    shared: Arc<Shared>,
}

#[derive(Default)]
struct ScriptingServer {
    main: Option<MainThread>,
    running: Option<Running>,
    /// The setting last applied (a failed start is retried when it is
    /// turned off and on again, not on every settings change).
    enabled: bool,
}

impl Global for ScriptingServer {}

/// Start the server if the setting is on, and follow the setting.
pub fn init(cx: &mut App) {
    let main = MainThread::start(cx);
    cx.set_global(ScriptingServer {
        main: Some(main),
        running: None,
        enabled: false,
    });
    apply(cx);
    cx.observe_global::<Settings>(apply).detach();
}

/// Start or stop to match the setting (`isEnabled` didSet).
fn apply(cx: &mut App) {
    let enabled = Settings::get(cx).mcp.scripting_api;
    if cx.global::<ScriptingServer>().enabled == enabled {
        return;
    }
    cx.global_mut::<ScriptingServer>().enabled = enabled;
    if enabled {
        start(cx);
    } else {
        stop(cx);
    }
}

fn start(cx: &mut App) {
    let socket = cx.global::<AppData>().root.scripting_socket();
    let Some(main) = cx.global::<ScriptingServer>().main.clone() else {
        return;
    };
    let listener = match Listener::bind(&socket) {
        Ok(listener) => listener,
        Err(err) => {
            log::error!(
                "ScriptingAPI: failed to listen on {}: {err}",
                socket.display()
            );
            return;
        }
    };
    let shared = Arc::new(Shared {
        stop: AtomicBool::new(false),
        started: Instant::now(),
        next_client: AtomicU64::new(0),
        clients: Mutex::new(Vec::new()),
    });
    let thread_shared = shared.clone();
    let spawned = std::thread::Builder::new()
        .name("chau7-next-scripting".into())
        .spawn(move || accept_loop(listener, thread_shared, main));
    if let Err(err) = spawned {
        log::error!("ScriptingAPI: server thread: {err}");
        crate::platform::local_socket::remove(&socket);
        return;
    }
    log::info!("ScriptingAPI: server started at {}", socket.display());
    cx.global_mut::<ScriptingServer>().running = Some(Running { socket, shared });
}

/// `stopServer`: disconnect the clients, close and remove the socket.
pub fn stop(cx: &mut App) {
    let Some(running) = cx
        .try_global::<ScriptingServer>()
        .is_some()
        .then(|| cx.global_mut::<ScriptingServer>().running.take())
        .flatten()
    else {
        return;
    };
    running.shared.stop.store(true, Ordering::SeqCst);
    if let Ok(mut clients) = running.shared.clients.lock() {
        for (_, conn) in clients.drain(..) {
            conn.shutdown();
        }
    }
    // Wake the blocked `accept` so the thread sees the stop flag.
    #[cfg(unix)]
    let _ = std::os::unix::net::UnixStream::connect(&running.socket);
    crate::platform::local_socket::remove(&running.socket);
    log::info!("ScriptingAPI: server stopped");
}

fn accept_loop(listener: Listener, shared: Arc<Shared>, main: MainThread) {
    loop {
        let conn = listener.accept();
        if shared.stop.load(Ordering::SeqCst) {
            return;
        }
        let conn = match conn {
            Ok(conn) => conn,
            Err(err) => {
                log::warn!("ScriptingAPI: accept failed: {err}");
                std::thread::sleep(std::time::Duration::from_millis(100));
                continue;
            }
        };
        let id = shared.next_client.fetch_add(1, Ordering::SeqCst) + 1;
        let Ok(handle) = conn.try_clone_box() else {
            continue;
        };
        let total = {
            let Ok(mut clients) = shared.clients.lock() else {
                continue;
            };
            clients.push((id, handle));
            clients.len()
        };
        log::info!("ScriptingAPI: client connected ({id}, total={total})");
        let (shared, main) = (shared.clone(), main.clone());
        let spawned = std::thread::Builder::new()
            .name(format!("chau7-next-scripting-{id}"))
            .spawn(move || {
                serve(conn, &shared, &main);
                if let Ok(mut clients) = shared.clients.lock() {
                    clients.retain(|(c, _)| *c != id);
                }
                log::info!("ScriptingAPI: client disconnected ({id})");
            });
        if let Err(err) = spawned {
            log::error!("ScriptingAPI: client thread: {err}");
        }
    }
}

/// `ScriptingClientHandler`: read lines, answer each one.
fn serve(mut conn: Box<dyn Connection>, shared: &Arc<Shared>, main: &MainThread) {
    let mut writer = match conn.try_clone_box() {
        Ok(writer) => writer,
        Err(err) => {
            log::warn!("ScriptingAPI: {err}");
            return;
        }
    };
    let mut lines = LineBuffer::default();
    let mut host = AppScriptingHost {
        main: main.clone(),
        shared: shared.clone(),
    };
    let mut buf = [0u8; 8192];
    loop {
        let read = match conn.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        if shared.stop.load(Ordering::SeqCst) {
            break;
        }
        for incoming in lines.push(&buf[..read]) {
            let line = match incoming {
                Incoming::Reply(reply) => finish_response(reply, None),
                Incoming::Request(request) => {
                    finish_response(handle_request(&request, &mut host), Some(&request))
                }
            };
            if writer.write_all(line.as_bytes()).is_err() || writer.flush().is_err() {
                log::warn!("ScriptingAPI: write failed");
                return;
            }
        }
    }
    writer.shutdown();
}

/// The app for the scripting methods, from a client thread.
struct AppScriptingHost {
    main: MainThread,
    shared: Arc<Shared>,
}

impl AppScriptingHost {
    fn tab_tool(&self, name: &str, args: Value) -> String {
        let args = args.as_object().cloned().unwrap_or_default();
        tabs::call(name, &args, &ToolContext { main: &self.main })
            .unwrap_or_else(|| chau7_next_core::mcp::output::json_error("unknown tool"))
    }

    fn history_store(
        &self,
    ) -> Option<Arc<parking_lot::Mutex<chau7_next_core::history_store::HistoryStore>>> {
        self.main
            .call(|cx| crate::history::service(cx).map(|s| s.store_handle()))
            .flatten()
    }
}

/// Bool settings take a Bool, a number (non-zero is on) or a yes/no string
/// (`UserDefaults.bool(forKey:)`).
fn bool_value(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => n.as_f64().map(|f| f != 0.0),
        Value::String(s) => match s.trim().to_lowercase().as_str() {
            "true" | "yes" | "1" => Some(true),
            "false" | "no" | "0" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

/// `history.maxRecords` takes a whole number or a numeric string.
fn int_value(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

impl ScriptingHost for AppScriptingHost {
    fn list_tabs(&mut self) -> String {
        self.tab_tool("tab_list", json!({}))
    }

    fn tab_status(&mut self, tab_id: &str) -> String {
        self.tab_tool("tab_status", json!({"tab_id": tab_id}))
    }

    fn exec(&mut self, tab_id: &str, command: &str) -> String {
        self.tab_tool("tab_exec", json!({"tab_id": tab_id, "command": command}))
    }

    fn output(&mut self, tab_id: &str, lines: i64) -> String {
        self.tab_tool("tab_output", json!({"tab_id": tab_id, "lines": lines}))
    }

    fn create_tab(&mut self, directory: Option<&str>) -> String {
        let args = match directory {
            Some(dir) => json!({"directory": dir}),
            None => json!({}),
        };
        self.tab_tool("tab_create", args)
    }

    fn close_tab(&mut self, tab_id: &str) -> String {
        self.tab_tool("tab_close", json!({"tab_id": tab_id, "force": true}))
    }

    fn history(&mut self, query: &str, limit: usize) -> Vec<Value> {
        let Some(store) = self.history_store() else {
            return Vec::new();
        };
        let records = {
            let store = store.lock();
            if query.is_empty() {
                store.recent(limit)
            } else {
                store.search(query, limit)
            }
        };
        records
            .into_iter()
            .map(|r| {
                let mut item = Map::new();
                item.insert("command".into(), json!(r.command));
                item.insert(
                    "timestamp".into(),
                    json!(r.timestamp.timestamp_millis() as f64 / 1000.0),
                );
                if let Some(d) = r.directory {
                    item.insert("directory".into(), json!(d));
                }
                if let Some(e) = r.exit_code {
                    item.insert("exit_code".into(), json!(e));
                }
                if let Some(s) = r.shell {
                    item.insert("shell".into(), json!(s));
                }
                if let Some(t) = r.tab_id {
                    item.insert("tab_id".into(), json!(t));
                }
                if let Some(d) = r.duration {
                    item.insert("duration".into(), json!(d));
                }
                Value::Object(item)
            })
            .collect()
    }

    fn history_count(&mut self) -> i64 {
        self.history_store()
            .map(|s| s.lock().total_count())
            .unwrap_or(0)
    }

    fn setting(&mut self, key: &str) -> Value {
        let key = key.to_string();
        self.main
            .call(move |cx| {
                let s = Settings::get(cx);
                match key.as_str() {
                    "feature.scriptingAPI" => json!(s.mcp.scripting_api),
                    "feature.persistentHistory" => json!(s.history.persistent_history),
                    "history.maxRecords" => json!(s.history.max_records),
                    _ => Value::Null,
                }
            })
            .unwrap_or(Value::Null)
    }

    fn set_setting(&mut self, key: &str, value: &Value) -> Result<(), String> {
        let key = key.to_string();
        match key.as_str() {
            "feature.scriptingAPI" | "feature.persistentHistory" => {
                let Some(on) = bool_value(value) else {
                    return Err(format!("{key} needs a Bool value"));
                };
                self.main.call(move |cx| {
                    crate::settings_window::update(cx, |s| {
                        if key == "feature.scriptingAPI" {
                            s.mcp.scripting_api = on;
                        } else {
                            s.history.persistent_history = on;
                        }
                    });
                });
            }
            "history.maxRecords" => {
                let Some(max) = int_value(value) else {
                    return Err(format!("{key} needs a number"));
                };
                self.main.call(move |cx| {
                    crate::settings_window::update(cx, |s| {
                        s.history.max_records = (max.max(0) as usize).clamp(
                            chau7_next_core::history_store::MIN_MAX_RECORDS,
                            chau7_next_core::history_store::MAX_MAX_RECORDS,
                        );
                    });
                });
            }
            _ => return Err(format!("unknown or disallowed setting key: {key}")),
        }
        Ok(())
    }

    fn snippets(&mut self) -> Vec<(String, String)> {
        self.main
            .call(|cx| {
                let root = cx.global::<AppData>().root.clone();
                let settings = Settings::get(cx).productivity.clone();
                // The repository of the front window's tab (`SnippetManager`
                // follows the active tab).
                let git_root = crate::mcp::windows::windows(cx).first().and_then(|w| {
                    let ws = w.workspace.read(cx);
                    let id = ws.selected_tab_id()?;
                    ws.mcp_session(id, cx)?.read(cx).git_root.clone()
                });
                crate::snippets::load_entries(&root, &settings, git_root.as_deref())
                    .into_iter()
                    .filter(|e| !e.is_overridden)
                    .map(|e| (e.snippet.title, e.snippet.body))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn version(&self) -> (String, String) {
        let short = crate::platform::system::bundle_string("CFBundleShortVersionString")
            .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string());
        let build = crate::platform::system::bundle_string("CFBundleVersion")
            .unwrap_or_else(|| "unknown".into());
        (short, build)
    }

    fn uptime_seconds(&self) -> i64 {
        self.shared.started.elapsed().as_secs() as i64
    }

    fn connected_clients(&self) -> i64 {
        self.shared.client_count()
    }

    fn server_running(&self) -> bool {
        !self.shared.stop.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setting_values_convert_like_user_defaults() {
        assert_eq!(bool_value(&json!(true)), Some(true));
        assert_eq!(bool_value(&json!(0)), Some(false));
        assert_eq!(bool_value(&json!(2.5)), Some(true));
        assert_eq!(bool_value(&json!("YES")), Some(true));
        assert_eq!(bool_value(&json!("maybe")), None);
        assert_eq!(int_value(&json!(25000)), Some(25000));
        assert_eq!(int_value(&json!(25000.9)), Some(25000));
        assert_eq!(int_value(&json!(" 30000 ")), Some(30000));
        assert_eq!(int_value(&json!(true)), None);
    }
}
