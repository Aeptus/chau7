//! Shared, authenticated loopback Streamable HTTP transport (MCP 2025-11-25).
//! Each HTTP session uses the existing socket dispatcher, permission state and
//! subscriptions. One event-driven runtime serves all HTTP connections; no bridge
//! subprocesses or periodic connection polling are needed.

mod endpoint_state;
mod session;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::convert::Infallible;
use std::io;
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::stream;
use http_body_util::{BodyExt, Full, Limited, StreamBody, combinators::UnsyncBoxBody};
use hyper::body::{Bytes, Frame, Incoming};
use hyper::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HOST, ORIGIN};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::Value;
use tokio::sync::{Semaphore, oneshot};

use super::client_config::HttpEntry;
use endpoint_state::Credentials;
use session::{ConnectionCancel, Session};

type Body = UnsyncBoxBody<Bytes, Infallible>;
const MAX_BODY: usize = 2 * 1024 * 1024;
const IDLE_EXPIRY: Duration = Duration::from_secs(30 * 60);
const PROTOCOLS: &[&str] = &["2025-11-25", "2025-06-18"];

/// Running in-process listener. Shutdown signals its runtime without blocking UI.
pub struct HttpServer {
    entry: HttpEntry,
    stop: Mutex<Option<oneshot::Sender<()>>>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
}

impl HttpServer {
    pub fn start(socket: &Path) -> io::Result<Self> {
        Self::start_with_idle(socket, IDLE_EXPIRY)
    }

    fn start_with_idle(socket: &Path, idle: Duration) -> io::Result<Self> {
        let state_path = socket.with_extension("http.json");
        let mut credentials = Credentials::load(&state_path)?;
        let listener = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, credentials.port))?;
        listener.set_nonblocking(true)?;
        credentials.port = listener.local_addr()?.port();
        credentials.save(&state_path)?;
        let entry = HttpEntry {
            url: format!("http://127.0.0.1:{}/mcp", credentials.port),
            authorization: format!("Bearer {}", credentials.token),
        };
        let state = Arc::new(State {
            socket: socket.into(),
            authority: format!("127.0.0.1:{}", credentials.port),
            localhost: format!("localhost:{}", credentials.port),
            authorization: entry.authorization.clone(),
            sessions: tokio::sync::Mutex::new(HashMap::new()),
            capacity: Arc::new(Semaphore::new(32)),
            requests: Arc::new(Semaphore::new(32)),
            idle,
        });
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let (stop, stopped) = oneshot::channel();
        let thread =
            std::thread::Builder::new()
                .name("chau7-mcp-http".into())
                .spawn(move || {
                    runtime.block_on(async move {
                        let Ok(listener) = tokio::net::TcpListener::from_std(listener) else {
                            return;
                        };
                        let connections = Arc::new(Semaphore::new(64));
                        tokio::pin!(stopped);
                        loop {
                            let accepted = tokio::select! {
                                _ = &mut stopped => break,
                                accepted = listener.accept() => accepted,
                            };
                            let Ok((stream, _)) = accepted else { break };
                            let Ok(permit) = connections.clone().try_acquire_owned() else {
                                continue;
                            };
                            let state = state.clone();
                            tokio::spawn(async move {
                                let _permit = permit;
                                let connection = Arc::new(ConnectionCancel::default());
                                let active = connection.clone();
                                let service = service_fn(move |request| {
                                    let state = state.clone();
                                    let active = active.clone();
                                    async move {
                                        Ok::<_, Infallible>(state.handle(request, active).await)
                                    }
                                });
                                let mut http = http1::Builder::new();
                                http.timer(TokioTimer::new())
                                    .header_read_timeout(Duration::from_secs(10))
                                    .max_headers(64)
                                    .max_buf_size(32 * 1024);
                                tokio::select! {
                                    _ = connection.wait() => {},
                                    _ = http.serve_connection(TokioIo::new(stream), service) => {},
                                }
                            });
                        }
                        for session in state
                            .sessions
                            .lock()
                            .await
                            .drain()
                            .map(|(_, session)| session)
                        {
                            session.close();
                        }
                    });
                })?;
        Ok(Self {
            entry,
            stop: Mutex::new(Some(stop)),
            thread: Mutex::new(Some(thread)),
        })
    }

    pub fn entry(&self) -> &HttpEntry {
        &self.entry
    }

    pub fn stop(&self) {
        if let Some(stop) = self.stop.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = stop.send(());
        }
    }
}

impl Drop for HttpServer {
    fn drop(&mut self) {
        self.stop();
        // Do not join from the UI thread. Runtime shutdown drops all owned sockets.
        self.thread.lock().unwrap_or_else(|e| e.into_inner()).take();
    }
}

struct State {
    socket: PathBuf,
    authority: String,
    localhost: String,
    authorization: String,
    sessions: tokio::sync::Mutex<HashMap<String, Arc<Session>>>,
    capacity: Arc<Semaphore>,
    requests: Arc<Semaphore>,
    idle: Duration,
}

impl State {
    async fn handle(
        self: Arc<Self>,
        request: Request<Incoming>,
        connection: Arc<ConnectionCancel>,
    ) -> Response<Body> {
        if request.uri().path() != "/mcp" || request.uri().query().is_some() {
            return status(StatusCode::NOT_FOUND);
        }
        let headers = request.headers();
        let host = headers.get(HOST).and_then(|v| v.to_str().ok());
        if host != Some(&self.authority) && host != Some(&self.localhost) {
            return status(StatusCode::FORBIDDEN);
        }
        if let Some(origin) = headers.get(ORIGIN) {
            let Ok(origin) = origin.to_str() else {
                return status(StatusCode::FORBIDDEN);
            };
            if origin != format!("http://{}", self.authority)
                && origin != format!("http://{}", self.localhost)
            {
                return status(StatusCode::FORBIDDEN);
            }
        }
        if headers
            .get(AUTHORIZATION)
            .is_none_or(|value| value.as_bytes() != self.authorization.as_bytes())
        {
            return Response::builder()
                .status(StatusCode::UNAUTHORIZED)
                .header("WWW-Authenticate", "Bearer")
                .body(empty())
                .unwrap();
        }
        let version = headers
            .get("mcp-protocol-version")
            .map(|v| v.to_str().unwrap_or_default().to_owned());
        if version
            .as_deref()
            .is_some_and(|version| !PROTOCOLS.contains(&version))
        {
            return status(StatusCode::BAD_REQUEST);
        }
        let session_id = headers
            .get("mcp-session-id")
            .map(|v| v.to_str().unwrap_or_default().to_owned());
        let session = if let Some(id) = &session_id {
            let session = self.sessions.lock().await.get(id).cloned();
            let Some(session) = session.filter(|s| !s.closed.load(Ordering::Acquire)) else {
                return status(StatusCode::NOT_FOUND);
            };
            if version
                .as_deref()
                .is_some_and(|version| version != session.protocol)
            {
                return status(StatusCode::BAD_REQUEST);
            }
            Some(session)
        } else {
            None
        };
        match *request.method() {
            Method::GET => {
                let Some(session) = session else {
                    return status(StatusCode::BAD_REQUEST);
                };
                if !accepts(headers, "text/event-stream") {
                    return status(StatusCode::NOT_ACCEPTABLE);
                }
                session.touch();
                let epoch = session.open_stream(connection);
                let body = StreamBody::new(stream::unfold(
                    (session, epoch),
                    |(session, epoch)| async move {
                        let bytes = session.next_notification(epoch).await?;
                        Some((Ok::<_, Infallible>(Frame::data(bytes)), (session, epoch)))
                    },
                ))
                .boxed_unsync();
                Response::builder()
                    .header(CONTENT_TYPE, "text/event-stream")
                    .header("Cache-Control", "no-store")
                    .body(body)
                    .unwrap()
            }
            Method::DELETE => {
                let Some(session) = session else {
                    return status(StatusCode::BAD_REQUEST);
                };
                session.close();
                self.sessions.lock().await.remove(&session.id);
                status(StatusCode::NO_CONTENT)
            }
            Method::POST => {
                if !accepts(headers, "application/json") || !accepts(headers, "text/event-stream") {
                    return status(StatusCode::NOT_ACCEPTABLE);
                }
                if headers
                    .get(CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .is_none_or(|v| {
                        v.split(';').next().unwrap_or_default().trim() != "application/json"
                    })
                {
                    return status(StatusCode::UNSUPPORTED_MEDIA_TYPE);
                }
                let Ok(permit) = self.requests.clone().try_acquire_owned() else {
                    return status(StatusCode::SERVICE_UNAVAILABLE);
                };
                let collected = tokio::time::timeout(
                    Duration::from_secs(10),
                    Limited::new(request.into_body(), MAX_BODY).collect(),
                )
                .await;
                let bytes = match collected {
                    Err(_) => return status(StatusCode::REQUEST_TIMEOUT),
                    Ok(Err(_)) => return status(StatusCode::PAYLOAD_TOO_LARGE),
                    Ok(Ok(body)) => body.to_bytes(),
                };
                let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
                    return status(StatusCode::BAD_REQUEST);
                };
                if !valid_rpc(&value) {
                    return status(StatusCode::BAD_REQUEST);
                }
                let initialize = value.get("method").and_then(Value::as_str) == Some("initialize");
                if initialize && (session.is_some() || value.get("id").is_none()) {
                    return status(StatusCode::BAD_REQUEST);
                }
                let session = if initialize {
                    let Some(protocol) = value
                        .pointer("/params/protocolVersion")
                        .and_then(Value::as_str)
                        .filter(|p| PROTOCOLS.contains(p))
                    else {
                        return status(StatusCode::BAD_REQUEST);
                    };
                    if version
                        .as_deref()
                        .is_some_and(|version| version != protocol)
                    {
                        return status(StatusCode::BAD_REQUEST);
                    }
                    let Ok(capacity) = self.capacity.clone().try_acquire_owned() else {
                        return status(StatusCode::SERVICE_UNAVAILABLE);
                    };
                    let stream = match tokio::time::timeout(
                        Duration::from_secs(1),
                        tokio::net::UnixStream::connect(&self.socket),
                    )
                    .await
                    {
                        Ok(Ok(stream)) => stream,
                        _ => return status(StatusCode::SERVICE_UNAVAILABLE),
                    };
                    let session = Session::new(stream, protocol.to_owned(), capacity);
                    self.sessions
                        .lock()
                        .await
                        .insert(session.id.clone(), session.clone());
                    let state = self.clone();
                    let active = session.clone();
                    tokio::spawn(async move {
                        active.clone().expire_after(state.idle).await;
                        state.sessions.lock().await.remove(&active.id);
                    });
                    session
                } else {
                    let Some(session) = session else {
                        return status(StatusCode::BAD_REQUEST);
                    };
                    session
                };
                // Keep the complete socket exchange alive on HTTP disconnect. Cancelling
                // a partial Unix write would corrupt framing, or cancel an approval.
                let session_info = value.get("method").and_then(Value::as_str)
                    == Some("tools/call")
                    && value.pointer("/params/name").and_then(Value::as_str)
                        == Some("chau7_mcp_session_info");
                let active = session.clone();
                let reply = tokio::spawn(async move {
                    let _permit = permit;
                    active.send(&value).await
                })
                .await;
                match reply {
                    Ok(Ok(Some(mut value))) => {
                        if initialize && value.get("error").is_some() {
                            session.close();
                        }
                        if session_info {
                            annotate_transport(&mut value, &self.authority);
                        }
                        let mut response = Response::builder()
                            .header(CONTENT_TYPE, "application/json")
                            .header("Cache-Control", "no-store");
                        if initialize && value.get("error").is_none() {
                            response = response.header("mcp-session-id", &session.id);
                        }
                        response
                            .body(Full::new(Bytes::from(value.to_string())).boxed_unsync())
                            .unwrap()
                    }
                    Ok(Ok(None)) => status(StatusCode::ACCEPTED),
                    _ => {
                        session.close();
                        status(StatusCode::BAD_GATEWAY)
                    }
                }
            }
            _ => Response::builder()
                .status(StatusCode::METHOD_NOT_ALLOWED)
                .header("Allow", "POST, GET, DELETE")
                .body(empty())
                .unwrap(),
        }
    }
}

fn accepts(headers: &hyper::HeaderMap, wanted: &str) -> bool {
    headers
        .get_all(ACCEPT)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .any(|v| v.split(';').next().unwrap_or_default().trim() == wanted)
}

fn valid_rpc(value: &Value) -> bool {
    value.is_object()
        && value.get("jsonrpc").and_then(Value::as_str) == Some("2.0")
        && value
            .get("id")
            .is_none_or(|id| id.is_string() || id.is_number())
        && match value.get("method") {
            Some(method) => {
                method.is_string() && value.get("result").is_none() && value.get("error").is_none()
            }
            None => {
                value.get("id").is_some()
                    && (value.get("result").is_some() ^ value.get("error").is_some())
            }
        }
}

fn annotate_transport(value: &mut Value, authority: &str) {
    // Session metadata describes the client-facing transport. Do not expose its
    // bearer credential. Ordinary tool output is left unchanged.
    let Some(result) = value.get_mut("result") else {
        return;
    };
    let Some(content) = result.get_mut("structuredContent") else {
        return;
    };
    if content.get("transport").and_then(Value::as_str) != Some("unix_socket") {
        return;
    }
    content["transport"] = "streamable_http".into();
    content["resolved_command_path"] = Value::Null;
    content["http_url"] = format!("http://{authority}/mcp").into();
    let encoded = content.to_string();
    if let Some(text) = result.pointer_mut("/content/0/text") {
        *text = encoded.into();
    }
}

fn empty() -> Body {
    Full::new(Bytes::new()).boxed_unsync()
}
fn status(code: StatusCode) -> Response<Body> {
    Response::builder().status(code).body(empty()).unwrap()
}
