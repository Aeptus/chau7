//! chau7-next-mcp-bridge: pipes stdin and stdout to the Chau7 Next MCP
//! socket (port of `tools/chau7-mcp-bridge/main.swift`).
//!
//! AI CLIs launch it from their config:
//! `{"command": "~/.chau7-next/bin/chau7-next-mcp-bridge", "args": ["--socket", "<socket>"]}`.
//! Without `--socket`, `CHAU7_NEXT_MCP_SOCKET` or the default
//! `DataRoot::mcp_socket` is used.
//!
//! When the app is not running it prints one JSON-RPC error line and exits
//! with status 1. On stdin EOF it shuts down the write side of the socket
//! and keeps copying answers until the app closes the connection. A closed
//! stdout ends the bridge (Rust ignores SIGPIPE, so writes fail with EPIPE).
//!
//! The bridge also exits once its client is gone, without waiting for a
//! write to fail: when the client closed the reading end of stdout, or when
//! the client process died (the bridge is reparented to launchd). An idle
//! client that keeps the pipes open, as Codex's app server does for loaded
//! threads, keeps its bridge.

use std::io::Write;
use std::path::PathBuf;

use chau7_next_core::mcp::{SOCKET_ENV, bridge_error_line, socket_from_args};

fn socket_path() -> PathBuf {
    let args: Vec<String> = std::env::args().skip(1).collect();
    socket_from_args(&args)
        .or_else(|| {
            std::env::var_os(SOCKET_ENV)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        })
        .unwrap_or_else(|| chau7_next_core::data_root::DataRoot::from_env().mcp_socket())
}

fn fail(message: &str) -> ! {
    let mut out = std::io::stdout();
    let _ = out.write_all(bridge_error_line(message).as_bytes());
    let _ = out.flush();
    std::process::exit(1);
}

/// How often the bridge checks that its client is still there.
#[cfg(unix)]
const CLIENT_CHECK_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);

/// Whether the client is gone: the bridge was reparented to launchd (its
/// parent died), or polling stdout reports that its reader hung up.
#[cfg(unix)]
fn client_gone(parent_pid: i32, stdout_revents: i16) -> bool {
    parent_pid == 1 || stdout_revents & (libc::POLLHUP | libc::POLLERR) != 0
}

#[cfg(unix)]
fn stdout_revents() -> i16 {
    let mut fd = libc::pollfd {
        fd: libc::STDOUT_FILENO,
        events: libc::POLLOUT,
        revents: 0,
    };
    // SAFETY: one pollfd for the process's own stdout, zero timeout.
    let ready = unsafe { libc::poll(&mut fd, 1, 0) };
    if ready > 0 { fd.revents } else { 0 }
}

#[cfg(unix)]
fn watch_client() {
    std::thread::spawn(|| {
        loop {
            std::thread::sleep(CLIENT_CHECK_INTERVAL);
            // SAFETY: getppid has no preconditions.
            let parent = unsafe { libc::getppid() };
            if client_gone(parent, stdout_revents()) {
                std::process::exit(0);
            }
        }
    });
}

#[cfg(unix)]
fn main() {
    use std::io::Read;
    use std::os::unix::net::UnixStream;

    let path = socket_path();
    let stream = match UnixStream::connect(&path) {
        Ok(stream) => stream,
        Err(_) => fail(chau7_next_core::mcp::NOT_RUNNING_MESSAGE),
    };
    let Ok(mut to_socket) = stream.try_clone() else {
        fail("Failed to create socket");
    };
    watch_client();
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin().lock();
        let mut buf = [0u8; 65536];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if to_socket.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
        let _ = to_socket.shutdown(std::net::Shutdown::Write);
    });
    let mut from_socket = stream;
    let mut stdout = std::io::stdout().lock();
    let mut buf = [0u8; 65536];
    loop {
        match from_socket.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if stdout.write_all(&buf[..n]).is_err() || stdout.flush().is_err() {
                    break;
                }
            }
        }
    }
}

#[cfg(not(unix))]
fn main() {
    let _ = socket_path();
    fail("The Chau7 Next MCP bridge needs Unix domain sockets, not available on this system.");
}

#[cfg(all(test, unix))]
mod tests {
    use super::client_gone;

    #[test]
    fn a_reparented_bridge_or_a_hung_up_reader_means_the_client_is_gone() {
        assert!(!client_gone(4242, 0));
        assert!(!client_gone(4242, libc::POLLOUT));
        assert!(client_gone(1, 0));
        assert!(client_gone(4242, libc::POLLHUP));
        assert!(client_gone(4242, libc::POLLOUT | libc::POLLERR));
    }
}
