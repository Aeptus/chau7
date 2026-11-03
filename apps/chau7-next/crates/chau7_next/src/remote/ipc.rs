//! Local IPC server the `chau7-remote` agent connects to
//! (`Remote/RemoteIPCServer.swift`).
//!
//! A Unix socket in the Chau7 Next state folder (`DataRoot::remote_socket`).
//! One client at a time: a new connection replaces the old one. Frames are
//! length-prefixed (`FrameParser`), at most 5 MB; bad frames are skipped and
//! logged. Reading, accepting and writing run on background threads; the app
//! drains [`IpcEvent`]s after an event notification, so a stalled agent never blocks the UI.

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
    use std::os::fd::AsRawFd;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::mpsc::{Receiver, Sender, channel};

    use chau7_next_core::remote::frame::RemoteFrame;
    use chau7_next_core::remote::frame_parser::{
        DEFAULT_MAX_FRAME_SIZE, pack_for_transport, parse_frames_with_max,
    };
    use parking_lot::Mutex;

    use super::IpcEvent;

    struct Shared {
        events: Mutex<VecDeque<IpcEvent>>,
        notify: Option<Arc<dyn Fn() + Send + Sync>>,
        /// The connected client and its connection number.
        client: Mutex<Option<(u64, UnixStream)>>,
        next_conn: AtomicU64,
        stop: AtomicBool,
        #[cfg(test)]
        wait_entries: AtomicU64,
    }

    impl Shared {
        fn push(&self, event: IpcEvent) {
            self.push_all(std::iter::once(event));
        }

        fn push_all(&self, events: impl IntoIterator<Item = IpcEvent>) {
            self.events.lock().extend(events);
            if let Some(notify) = &self.notify {
                notify();
            }
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
        /// Identity of the socket file this server bound, so `stop` never
        /// removes a socket another instance bound at the same path later.
        identity: Option<chau7_next_core::file_identity::FileIdentity>,
        shared: Arc<Shared>,
        outgoing: Option<Sender<Vec<u8>>>,
        shutdown: UnixStream,
        _accept_thread: Option<std::thread::JoinHandle<()>>,
    }

    impl IpcServer {
        /// Bind `path` and start accepting. A stale socket file is removed
        /// first; a socket another running instance still listens on is
        /// refused, as in `platform::local_socket::Listener::bind`.
        pub fn start(
            path: &Path,
            notify: Option<Arc<dyn Fn() + Send + Sync>>,
        ) -> std::io::Result<Self> {
            use std::os::unix::fs::PermissionsExt;
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
                std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
            }
            if UnixStream::connect(path).is_ok() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AddrInUse,
                    format!("{} is in use by another running instance", path.display()),
                ));
            }
            let _ = std::fs::remove_file(path);
            let listener = UnixListener::bind(path)?;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
            let identity = chau7_next_core::file_identity::for_path(path).ok();
            listener.set_nonblocking(true)?;
            let shared = Arc::new(Shared {
                events: Mutex::new(VecDeque::new()),
                notify,
                client: Mutex::new(None),
                next_conn: AtomicU64::new(1),
                stop: AtomicBool::new(false),
                #[cfg(test)]
                wait_entries: AtomicU64::new(0),
            });
            let (shutdown, stopped) = UnixStream::pair()?;
            let (tx, rx) = channel::<Vec<u8>>();
            let accept_thread = {
                let shared = shared.clone();
                std::thread::Builder::new()
                    .name("remote-ipc-accept".into())
                    .spawn(move || accept_loop(listener, stopped, shared))?
            };
            {
                let shared = shared.clone();
                std::thread::Builder::new()
                    .name("remote-ipc-write".into())
                    .spawn(move || write_loop(rx, shared))?;
            }
            log::info!("Remote IPC listening at {}", path.display());
            Ok(Self {
                path: path.to_path_buf(),
                identity,
                shared,
                outgoing: Some(tx),
                shutdown,
                _accept_thread: Some(accept_thread),
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
            // Wakes the blocking accept wait without connecting to a possibly
            // replaced socket path. No periodic shutdown/liveness check is needed.
            let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
            self.outgoing = None;
            if let Some((_, stream)) = self.shared.client.lock().take() {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
            let current = chau7_next_core::file_identity::for_path(&self.path).ok();
            if current.is_some() && current == self.identity {
                let _ = std::fs::remove_file(&self.path);
            }
        }
    }

    impl Drop for IpcServer {
        fn drop(&mut self) {
            self.stop();
        }
    }

    fn accept_loop(listener: UnixListener, stopped: UnixStream, shared: Arc<Shared>) {
        while !shared.stop.load(Ordering::SeqCst) {
            #[cfg(test)]
            shared.wait_entries.fetch_add(1, Ordering::Release);
            let mut descriptors = [
                libc::pollfd {
                    fd: listener.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: stopped.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            // SAFETY: both owned sockets and the two-element descriptor array
            // stay alive for the entire blocking call. No timeout or busy loop.
            let ready = unsafe { libc::poll(descriptors.as_mut_ptr(), descriptors.len() as _, -1) };
            if ready < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                log::warn!("Remote IPC: accept wait failed: {error}");
                break;
            }
            if shared.stop.load(Ordering::SeqCst) || descriptors[1].revents != 0 {
                break;
            }
            if descriptors[0].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                log::warn!("Remote IPC: listener closed");
                break;
            }
            if descriptors[0].revents & libc::POLLIN == 0 {
                continue;
            }
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
                    // Admission and stop serialize on this lock. A connection
                    // accepted concurrently with stop must not outlive shutdown.
                    let mut client = shared.client.lock();
                    if shared.stop.load(Ordering::SeqCst) {
                        break;
                    }
                    if let Some((_, old)) = client.replace((conn, stream)) {
                        let _ = old.shutdown(std::net::Shutdown::Both);
                    }
                    drop(client);
                    shared.push(IpcEvent::Connected);
                    let shared = shared.clone();
                    let _ = std::thread::Builder::new()
                        .name("remote-ipc-read".into())
                        .spawn(move || read_loop(reader, conn, shared));
                }
                Err(err)
                    if matches!(
                        err.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                    ) => {}
                Err(err) => {
                    log::warn!("Remote IPC: failed to accept connection: {err}");
                    // Retain recovery from transient descriptor/resource errors.
                    std::thread::sleep(std::time::Duration::from_millis(200));
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
                        shared.push_all(result.frames.into_iter().map(IpcEvent::Frame));
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
    #[cfg(test)]
    mod idle_regression {
        use super::*;
        use std::time::{Duration, Instant};
        struct Fixture {
            root: PathBuf,
            server: IpcServer,
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                self.server.stop();
                let _ = std::fs::remove_dir_all(&self.root);
            }
        }
        #[test]
        fn queued_events_notify_without_a_ui_poll() {
            let root =
                PathBuf::from("/tmp").join(format!("c7-notify-{}", uuid::Uuid::new_v4().simple()));
            let (wake, wakes) = std::sync::mpsc::sync_channel(1);
            let notify = Arc::new(move || {
                let _ = wake.try_send(());
            });
            let server = IpcServer::start(&root.join("fixture.sock"), Some(notify)).unwrap();
            let fixture = Fixture { root, server };
            let mut stream = UnixStream::connect(fixture.root.join("fixture.sock")).unwrap();
            wakes.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(fixture.server.drain(), vec![IpcEvent::Connected]);
            let frame = RemoteFrame {
                version: 1,
                type_: 2,
                flags: 0,
                reserved: 0,
                tab_id: 3,
                seq: 4,
                payload: b"notified".to_vec(),
            };
            stream.write_all(&pack_for_transport(&frame)).unwrap();
            wakes.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(fixture.server.drain(), vec![IpcEvent::Frame(frame)]);
            drop(stream);
            wakes.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(fixture.server.drain(), vec![IpcEvent::Disconnected]);
        }
        #[test]
        fn idle_listener_wait_is_not_periodic() {
            let root =
                PathBuf::from("/tmp").join(format!("c7-idle-{}", uuid::Uuid::new_v4().simple()));
            let server = IpcServer::start(&root.join("fixture.sock"), None).unwrap();
            let fixture = Fixture { root, server };
            let started = Instant::now();
            while fixture.server.shared.wait_entries.load(Ordering::Acquire) == 0 {
                assert!(started.elapsed() < Duration::from_secs(1));
                std::thread::sleep(Duration::from_millis(2));
            }
            std::thread::sleep(Duration::from_millis(180));
            assert_eq!(
                fixture.server.shared.wait_entries.load(Ordering::Acquire),
                1,
                "an idle listener must stay in its initial blocking wait"
            );
        }
    }
    #[cfg(all(test, unix))]
    mod tests {
        use super::*;
        use chau7_next_core::remote::frame_parser::pack_for_transport;
        use std::io::{Read, Write};
        use std::os::unix::net::{UnixListener, UnixStream};
        use std::path::PathBuf;
        use std::time::{Duration, Instant};

        struct Fixture {
            root: PathBuf,
            server: IpcServer,
        }
        impl Fixture {
            fn new() -> Self {
                let root =
                    PathBuf::from("/tmp").join(format!("c7-ipc-{}", uuid::Uuid::new_v4().simple()));
                let server = IpcServer::start(&root.join("fixture.sock"), None).unwrap();
                Self { root, server }
            }
            fn connect(&self) -> UnixStream {
                let stream = UnixStream::connect(self.root.join("fixture.sock")).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(1)))
                    .unwrap();
                stream
            }
            fn event(&self) -> Vec<IpcEvent> {
                let start = Instant::now();
                loop {
                    let events = self.server.drain();
                    if !events.is_empty() {
                        return events;
                    }
                    assert!(
                        start.elapsed() < Duration::from_secs(1),
                        "IPC event not delivered"
                    );
                    std::thread::sleep(Duration::from_millis(2));
                }
            }
            fn stopped(&mut self) {
                self.server.stop();
                let start = Instant::now();
                while !self.server._accept_thread.as_ref().unwrap().is_finished() {
                    assert!(
                        start.elapsed() < Duration::from_secs(1),
                        "blocking accept did not stop"
                    );
                    std::thread::sleep(Duration::from_millis(2));
                }
                self.server._accept_thread.take().unwrap().join().unwrap();
            }
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                self.server.stop();
                let _ = std::fs::remove_dir_all(&self.root);
            }
        }
        fn frame() -> RemoteFrame {
            RemoteFrame {
                version: 1,
                type_: 2,
                flags: 0,
                reserved: 0,
                tab_id: 3,
                seq: 4,
                payload: b"fixture".to_vec(),
            }
        }

        #[test]
        fn idle_listener_stops_promptly_and_stop_is_idempotent() {
            let mut fixture = Fixture::new();
            fixture.stopped();
            fixture.server.stop();
            assert!(!fixture.root.join("fixture.sock").exists());
        }

        #[test]
        fn partial_frames_and_bidirectional_delivery_survive_blocking_accept() {
            let mut fixture = Fixture::new();
            let mut client = fixture.connect();
            assert_eq!(fixture.event(), vec![IpcEvent::Connected]);
            let frame = frame();
            let bytes = pack_for_transport(&frame);
            client.write_all(&bytes[..3]).unwrap();
            client.write_all(&bytes[3..]).unwrap();
            assert_eq!(fixture.event(), vec![IpcEvent::Frame(frame.clone())]);
            fixture.server.send(&frame);
            let mut reply = vec![0; bytes.len()];
            client.read_exact(&mut reply).unwrap();
            assert_eq!(reply, bytes);
            drop(client);
            assert_eq!(fixture.event(), vec![IpcEvent::Disconnected]);
            fixture.stopped();
        }

        #[test]
        fn replacement_client_stays_connected_when_old_reader_exits() {
            let mut fixture = Fixture::new();
            let mut old = fixture.connect();
            assert_eq!(fixture.event(), vec![IpcEvent::Connected]);
            let mut current = fixture.connect();
            assert_eq!(fixture.event(), vec![IpcEvent::Connected]);
            assert_eq!(old.read(&mut [0]).unwrap(), 0);
            drop(old);
            let bytes = pack_for_transport(&frame());
            fixture.server.send(&frame());
            let mut reply = vec![0; bytes.len()];
            current.read_exact(&mut reply).unwrap();
            assert_eq!(reply, bytes);
            fixture.stopped();
            assert_eq!(current.read(&mut [0]).unwrap(), 0);
        }

        #[test]
        fn stop_does_not_touch_a_replacement_socket_at_the_same_path() {
            let mut fixture = Fixture::new();
            let path = fixture.root.join("fixture.sock");
            std::fs::rename(&path, fixture.root.join("old.sock")).unwrap();
            let replacement = UnixListener::bind(&path).unwrap();
            fixture.stopped();
            assert!(path.exists());
            let _client = UnixStream::connect(&path).unwrap();
            replacement.accept().unwrap();
        }
    }
}

/// Unix sockets are not available here: the server never starts.
#[cfg(not(unix))]
pub struct IpcServer;

#[cfg(not(unix))]
impl IpcServer {
    pub fn start(
        _path: &std::path::Path,
        _notify: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
    ) -> std::io::Result<Self> {
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
