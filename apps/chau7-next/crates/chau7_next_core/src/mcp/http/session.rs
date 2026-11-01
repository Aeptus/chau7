//! An HTTP session owns one existing app socket session, without a subprocess.
//! Socket reads, response routing and SSE waits share the HTTP runtime thread.

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use hyper::body::Bytes;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::OwnedWriteHalf;
use tokio::sync::{Notify, OwnedSemaphorePermit, mpsc, oneshot};

pub(super) const MAX_FRAME: usize = 8 * 1024 * 1024;
const MAX_NOTIFICATIONS: usize = 64;
const MAX_QUEUED_BYTES: usize = 256 * 1024;
type Replies = HashMap<String, oneshot::Sender<io::Result<Value>>>;

pub(super) struct Session {
    pub id: String,
    pub protocol: String,
    pub closed: AtomicBool,
    pub last_activity: Mutex<Instant>,
    writer: tokio::sync::Mutex<OwnedWriteHalf>,
    pending: Mutex<Replies>,
    notifications: mpsc::Sender<Bytes>,
    receiver: tokio::sync::Mutex<mpsc::Receiver<Bytes>>,
    queued_bytes: AtomicUsize,
    stream_epoch: AtomicU64,
    closed_notify: Notify,
    stream_changed: Notify,
    _capacity: OwnedSemaphorePermit,
}

impl Session {
    pub fn new(stream: UnixStream, protocol: String, capacity: OwnedSemaphorePermit) -> Arc<Self> {
        let (reader, writer) = stream.into_split();
        let (notifications, receiver) = mpsc::channel(MAX_NOTIFICATIONS);
        let session = Arc::new(Self {
            id: uuid::Uuid::new_v4().to_string(),
            protocol,
            closed: AtomicBool::new(false),
            last_activity: Mutex::new(Instant::now()),
            writer: tokio::sync::Mutex::new(writer),
            pending: Mutex::new(HashMap::new()),
            notifications,
            receiver: tokio::sync::Mutex::new(receiver),
            queued_bytes: AtomicUsize::new(0),
            stream_epoch: AtomicU64::new(0),
            closed_notify: Notify::new(),
            stream_changed: Notify::new(),
            _capacity: capacity,
        });
        let active = session.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(reader);
            loop {
                let mut bytes = Vec::new();
                let read = tokio::select! {
                    _ = active.wait_closed() => break,
                    read = read_frame(&mut reader, &mut bytes) => read,
                };
                if active.closed.load(Ordering::Acquire) || !matches!(read, Ok(true)) {
                    break;
                }
                let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
                    break;
                };
                active.touch();
                if let Some(id) = value.get("id").filter(|_| value.get("method").is_none()) {
                    let reply = active
                        .pending
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .remove(&id.to_string());
                    if let Some(reply) = reply {
                        let _ = reply.send(Ok(value));
                    }
                } else {
                    let frame = Bytes::from(format!("event: message\ndata: {value}\n\n"));
                    let size = frame.len();
                    if active
                        .queued_bytes
                        .try_update(Ordering::AcqRel, Ordering::Acquire, |old| {
                            old.checked_add(size).filter(|sum| *sum <= MAX_QUEUED_BYTES)
                        })
                        .is_err()
                    {
                        break;
                    }
                    if active.notifications.try_send(frame).is_err() {
                        active.queued_bytes.fetch_sub(size, Ordering::AcqRel);
                        break;
                    }
                }
            }
            active.close();
        });
        session
    }

    pub fn touch(&self) {
        *self.last_activity.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
    }

    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.closed_notify.notify_waiters();
        self.stream_changed.notify_waiters();
        let pending = std::mem::take(&mut *self.pending.lock().unwrap_or_else(|e| e.into_inner()));
        for reply in pending.into_values() {
            let _ = reply.send(Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "MCP HTTP session closed",
            )));
        }
    }

    pub async fn wait_closed(&self) {
        loop {
            let changed = self.closed_notify.notified();
            if self.closed.load(Ordering::Acquire) {
                return;
            }
            changed.await;
        }
    }

    /// Per-request guards remove pending IDs on cancellation without cancelling
    /// the underlying tool, which may already be waiting for local approval.
    pub async fn send(self: &Arc<Self>, value: &Value) -> io::Result<Option<Value>> {
        if self.closed.load(Ordering::Acquire) {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "MCP HTTP session closed",
            ));
        }
        self.touch();
        let is_reply = value.get("method").is_none();
        let id = (!is_reply)
            .then(|| value.get("id"))
            .flatten()
            .map(Value::to_string);
        let (receiver, _guard) = if let Some(id) = id {
            let (sender, receiver) = oneshot::channel();
            let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
            if pending.contains_key(&id) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "duplicate in-flight request ID",
                ));
            }
            pending.insert(id.clone(), sender);
            (
                Some(receiver),
                Some(Pending {
                    session: self.clone(),
                    id,
                }),
            )
        } else {
            (None, None)
        };
        let mut bytes = serde_json::to_vec(value)?;
        bytes.push(b'\n');
        if self.writer.lock().await.write_all(&bytes).await.is_err() {
            self.close();
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "MCP socket write failed",
            ));
        }
        match receiver {
            Some(receiver) => receiver
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "MCP reply closed"))?
                .map(Some),
            None => Ok(None),
        }
    }

    pub fn open_stream(&self) -> u64 {
        let epoch = self.stream_epoch.fetch_add(1, Ordering::AcqRel) + 1;
        self.stream_changed.notify_waiters();
        epoch
    }

    pub async fn next_notification(&self, epoch: u64) -> Option<Bytes> {
        loop {
            let changed = self.stream_changed.notified();
            if self.closed.load(Ordering::Acquire)
                || self.stream_epoch.load(Ordering::Acquire) != epoch
            {
                return None;
            }
            tokio::select! {
                biased;
                _ = changed => continue,
                next = async { self.receiver.lock().await.recv().await } => {
                    let frame = next?;
                    self.queued_bytes.fetch_sub(frame.len(), Ordering::AcqRel);
                    return Some(frame);
                }
            }
        }
    }

    pub async fn expire_after(self: Arc<Self>, idle: Duration) {
        loop {
            let deadline = *self.last_activity.lock().unwrap_or_else(|e| e.into_inner()) + idle;
            tokio::select! {
                _ = self.wait_closed() => return,
                _ = tokio::time::sleep_until(deadline.into()) => {}
            }
            if !self
                .pending
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .is_empty()
            {
                self.touch();
                continue;
            }
            if self
                .last_activity
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .elapsed()
                >= idle
            {
                self.close();
                return;
            }
        }
    }
}

struct Pending {
    session: Arc<Session>,
    id: String,
}
impl Drop for Pending {
    fn drop(&mut self) {
        self.session
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.id);
    }
}

async fn read_frame(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    bytes: &mut Vec<u8>,
) -> io::Result<bool> {
    use tokio::io::AsyncReadExt;
    let count = reader
        .take((MAX_FRAME + 1) as u64)
        .read_until(b'\n', bytes)
        .await?;
    if bytes.len() > MAX_FRAME {
        return Err(io::Error::other("MCP response exceeds frame limit"));
    }
    Ok(count > 0)
}
