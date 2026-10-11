//! The proxy's IPC socket (`ProxyIPCServer.swift`, PRX-009): the proxy
//! connects and writes one JSON object per line. Lines are decoded on a
//! reader thread and handed to the main thread through a channel.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};

use chau7_next_core::proxy::{LineBuffer, ProxyMessage, parse_message};

use crate::platform::local_socket::{self, Listener};

pub struct IpcServer {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    pub messages: Receiver<ProxyMessage>,
}

impl IpcServer {
    /// Listen on `path` (a stale socket file is removed first).
    pub fn start(path: &Path) -> Result<Self, String> {
        let listener = Listener::bind(path).map_err(|e| e.to_string())?;
        let (tx, rx) = channel();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::Builder::new()
            .name("proxy-ipc".into())
            .spawn(move || accept_loop(listener, tx, flag))
            .map_err(|e| e.to_string())?;
        log::info!("IPC server listening at {}", path.display());
        Ok(Self {
            path: path.to_path_buf(),
            stop,
            messages: rx,
        })
    }

    /// Stop accepting and remove the socket file.
    pub fn stop(&self) {
        log::info!("Stopping IPC server");
        self.stop.store(true, Ordering::Release);
        // Wake the blocking accept.
        #[cfg(unix)]
        let _ = std::os::unix::net::UnixStream::connect(&self.path);
        local_socket::remove(&self.path);
    }
}

impl Drop for IpcServer {
    fn drop(&mut self) {
        if !self.stop.load(Ordering::Acquire) {
            self.stop();
        }
    }
}

fn accept_loop(listener: Listener, tx: Sender<ProxyMessage>, stop: Arc<AtomicBool>) {
    loop {
        let conn = listener.accept();
        if stop.load(Ordering::Acquire) {
            return;
        }
        match conn {
            Ok(mut conn) => {
                log::debug!("Accepted IPC connection");
                let tx = tx.clone();
                let stop = stop.clone();
                let _ = std::thread::Builder::new()
                    .name("proxy-ipc-client".into())
                    .spawn(move || {
                        let mut lines = LineBuffer::default();
                        let mut buf = [0u8; 4096];
                        while !stop.load(Ordering::Acquire) {
                            match conn.read(&mut buf) {
                                Ok(0) => break,
                                Ok(n) => {
                                    for line in lines.push(&buf[..n]) {
                                        match parse_message(&line, chrono::Utc::now()) {
                                            Ok(message) => {
                                                if tx.send(message).is_err() {
                                                    return;
                                                }
                                            }
                                            Err(err) => {
                                                log::warn!("Failed to decode IPC message: {err}");
                                                log::debug!("Raw message: {line}");
                                            }
                                        }
                                    }
                                }
                                Err(err) => {
                                    log::warn!("Read error: {err}");
                                    break;
                                }
                            }
                        }
                    });
            }
            Err(err) => {
                log::warn!("Failed to accept connection: {err}");
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        }
    }
}
