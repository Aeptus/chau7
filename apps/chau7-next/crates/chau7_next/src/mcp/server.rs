//! The socket server (`MCPServerManager._start`, `MCPSession.run`): one
//! listener thread, one thread per client. Each line from a client is one
//! JSON-RPC message; each answer is one line, flushed.

use crate::observability::{Journal, TimerRegistry};
use chau7_next_core::mcp::rate_limiter::{Decision, ToolRateLimiter};
use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use chau7_next_core::data_root::MCP_SERVER_NAME;
use chau7_next_core::mcp::handshake::Handshake;
use chau7_next_core::mcp::protocol::{McpHost, handle_line};
use serde_json::{Map, Value};

use super::MainThread;
use super::tools::{self, ToolContext};
use crate::platform::local_socket::{Connection, Listener};

/// The current Swift server shares per-tool budgets across connections. This
/// prevents reconnecting or adding clients from multiplying creation budgets.
fn rate_decision(name: &str) -> Decision {
    static LIMITER: OnceLock<Mutex<(Instant, ToolRateLimiter)>> = OnceLock::new();
    let mut state = LIMITER
        .get_or_init(|| Mutex::new((Instant::now(), ToolRateLimiter::default())))
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let now = state.0.elapsed();
    state.1.evaluate(name, now)
}

/// Bind the socket and accept clients on a background thread.
pub(super) fn spawn(
    socket: PathBuf,
    main: MainThread,
    journal: Option<Journal>,
    timers: Option<TimerRegistry>,
    bridge: PathBuf,
) {
    let spawned = std::thread::Builder::new()
        .name("chau7-next-mcp".into())
        .spawn(move || {
            let listener = match Listener::bind(&socket) {
                Ok(listener) => listener,
                Err(err) => {
                    log::error!("MCPServer: failed to listen on {}: {err}", socket.display());
                    return;
                }
            };
            log::info!("MCPServer: listening on {}", socket.display());
            let mut next_client = 0u64;
            loop {
                match listener.accept() {
                    Ok(conn) => {
                        next_client += 1;
                        let client = next_client;
                        let main = main.clone();
                        let journal = journal.clone();
                        let timers = timers.clone();
                        let socket_path = socket.clone();
                        let bridge = bridge.clone();
                        log::info!("MCPServer: client connected ({client})");
                        let spawned = std::thread::Builder::new()
                            .name(format!("chau7-next-mcp-client-{client}"))
                            .spawn(move || {
                                run_session(conn, main, journal, timers, socket_path, bridge);
                                log::info!("MCPServer: client disconnected ({client})");
                            });
                        if let Err(err) = spawned {
                            log::error!("MCPServer: client thread: {err}");
                        }
                    }
                    Err(err) => {
                        log::warn!("MCPServer: accept: {err}");
                        std::thread::sleep(std::time::Duration::from_millis(100));
                    }
                }
            }
        });
    if let Err(err) = spawned {
        log::error!("MCPServer: server thread: {err}");
    }
}

/// The app side of one client session.
struct Session {
    main: MainThread,
    client_id: String,
    handshake: Handshake,
    observer: super::observer::Observer,
    socket_path: PathBuf,
    bridge: PathBuf,
}

impl McpHost for Session {
    fn handshake(&mut self) -> &mut Handshake {
        &mut self.handshake
    }
    fn tool_definitions(&self) -> Vec<Value> {
        tools::definitions()
    }

    fn call_tool(&mut self, name: &str, arguments: &Map<String, Value>) -> String {
        if name == "chau7_mcp_session_info" {
            return chau7_next_core::mcp::output::encode_sorted(&self.handshake.payload(
                MCP_SERVER_NAME,
                chau7_next_core::mcp::protocol::SERVER_VERSION,
                &self.bridge.to_string_lossy(),
                &self.socket_path.to_string_lossy(),
            ));
        }
        if let Some(result) = self.observer.call(name, arguments) {
            return result;
        }
        tools::call(
            name,
            arguments,
            &ToolContext::connection(&self.main, &self.client_id),
        )
    }

    fn call_tool_result(
        &mut self,
        name: &str,
        arguments: &Map<String, Value>,
    ) -> Result<String, chau7_next_core::mcp::handshake::ProtocolError> {
        if let Decision::Limited {
            retry_after_seconds,
        } = rate_decision(name)
        {
            let mut details = serde_json::json!({
                "error":"rate_limit_exceeded", "tool":name,
                "message":format!("Rate limit exceeded for tool '{name}'.")
            });
            if let Some(seconds) = retry_after_seconds {
                details["retry_after_seconds"] = serde_json::json!(seconds);
            }
            return Ok(chau7_next_core::mcp::output::encode_sorted(&details));
        }
        if name == "chau7_unsubscribe" {
            self.observer.validate_unsubscription(arguments)?;
        }
        Ok(self.call_tool(name, arguments))
    }

    fn resource_definitions(&self) -> Vec<Value> {
        tools::telemetry::resource_definitions()
    }

    fn read_resource(&mut self, uri: &str) -> String {
        tools::telemetry::read_resource(uri)
    }
}

/// Longest request line accepted; a longer one drops the connection.
const MAX_LINE_BYTES: u64 = 8 * 1024 * 1024;

/// Reads one line into `line` (cleared first). `Ok(false)` at end of input,
/// an error when the line exceeds `max` bytes.
fn read_capped_line(
    reader: &mut impl BufRead,
    line: &mut Vec<u8>,
    max: u64,
) -> std::io::Result<bool> {
    line.clear();
    let read = reader.take(max + 1).read_until(b'\n', line)?;
    if read == 0 {
        return Ok(false);
    }
    if line.len() as u64 > max {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "request line too long",
        ));
    }
    Ok(true)
}

/// Read lines until the client closes the connection.
fn run_session(
    conn: Box<dyn Connection>,
    main: MainThread,
    journal: Option<Journal>,
    timers: Option<TimerRegistry>,
    socket_path: PathBuf,
    bridge: PathBuf,
) {
    let writer = match conn.try_clone_box() {
        Ok(writer) => writer,
        Err(err) => {
            log::warn!("MCPServer: {err}");
            return;
        }
    };
    let writer: super::observer::Writer = Arc::new(Mutex::new(writer));
    let mut reader = BufReader::new(conn);
    let client_id = uuid::Uuid::new_v4().to_string();
    if super::control::connect(&client_id).is_err() {
        writer.lock().unwrap_or_else(|e| e.into_inner()).shutdown();
        return;
    }
    let observer = super::observer::Observer::new(
        main.clone(),
        journal,
        timers,
        writer.clone(),
        client_id.clone(),
    );
    let mut session = Session {
        main,
        client_id,
        handshake: Handshake::default(),
        observer,
        socket_path,
        bridge,
    };
    let mut line = Vec::new();
    loop {
        match read_capped_line(&mut reader, &mut line, MAX_LINE_BYTES) {
            Ok(true) => {}
            Ok(false) => break,
            Err(err) => {
                log::warn!("MCPServer: {err}; closing the connection");
                break;
            }
        }
        let text = String::from_utf8_lossy(&line);
        let Some(answer) = handle_line(&text, MCP_SERVER_NAME, &mut session) else {
            continue;
        };
        if super::observer::write_frame(&writer, &answer).is_err() {
            break;
        }
        session.observer.arm();
    }
    super::control::disconnect(&session.client_id, &session.main);
    drop(session);
    writer.lock().unwrap_or_else(|e| e.into_inner()).shutdown();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_lines_are_refused() {
        let mut reader = std::io::Cursor::new(b"short\n0123456789abc\ntail".to_vec());
        let mut line = Vec::new();
        assert!(read_capped_line(&mut reader, &mut line, 8).unwrap());
        assert_eq!(line, b"short\n");
        assert!(read_capped_line(&mut reader, &mut line, 8).is_err());
        let mut reader = std::io::Cursor::new(b"tail".to_vec());
        assert!(read_capped_line(&mut reader, &mut line, 8).unwrap());
        assert_eq!(line, b"tail");
        assert!(!read_capped_line(&mut reader, &mut line, 8).unwrap());
    }
}
