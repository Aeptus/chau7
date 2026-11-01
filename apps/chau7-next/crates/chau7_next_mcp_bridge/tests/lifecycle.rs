#![cfg(unix)]

use std::os::unix::net::UnixListener;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Fixture {
    child: Child,
    socket: std::path::PathBuf,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.socket);
    }
}

#[test]
fn closing_the_response_pipe_stops_an_idle_bridge_without_a_polling_delay() {
    let socket = std::env::temp_dir().join(format!(
        "chau7-bridge-{}-{}.sock",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_chau7-next-mcp-bridge"))
        .arg("--socket")
        .arg(&socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut fixture = Fixture { child, socket };
    let connected_by = Instant::now() + Duration::from_secs(5);
    let _connection = loop {
        match listener.accept() {
            Ok((connection, _)) => break connection,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < connected_by, "bridge did not connect");
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("accept: {error}"),
        }
    };
    // Keep stdin and the app socket open: only the client response reader is gone.
    drop(fixture.child.stdout.take());
    let closed_by = Instant::now() + Duration::from_secs(1);
    loop {
        if let Some(status) = fixture.child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(
            Instant::now() < closed_by,
            "idle bridge waited for a periodic client check"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn owner_exit_stops_a_bridge_even_when_another_process_retains_its_pipes() {
    let status = Command::new("python3")
        .arg("-B")
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/parent_exit.py"))
        .arg(env!("CARGO_BIN_EXE_chau7-next-mcp-bridge"))
        .status()
        .expect("Python fixture starts");
    assert!(status.success(), "bridge missed the parent exit event");
}
