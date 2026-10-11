//! The socket server (`MCPServerManager._start`, `MCPSession.run`): one
//! listener thread, one thread per client. Each line from a client is one
//! JSON-RPC message; each answer is one line, flushed.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;

use chau7_next_core::data_root::MCP_SERVER_NAME;
use chau7_next_core::mcp::protocol::{McpHost, handle_line};
use serde_json::{Map, Value};

use super::MainThread;
use super::tools::{self, ToolContext};
use crate::platform::local_socket::{Connection, Listener};

/// Bind the socket and accept clients on a background thread.
pub(super) fn spawn(socket: PathBuf, main: MainThread) {
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
                        log::info!("MCPServer: client connected ({client})");
                        let spawned = std::thread::Builder::new()
                            .name(format!("chau7-next-mcp-client-{client}"))
                            .spawn(move || {
                                run_session(conn, main);
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
}

impl McpHost for Session {
    fn tool_definitions(&self) -> Vec<Value> {
        tools::definitions()
    }

    fn call_tool(&mut self, name: &str, arguments: &Map<String, Value>) -> String {
        tools::call(name, arguments, &ToolContext { main: &self.main })
    }

    fn resource_definitions(&self) -> Vec<Value> {
        tools::telemetry::resource_definitions()
    }

    fn read_resource(&mut self, uri: &str) -> String {
        tools::telemetry::read_resource(uri)
    }
}

/// Longest request line accepted; a longer one drops the connection.
const MAX_LINE_BYTES: u64 = 4 * 1024 * 1024;

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
fn run_session(conn: Box<dyn Connection>, main: MainThread) {
    let mut writer = match conn.try_clone_box() {
        Ok(writer) => writer,
        Err(err) => {
            log::warn!("MCPServer: {err}");
            return;
        }
    };
    let mut reader = BufReader::new(conn);
    let mut session = Session { main };
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
        if writer.write_all(answer.as_bytes()).is_err()
            || writer.write_all(b"\n").is_err()
            || writer.flush().is_err()
        {
            break;
        }
    }
    writer.shutdown();
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
