//! End to end over the real socket: a fake agent (a plain Unix socket client
//! speaking the frame protocol) talks to the IPC server and the host.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::remote::frame::{RemoteFrame, RemoteFrameType};
use chau7_next_core::remote::frame_parser::{pack_for_transport, parse_frames};
use chau7_next_core::remote::models::{ApprovalRequestPayload, RemoteTabListPayload};

use super::host::RemoteHost;
use super::host::tests::FakeEnv;
use super::ipc::{IpcEvent, IpcServer};
use super::{IpcSink, agent};

struct FakeAgent {
    stream: UnixStream,
    buffer: Vec<u8>,
    seq: u64,
}

impl FakeAgent {
    fn connect(path: &std::path::Path) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_millis(50)))
            .unwrap();
        Self {
            stream,
            buffer: Vec::new(),
            seq: 1,
        }
    }

    fn send(&mut self, kind: RemoteFrameType, tab_id: u32, payload: &[u8]) {
        let frame = RemoteFrame::new(kind.raw_value(), tab_id, self.seq, payload.to_vec());
        self.seq += 1;
        self.stream.write_all(&pack_for_transport(&frame)).unwrap();
    }

    /// Frames received until `until` returns true (or 3 s).
    fn read_until(&mut self, mut until: impl FnMut(&[RemoteFrame]) -> bool) -> Vec<RemoteFrame> {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut frames = Vec::new();
        let mut chunk = [0u8; 65536];
        while Instant::now() < deadline && !until(&frames) {
            match self.stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    self.buffer.extend_from_slice(&chunk[..n]);
                    frames.extend(parse_frames(&mut self.buffer).frames);
                }
                Err(_) => {}
            }
        }
        frames
    }

    fn is_closed(&mut self) -> bool {
        let mut byte = [0u8; 1];
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            match self.stream.read(&mut byte) {
                Ok(0) => return true,
                Ok(_) => {}
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => return true,
            }
        }
        false
    }
}

/// Run the host on the server's events until `done` or 3 s.
fn pump(
    server: &IpcServer,
    host: &mut RemoteHost,
    env: &mut FakeEnv,
    mut done: impl FnMut(&RemoteHost, &FakeEnv, &[IpcEvent]) -> bool,
) -> Vec<IpcEvent> {
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut seen = Vec::new();
    while Instant::now() < deadline {
        for event in server.drain() {
            let mut sink = IpcSink(Some(server));
            match &event {
                IpcEvent::Connected => host.on_connected(env, &mut sink),
                IpcEvent::Frame(frame) => host.handle_frame(frame.clone(), env, &mut sink),
                IpcEvent::Disconnected => host.on_disconnected(),
            }
            seen.push(event);
        }
        if done(host, env, &seen) {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    seen
}

fn kinds(frames: &[RemoteFrame]) -> Vec<RemoteFrameType> {
    frames.iter().filter_map(RemoteFrame::frame_type).collect()
}

fn temp_socket(name: &str) -> (PathBuf, PathBuf) {
    // Short path: Unix socket paths are limited to about 100 bytes.
    let dir = PathBuf::from("/tmp").join(format!("c7n-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    (dir.clone(), dir.join("agent.sock"))
}

#[test]
fn fake_agent_drives_the_host_over_the_socket() {
    let (dir, path) = temp_socket("e2e");
    let mut server = IpcServer::start(&path).unwrap();
    let mut host = RemoteHost::new();
    let mut env = FakeEnv::new();

    // The agent connects and announces the pairing code (as the Go agent does).
    let mut agent = FakeAgent::connect(&path);
    agent.send(
        RemoteFrameType::PairingInfo,
        0,
        br#"{"device_id":"dev","mac_pub":"pub","pairing_code":"424242","expires_at":"2026-10-10T10:10:00Z","relay_url":"wss://relay.test/connect"}"#,
    );
    pump(&server, &mut host, &mut env, |h, _, _| {
        h.pairing_info.is_some()
    });
    assert!(host.ipc_connected);
    assert_eq!(host.pairing_info.as_ref().unwrap().pairing_code, "424242");

    // Initial state on connect.
    let frames = agent.read_until(|f| kinds(f).contains(&RemoteFrameType::InteractivePromptList));
    assert_eq!(
        kinds(&frames),
        [
            RemoteFrameType::TabList,
            RemoteFrameType::Snapshot,
            RemoteFrameType::TerminalGridSnapshot,
            RemoteFrameType::ActivityCleared,
            RemoteFrameType::InteractivePromptList,
        ]
    );
    let list: RemoteTabListPayload = serde_json::from_slice(&frames[0].payload).unwrap();
    assert_eq!(list.tabs.len(), 2);

    // A bad length prefix is skipped; the next frame still arrives.
    agent.stream.write_all(&0u32.to_le_bytes()).unwrap();
    agent.send(RemoteFrameType::Input, 0, b"echo hi\n");
    pump(&server, &mut host, &mut env, |_, e, _| !e.typed.is_empty());
    assert_eq!(env.typed, [(10, "echo hi\n".to_string())]);

    // Ping, pong.
    agent.send(RemoteFrameType::Ping, 0, b"p1");
    pump(&server, &mut host, &mut env, |_, _, seen| !seen.is_empty());
    let frames = agent.read_until(|f| kinds(f).contains(&RemoteFrameType::Pong));
    assert_eq!(frames.last().unwrap().payload, b"p1");

    // A protected action waits for the phone.
    agent.send(RemoteFrameType::Input, 2, b"killall chau7\n");
    pump(&server, &mut host, &mut env, |h, _, _| {
        !h.pending_approval_ids().is_empty()
    });
    let frames = agent.read_until(|f| kinds(f).contains(&RemoteFrameType::ApprovalRequest));
    let request: ApprovalRequestPayload = serde_json::from_slice(
        &frames
            .iter()
            .find(|f| f.frame_type() == Some(RemoteFrameType::ApprovalRequest))
            .unwrap()
            .payload,
    )
    .unwrap();
    assert_eq!(request.tab_title.as_deref(), Some("Build"));
    assert_eq!(env.typed.len(), 1);
    let answer = format!(
        r#"{{"request_id":"{}","approved":true}}"#,
        request.request_id
    );
    agent.send(RemoteFrameType::ApprovalResponse, 0, answer.as_bytes());
    pump(&server, &mut host, &mut env, |_, e, _| e.typed.len() == 2);
    assert_eq!(env.typed[1], (20, "killall chau7\n".to_string()));

    // A second agent replaces the first; the first is closed.
    let mut second = FakeAgent::connect(&path);
    let seen = pump(&server, &mut host, &mut env, |_, _, seen| {
        seen.contains(&IpcEvent::Connected)
    });
    assert!(!seen.contains(&IpcEvent::Disconnected));
    assert!(agent.is_closed());
    let frames = second.read_until(|f| kinds(f).contains(&RemoteFrameType::TabList));
    assert!(kinds(&frames).contains(&RemoteFrameType::TabList));

    // The agent goes away.
    drop(second);
    pump(&server, &mut host, &mut env, |h, _, _| !h.ipc_connected);
    assert!(!host.ipc_connected);

    server.stop();
    assert!(!path.exists());
    let _ = std::fs::remove_dir_all(dir);
}

/// The real Go agent against our socket, with our state file. Needs Go and
/// network access for its modules, so it is run by hand:
/// `cargo test -p chau7_next real_go_agent -- --ignored`.
#[test]
#[ignore]
fn real_go_agent_pairs_with_its_own_state() {
    let (dir, _) = temp_socket("go");
    let root = DataRoot::with_home(dir.join("h"), true);
    let mut server = IpcServer::start(&root.remote_socket()).unwrap();
    let binary = dir.join("chau7-remote");
    let source =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../services/chau7-remote");
    let status = std::process::Command::new("go")
        .args(["build", "-o"])
        .arg(&binary)
        .arg("./cmd/chau7-remote")
        .current_dir(&source)
        .status()
        .unwrap();
    assert!(status.success());
    let process = agent::AgentProcess::spawn(
        &binary,
        &root,
        "ws://127.0.0.1:9/connect",
        Some("Test".into()),
    )
    .unwrap();
    let mut host = RemoteHost::new();
    let mut env = FakeEnv::new();
    pump(&server, &mut host, &mut env, |h, _, _| {
        h.pairing_info.is_some()
    });
    let info = host
        .pairing_info
        .clone()
        .expect("pairing info from the agent");
    assert_eq!(info.pairing_code.len(), 6);
    assert_eq!(info.relay_url, "ws://127.0.0.1:9/connect");
    // The agent wrote its identity into our state file, not anywhere else.
    let state = std::fs::read_to_string(root.remote_state_file()).unwrap();
    assert!(state.contains(&info.device_id));
    process.stop();
    server.stop();
    let _ = std::fs::remove_dir_all(dir);
}
