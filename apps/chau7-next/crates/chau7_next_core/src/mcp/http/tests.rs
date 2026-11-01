use super::*;
use std::io::{BufRead, Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixListener;

struct Fixture {
    root: PathBuf,
    server: HttpServer,
    backend: Option<std::thread::JoinHandle<()>>,
}

impl Fixture {
    fn new(idle: Duration) -> Self {
        let root = PathBuf::from("/tmp").join(format!("chau7-http-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let socket = root.join("mcp.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        // One fake backend per accepted session; mirrors initialize and one RPC,
        // emits a subscription notification without polling or a timer.
        let backend = std::thread::spawn(move || {
            let mut workers = Vec::new();
            for connection in listener.incoming() {
                let Ok(mut connection) = connection else {
                    break;
                };
                let mut reader = std::io::BufReader::new(connection.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    continue;
                }
                let first: Value = serde_json::from_str(&line).unwrap();
                if first["method"] == "fixture/stop" {
                    break;
                }
                workers.push(std::thread::spawn(move || {
                    loop {
                        let value: Value = serde_json::from_str(&line).unwrap();
                        line.clear();
                        if let Some(id) = value.get("id") {
                            let result = if value["method"] == "initialize" {
                                serde_json::json!({"protocolVersion":value["params"]["protocolVersion"],"capabilities":{},"serverInfo":{"name":"fixture","version":"1"}})
                            } else { value["params"].clone() };
                            if writeln!(connection, "{}", serde_json::json!({"jsonrpc":"2.0","id":id,"result":result})).is_err() { break; }
                        } else if value["method"] == "fixture/notify"
                            && writeln!(connection, "{}", serde_json::json!({"jsonrpc":"2.0","method":"notifications/fixture","params":{"sequence":1}})).is_err()
                        { break; }
                        if reader.read_line(&mut line).unwrap_or(0) == 0 { break; }
                    }
                }));
            }
            for worker in workers {
                worker.join().unwrap();
            }
        });
        let server = HttpServer::start_with_idle(&socket, idle).unwrap();
        Self {
            root,
            server,
            backend: Some(backend),
        }
    }

    fn request(
        &self,
        method: &str,
        session: Option<&str>,
        body: &str,
        extra: &str,
    ) -> (u16, String, Vec<u8>) {
        let mut stream = self.connect();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let authority = self
            .server
            .entry
            .url
            .strip_prefix("http://")
            .unwrap()
            .strip_suffix("/mcp")
            .unwrap();
        let session = session
            .map(|id| format!("Mcp-Session-Id: {id}\r\n"))
            .unwrap_or_default();
        write!(stream, "{method} /mcp HTTP/1.1\r\nHost: {authority}\r\nAuthorization: {}\r\nAccept: application/json, text/event-stream\r\nContent-Type: application/json\r\n{session}{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{body}", self.server.entry.authorization, body.len()).unwrap();
        let mut bytes = Vec::new();
        stream.read_to_end(&mut bytes).unwrap();
        let boundary = bytes
            .windows(4)
            .position(|bytes| bytes == b"\r\n\r\n")
            .unwrap()
            + 4;
        let headers = String::from_utf8(bytes[..boundary].to_vec()).unwrap();
        let code = headers.split_whitespace().nth(1).unwrap().parse().unwrap();
        (code, headers, bytes[boundary..].to_vec())
    }

    fn connect(&self) -> TcpStream {
        TcpStream::connect(
            self.server
                .entry
                .url
                .strip_prefix("http://")
                .unwrap()
                .strip_suffix("/mcp")
                .unwrap(),
        )
        .unwrap()
    }

    fn initialize(&self) -> String {
        let (code, headers, _) = self.request("POST", None, r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#, "");
        assert_eq!(code, 200);
        headers
            .lines()
            .find_map(|line| line.strip_prefix("mcp-session-id: "))
            .unwrap()
            .to_owned()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.stop();
        if let Some(thread) = self.server.thread.lock().unwrap().take() {
            thread.join().unwrap();
        }
        // Wake the owned fake listener after all transport sessions have closed.
        if let Ok(mut socket) = std::os::unix::net::UnixStream::connect(self.root.join("mcp.sock"))
        {
            let _ = writeln!(
                socket,
                "{}",
                serde_json::json!({"jsonrpc":"2.0","method":"fixture/stop"})
            );
        }
        if let Some(thread) = self.backend.take() {
            thread.join().unwrap();
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn http_handshake_rpc_notifications_and_delete_share_one_session() {
    let fixture = Fixture::new(Duration::from_secs(60));
    let id = fixture.initialize();
    assert_eq!(
        fixture
            .request(
                "POST",
                Some(&id),
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                ""
            )
            .0,
        202
    );
    let (code, _, body) = fixture.request(
        "POST",
        Some(&id),
        r#"{"jsonrpc":"2.0","id":1,"method":"fixture/echo","params":{"client":"first"}}"#,
        "",
    );
    assert_eq!(code, 200);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["result"]["client"],
        "first"
    );
    assert_eq!(
        fixture
            .request(
                "POST",
                Some(&id),
                r#"{"jsonrpc":"2.0","method":"fixture/notify"}"#,
                ""
            )
            .0,
        202
    );
    let mut stream = fixture.connect();
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let authority = fixture
        .server
        .entry
        .url
        .strip_prefix("http://")
        .unwrap()
        .strip_suffix("/mcp")
        .unwrap();
    write!(stream, "GET /mcp HTTP/1.1\r\nHost: {authority}\r\nAuthorization: {}\r\nAccept: text/event-stream\r\nMcp-Session-Id: {id}\r\n\r\n", fixture.server.entry.authorization).unwrap();
    let mut reader = std::io::BufReader::new(stream);
    let mut found = false;
    for _ in 0..20 {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        if line.starts_with("data: ") {
            assert!(line.contains("notifications/fixture"));
            found = true;
            break;
        }
    }
    assert!(found);
    assert_eq!(fixture.request("DELETE", Some(&id), "", "").0, 204);
    assert_eq!(
        fixture
            .request(
                "POST",
                Some(&id),
                r#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
                ""
            )
            .0,
        404
    );
    let second = fixture.initialize();
    assert_ne!(second, id);
}

#[test]
fn http_rejects_bad_origin_version_batches_and_missing_session() {
    let fixture = Fixture::new(Duration::from_secs(60));
    assert_eq!(
        fixture
            .request("POST", None, "{}", "Origin: https://attacker.invalid\r\n")
            .0,
        403
    );
    assert_eq!(
        fixture
            .request("POST", None, "{}", "MCP-Protocol-Version: 1999-01-01\r\n")
            .0,
        400
    );
    assert_eq!(fixture.request("POST", None, "[]", "").0, 400);
    assert_eq!(
        fixture
            .request(
                "POST",
                None,
                r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
                ""
            )
            .0,
        400
    );
    assert_eq!(fixture.request("GET", Some("unknown"), "", "").0, 404);
    assert_eq!(
        fixture
            .request("POST", None, &" ".repeat(MAX_BODY + 1), "")
            .0,
        413
    );
}

#[test]
fn http_idle_session_expires_without_polling() {
    let fixture = Fixture::new(Duration::from_millis(40));
    let id = fixture.initialize();
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(fixture.request("DELETE", Some(&id), "", "").0, 404);
}

#[test]
fn credentials_are_private_stable_and_invalid_state_is_not_overwritten() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new(Duration::from_secs(60));
    let path = fixture.root.join("mcp.http.json");
    let original = Credentials::load(&path).unwrap();
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    fixture.server.stop();
    fixture
        .server
        .thread
        .lock()
        .unwrap()
        .take()
        .unwrap()
        .join()
        .unwrap();
    let restarted = HttpServer::start(&fixture.root.join("mcp.sock")).unwrap();
    assert_eq!(restarted.entry.url, fixture.server.entry.url);
    assert_eq!(Credentials::load(&path).unwrap().token, original.token);
    restarted.stop();
    restarted
        .thread
        .lock()
        .unwrap()
        .take()
        .unwrap()
        .join()
        .unwrap();
    std::fs::write(&path, "broken").unwrap();
    assert!(HttpServer::start(&fixture.root.join("mcp.sock")).is_err());
    assert_eq!(std::fs::read_to_string(path).unwrap(), "broken");
}

#[test]
fn client_ids_are_isolated_and_invalid_http_security_headers_are_rejected() {
    let fixture = Fixture::new(Duration::from_secs(60));
    let first = fixture.initialize();
    let second = fixture.initialize();
    for (id, label) in [(&first, "one"), (&second, "two")] {
        let body = serde_json::json!({"jsonrpc":"2.0","id":1,"method":"fixture/echo","params":{"client":label}}).to_string();
        let (code, _, body) = fixture.request("POST", Some(id), &body, "");
        assert_eq!(code, 200);
        assert_eq!(
            serde_json::from_slice::<Value>(&body).unwrap()["result"]["client"],
            label
        );
    }
    let authority = fixture
        .server
        .entry
        .url
        .strip_prefix("http://")
        .unwrap()
        .strip_suffix("/mcp")
        .unwrap();
    for (host, authorization, accept, expected) in [
        (
            authority,
            "Bearer wrong",
            "application/json, text/event-stream",
            401,
        ),
        (
            "attacker.invalid",
            &fixture.server.entry.authorization,
            "application/json, text/event-stream",
            403,
        ),
        (
            authority,
            &fixture.server.entry.authorization,
            "application/json",
            406,
        ),
    ] {
        let mut stream = fixture.connect();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        write!(stream, "POST /mcp HTTP/1.1\r\nHost: {host}\r\nAuthorization: {authorization}\r\nAccept: {accept}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}").unwrap();
        let mut reply = String::new();
        stream.read_to_string(&mut reply).unwrap();
        assert_eq!(
            reply
                .split_whitespace()
                .nth(1)
                .unwrap()
                .parse::<u16>()
                .unwrap(),
            expected
        );
    }
}

#[test]
#[ignore = "owned native idle fixture; run explicitly with --exact --ignored --nocapture"]
fn http_idle_native_fixture() {
    let fixture = Fixture::new(Duration::from_secs(60));
    let _first = fixture.initialize();
    let _second = fixture.initialize();
    println!("HTTP_IDLE_READY {}", std::process::id());
    std::io::stdout().flush().unwrap();
    std::thread::sleep(Duration::from_secs(10));
}

#[test]
fn subscription_queue_overflow_closes_session_and_stream_handoff_keeps_messages() {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            let (client, mut backend) = tokio::net::UnixStream::pair().unwrap();
            let capacity = Arc::new(Semaphore::new(1));
            let session = Session::new(
                client,
                PROTOCOLS[0].into(),
                capacity.clone().acquire_owned().await.unwrap(),
            );
            let first_connection = Arc::new(ConnectionCancel::default());
            let first = session.open_stream(first_connection.clone());
            let old = session.clone();
            let old_stream = tokio::spawn(async move { old.next_notification(first).await });
            tokio::task::yield_now().await;
            let second_connection = Arc::new(ConnectionCancel::default());
            let second = session.open_stream(second_connection.clone());
            tokio::time::timeout(Duration::from_secs(1), first_connection.wait())
                .await
                .unwrap();
            tokio::io::AsyncWriteExt::write_all(
                &mut backend,
                b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/fixture\"}\n",
            )
            .await
            .unwrap();
            assert!(
                tokio::time::timeout(Duration::from_secs(1), old_stream)
                    .await
                    .unwrap()
                    .unwrap()
                    .is_none()
            );
            let frame =
                tokio::time::timeout(Duration::from_secs(1), session.next_notification(second))
                    .await
                    .unwrap()
                    .unwrap();
            assert!(
                std::str::from_utf8(&frame)
                    .unwrap()
                    .contains("notifications/fixture")
            );
            let notifications =
                b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/fixture\"}\n".repeat(65);
            tokio::io::AsyncWriteExt::write_all(&mut backend, &notifications)
                .await
                .unwrap();
            tokio::time::timeout(Duration::from_secs(1), session.wait_closed())
                .await
                .unwrap();
            assert!(session.closed.load(Ordering::Acquire));
            tokio::time::timeout(Duration::from_secs(1), second_connection.wait())
                .await
                .unwrap();
            drop(session);
            tokio::task::yield_now().await;
            assert_eq!(capacity.available_permits(), 1);
        });
}

#[test]
fn closing_retained_session_releases_backend_and_capacity() {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            let (client, mut backend) = tokio::net::UnixStream::pair().unwrap();
            let capacity = Arc::new(Semaphore::new(1));
            let session = Session::new(
                client,
                PROTOCOLS[0].into(),
                capacity.clone().acquire_owned().await.unwrap(),
            );
            session.close();
            session.close(); // Idempotent while response bodies still retain the session.
            let late_connection = Arc::new(ConnectionCancel::default());
            session.open_stream(late_connection.clone());
            tokio::time::timeout(Duration::from_secs(1), late_connection.wait())
                .await
                .unwrap();
            let mut byte = [0];
            let read = tokio::time::timeout(
                Duration::from_secs(1),
                tokio::io::AsyncReadExt::read(&mut backend, &mut byte),
            )
            .await;
            assert!(
                matches!(read, Ok(Ok(0))),
                "retained closed session keeps backend open: {read:?}"
            );
            assert_eq!(capacity.available_permits(), 1);
            assert!(session.closed.load(Ordering::Acquire));
        });
}
