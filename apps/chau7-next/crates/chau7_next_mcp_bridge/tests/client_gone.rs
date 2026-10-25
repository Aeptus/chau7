//! The real bridge binary against a server that never closes its end.
#![cfg(unix)]

use std::os::unix::net::UnixListener;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[test]
fn bridge_exits_when_its_client_closes_stdout() {
    let dir = std::path::PathBuf::from("/tmp").join(format!("c7b-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mcp.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    // Accept and hold the connection open, as an idle app would.
    let server = std::thread::spawn(move || listener.accept().map(|(stream, _)| stream));

    let mut bridge = Command::new(env!("CARGO_BIN_EXE_chau7-next-mcp-bridge"))
        .args(["--socket", socket.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let _held = server.join().unwrap().unwrap();
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        bridge.try_wait().unwrap().is_none(),
        "an idle client keeps its bridge"
    );

    // The client goes away: it stops reading answers. Stdin stays open, so
    // only the hang-up check can notice.
    drop(bridge.stdout.take());
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = bridge.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "bridge outlived its client");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(status.success());
    let _ = std::fs::remove_dir_all(&dir);
}
