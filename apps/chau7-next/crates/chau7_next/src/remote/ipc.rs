//! Local IPC server the `chau7-remote` agent connects to
//! (`Remote/RemoteIPCServer.swift`).
//!
//! A Unix socket in the Chau7 Next state folder (`DataRoot::remote_socket`).
//! One client at a time: a new connection replaces the old one. Frames are
//! length-prefixed (`FrameParser`), at most 5 MB; bad frames are skipped and
//! logged. Reading, accepting and writing run on background threads; the app
//! drains [`IpcEvent`]s from its timer, so a stalled agent never blocks the UI.

use chau7_next_core::remote::frame::RemoteFrame;

/// What happened on the socket since the last [`IpcServer::drain`].
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(not(unix), allow(dead_code))]
pub enum IpcEvent {
    Connected,
    Frame(RemoteFrame),
    Disconnected,
}

#[cfg(unix)]
pub use unix::IpcServer;

#[cfg(unix)]
mod unix {
    use std::collections::VecDeque;
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::time::Duration;

    use chau7_next_core::remote::frame::RemoteFrame;
    use chau7_next_core::remote::frame_parser::{
        DEFAULT_MAX_FRAME_SIZE, pack_for_transport, parse_frames_with_max,
    };
    use parking_lot::Mutex;

    use super::IpcEvent;

    struct Shared {
        events: Mutex<VecDeque<IpcEvent>>,
        /// The connected client and its connection number.
        client: Mutex<Option<(u64, UnixStream)>>,
        next_conn: AtomicU64,
        stop: AtomicBool,
    }

    impl Shared {
        fn push(&self, event: IpcEvent) {
            self.events.lock().push_back(event);
        }

        /// Close connection `conn` if it is still the current one, and
        /// report it once.
        fn disconnect(&self, conn: u64) {
            let mut client = self.client.lock();
            if client.as_ref().is_some_and(|(id, _)| *id == conn) {
                if let Some((_, stream)) = client.take() {
                    let _ = stream.shutdown(std::net::Shutdown::Both);
                }
                drop(client);
                self.push(IpcEvent::Disconnected);
            }
        }
    }

    pub struct IpcServer {
        path: PathBuf,
        shared: Arc<Shared>,
        outgoing: Option<Sender<Vec<u8>>>,
    }

    impl IpcServer {
        /// Bind `path` (a stale socket file is removed first) and start
        /// accepting.
        pub fn start(path: &Path) -> std::io::Result<Self> {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let _ = std::fs::remove_file(path);
            let listener = UnixListener::bind(path)?;
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
            }
            listener.set_nonblocking(true)?;
            let shared = Arc::new(Shared {
                events: Mutex::new(VecDeque::new()),
                client: Mutex::new(None),
                next_conn: AtomicU64::new(1),
                stop: AtomicBool::new(false),
            });
            let (tx, rx) = channel::<Vec<u8>>();
            {
                let shared = shared.clone();
                std::thread::Builder::new()
                    .name("remote-ipc-accept".into())
                    .spawn(move || accept_loop(listener, shared))?;
            }
            {
                let shared = shared.clone();
                std::thread::Builder::new()
                    .name("remote-ipc-write".into())
                    .spawn(move || write_loop(rx, shared))?;
            }
            log::info!("Remote IPC listening at {}", path.display());
            Ok(Self {
                path: path.to_path_buf(),
                shared,
                outgoing: Some(tx),
            })
        }

        /// Queue `frame` for the connected agent; dropped when none is.
        pub fn send(&self, frame: &RemoteFrame) {
            if self.shared.client.lock().is_none() {
                return;
            }
            if let Some(tx) = &self.outgoing {
                let _ = tx.send(pack_for_transport(frame));
            }
        }

        pub fn drain(&self) -> Vec<IpcEvent> {
            self.shared.events.lock().drain(..).collect()
        }

        /// Close the client and the socket, and remove the socket file.
        pub fn stop(&mut self) {
            if self.shared.stop.swap(true, Ordering::SeqCst) {
                return;
            }
            self.outgoing = None;
            if let Some((_, stream)) = self.shared.client.lock().take() {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
            let _ = std::fs::remove_file(&self.path);
        }
    }

    impl Drop for IpcServer {
        fn drop(&mut self) {
            self.stop();
        }
    }

    fn accept_loop(listener: UnixListener, shared: Arc<Shared>) {
        while !shared.stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, _)) => {
                    if let Err(err) = stream.set_nonblocking(false) {
                        log::warn!("Remote IPC: {err}");
                        continue;
                    }
                    let conn = shared.next_conn.fetch_add(1, Ordering::SeqCst);
                    let Ok(reader) = stream.try_clone() else {
                        continue;
                    };
                    // A new client replaces the old one.
                    if let Some((_, old)) = shared.client.lock().replace((conn, stream)) {
                        let _ = old.shutdown(std::net::Shutdown::Both);
                    }
                    shared.push(IpcEvent::Connected);
                    let shared = shared.clone();
                    let _ = std::thread::Builder::new()
                        .name("remote-ipc-read".into())
                        .spawn(move || read_loop(reader, conn, shared));
                }
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(err) => {
                    log::warn!("Remote IPC: failed to accept connection: {err}");
                    std::thread::sleep(Duration::from_millis(200));
                }
            }
        }
    }

    fn read_loop(mut stream: UnixStream, conn: u64, shared: Arc<Shared>) {
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    buffer.extend_from_slice(&chunk[..n]);
                    let result = parse_frames_with_max(&mut buffer, DEFAULT_MAX_FRAME_SIZE);
                    for error in result.errors {
                        log::warn!("Remote IPC frame error: {error}");
                    }
                    if !result.frames.is_empty() {
                        let mut events = shared.events.lock();
                        events.extend(result.frames.into_iter().map(IpcEvent::Frame));
                    }
                }
            }
            if shared.stop.load(Ordering::SeqCst) {
                return;
            }
        }
        if !shared.stop.load(Ordering::SeqCst) {
            shared.disconnect(conn);
        }
    }

    fn write_loop(rx: Receiver<Vec<u8>>, shared: Arc<Shared>) {
        while let Ok(data) = rx.recv() {
            let target = shared
                .client
                .lock()
                .as_ref()
                .and_then(|(conn, stream)| Some((*conn, stream.try_clone().ok()?)));
            let Some((conn, mut stream)) = target else {
                continue;
            };
            if let Err(err) = stream.write_all(&data) {
                log::error!("Remote IPC write failed: {err}");
                shared.disconnect(conn);
            }
        }
    }
}

/// Unix sockets are not available here: the server never starts.
#[cfg(not(unix))]
pub struct IpcServer;

#[cfg(not(unix))]
impl IpcServer {
    pub fn start(_path: &std::path::Path) -> std::io::Result<Self> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "remote control needs Unix sockets",
        ))
    }
    pub fn send(&self, _frame: &RemoteFrame) {}
    pub fn drain(&self) -> Vec<IpcEvent> {
        Vec::new()
    }
    pub fn stop(&mut self) {}
}
