//! Bounded subprocess capture corresponding to `SubprocessRunner.swift`.
use std::io::{self, Read};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Complete output is distinguished from a timed-out, failed or truncated capture.
#[derive(Debug, Default)]
pub struct CaptureResult {
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub timed_out: bool,
    pub output_limit_exceeded: bool,
    pub read_failed: bool,
    pub cancelled: bool,
}
impl CaptureResult {
    pub fn completed(&self) -> bool {
        self.status.is_some()
            && !self.timed_out
            && !self.output_limit_exceeded
            && !self.read_failed
            && !self.cancelled
    }
}

/// Bound elapsed time and combined stdout/stderr bytes, including pipes held
/// by descendants after the immediate child exits. Only the owned child is
/// terminated; terminal process groups and unrelated children are untouched.
pub fn capture(
    command: &mut Command,
    timeout: Duration,
    maximum_bytes: usize,
) -> io::Result<CaptureResult> {
    capture_unless(command, timeout, maximum_bytes, || false)
}
pub fn capture_unless(
    command: &mut Command,
    timeout: Duration,
    maximum_bytes: usize,
    cancelled: impl Fn() -> bool,
) -> io::Result<CaptureResult> {
    let Some(deadline) = Instant::now().checked_add(timeout) else {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    };
    if timeout.is_zero() || maximum_bytes == 0 {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    if let Err(error) = make_nonblocking(&stdout).and_then(|()| make_nonblocking(&stderr)) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    let mut result = CaptureResult::default();
    let (mut out_eof, mut err_eof) = (false, false);
    loop {
        result.cancelled = cancelled();
        result.timed_out = Instant::now() >= deadline;
        if result.cancelled || result.timed_out {
            break;
        }
        match child.try_wait() {
            Ok(Some(status)) => result.status = Some(status.code().unwrap_or(-1)),
            Ok(None) => {}
            Err(_) => {
                result.read_failed = true;
                break;
            }
        }
        let before = result.stdout.len() + result.stderr.len();
        let mut remaining = maximum_bytes.saturating_sub(before);
        match drain(&mut stdout, &mut result.stdout, &mut remaining) {
            Ok(eof) => out_eof |= eof,
            Err(error) if error.kind() == io::ErrorKind::OutOfMemory => {
                result.output_limit_exceeded = true
            }
            Err(_) => result.read_failed = true,
        }
        match drain(&mut stderr, &mut result.stderr, &mut remaining) {
            Ok(eof) => err_eof |= eof,
            Err(error) if error.kind() == io::ErrorKind::OutOfMemory => {
                result.output_limit_exceeded = true
            }
            Err(_) => result.read_failed = true,
        }
        if result.output_limit_exceeded
            || result.read_failed
            || (result.status.is_some() && out_eof && err_eof)
        {
            break;
        }
        if before == result.stdout.len() + result.stderr.len() {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    // Closing our pipe handles also bounds the lifetime when descendants retain
    // inherited descriptors. Never join a blocking reader thread.
    drop(stdout);
    drop(stderr);
    if result.status.is_none() {
        let _ = child.kill();
        let reap_deadline = Instant::now() + Duration::from_millis(200);
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                result.status = Some(status.code().unwrap_or(-1));
                break;
            }
            if Instant::now() >= reap_deadline {
                // A stuck OS process must not defeat the capture deadline.
                // This reaper owns no pipe handles and cannot publish output.
                let _ = std::thread::Builder::new()
                    .name("chau7-next-command-reaper".into())
                    .spawn(move || {
                        let _ = child.wait();
                    });
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    Ok(result)
}

#[cfg(unix)]
fn make_nonblocking(pipe: &impl std::os::fd::AsRawFd) -> io::Result<()> {
    let fd = pipe.as_raw_fd();
    // SAFETY: the owned pipe remains open throughout this operation.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
#[cfg(windows)]
fn make_nonblocking(_: &impl std::os::windows::io::AsRawHandle) -> io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn available(_: &impl std::os::fd::AsRawFd) -> io::Result<Option<usize>> {
    Ok(Some(8192))
}
#[cfg(windows)]
fn available(pipe: &impl std::os::windows::io::AsRawHandle) -> io::Result<Option<usize>> {
    use std::ffi::c_void;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        #[link_name = "PeekNamedPipe"]
        fn peek_pipe(
            handle: *mut c_void,
            buffer: *mut c_void,
            size: u32,
            read: *mut u32,
            available: *mut u32,
            left: *mut u32,
        ) -> i32;
    }
    let mut bytes = 0;
    // SAFETY: the pipe is live, no read buffer is passed, and bytes is writable.
    if unsafe {
        peek_pipe(
            pipe.as_raw_handle(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            &mut bytes,
            std::ptr::null_mut(),
        )
    } == 0
    {
        let error = io::Error::last_os_error();
        return if error.raw_os_error() == Some(109) {
            Ok(None)
        } else {
            Err(error)
        };
    }
    Ok(Some(bytes as usize))
}

#[cfg(unix)]
trait Pipe: Read + std::os::fd::AsRawFd {}
#[cfg(unix)]
impl<T: Read + std::os::fd::AsRawFd> Pipe for T {}
#[cfg(windows)]
trait Pipe: Read + std::os::windows::io::AsRawHandle {}
#[cfg(windows)]
impl<T: Read + std::os::windows::io::AsRawHandle> Pipe for T {}
fn drain(pipe: &mut impl Pipe, output: &mut Vec<u8>, remaining: &mut usize) -> io::Result<bool> {
    // A noisy child cannot starve the deadline or the other pipe.
    for _ in 0..16 {
        let Some(ready) = available(pipe)? else {
            return Ok(true);
        };
        if ready == 0 {
            return Ok(false);
        }
        let mut buffer = [0u8; 8192];
        let limit = ready.min(buffer.len()).min(remaining.saturating_add(1));
        match pipe.read(&mut buffer[..limit]) {
            Ok(0) => return Ok(true),
            Ok(count) => {
                let retain = count.min(*remaining);
                output.extend_from_slice(&buffer[..retain]);
                *remaining -= retain;
                if count > retain {
                    return Err(io::Error::from(io::ErrorKind::OutOfMemory));
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    Ok(false)
}

/// Convenience capture for callers that only accept successful complete output.
pub fn run(executable_path: &str, arguments: &[&str]) -> Option<String> {
    let result = capture(
        Command::new(executable_path).args(arguments),
        Duration::from_secs(5),
        4 * 1024 * 1024,
    )
    .ok()?;
    (result.completed() && result.status == Some(0))
        .then(|| String::from_utf8_lossy(&result.stdout).into_owned())
}

/// Drain a helper's stdout or stderr to EOF, one lossily decoded line at a
/// time (without the line ending). Invalid UTF-8 never stops the drain: a
/// reader that quit early would leave the pipe full and block the child.
pub fn for_each_output_line(stream: impl Read, mut on_line: impl FnMut(&str)) {
    use std::io::BufRead;
    let mut reader = io::BufReader::new(stream);
    let mut raw = Vec::new();
    loop {
        raw.clear();
        match reader.read_until(b'\n', &mut raw) {
            Ok(0) => return,
            Ok(_) => {
                let line = String::from_utf8_lossy(&raw);
                on_line(line.trim_end_matches(['\n', '\r']));
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return,
        }
    }
}

#[cfg(test)]
mod output_line_tests {
    use super::for_each_output_line;

    #[test]
    fn invalid_utf8_does_not_stop_the_drain() {
        let input: &[u8] = b"first\r\nbad \xff byte\nlast";
        let mut lines = Vec::new();
        for_each_output_line(input, |line| lines.push(line.to_string()));
        assert_eq!(lines, ["first", "bad \u{fffd} byte", "last"]);
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    fn shell(script: &str, millis: u64, limit: usize) -> CaptureResult {
        capture(
            Command::new("/bin/sh").args(["-c", script]),
            Duration::from_millis(millis),
            limit,
        )
        .unwrap()
    }
    #[test]
    fn run_captures_stdout() {
        assert_eq!(run("/bin/echo", &["chau7"]).as_deref(), Some("chau7\n"));
    }
    #[test]
    fn run_returns_none_for_missing_executable() {
        assert_eq!(run("/path/that/does/not/exist", &[]), None);
    }
    #[test]
    fn captures_both_streams_and_nonzero_status() {
        let result = shell("printf out; printf err >&2; exit 7", 2000, 1024);
        assert!(result.completed());
        assert_eq!(result.status, Some(7));
        assert_eq!(result.stdout, b"out");
        assert_eq!(result.stderr, b"err");
        assert_eq!(run("/bin/sh", &["-c", "printf partial; exit 7"]), None);
    }
    #[test]
    fn combined_limit_is_not_parseable() {
        let result = shell("printf 123456; printf abcdef >&2", 2000, 10);
        assert!(result.output_limit_exceeded);
        assert!(!result.completed());
        assert_eq!(result.stdout.len() + result.stderr.len(), 10);
    }
    #[test]
    fn timeout_covers_descendant_held_pipes() {
        let start = Instant::now();
        let result = shell("sleep 1 & printf child-exited", 100, 1024);
        assert!(result.timed_out);
        assert!(!result.completed());
        assert!(start.elapsed() < Duration::from_millis(800));
    }
    #[test]
    fn cancellation_and_continuous_output_are_bounded() {
        let start = Instant::now();
        let result = capture_unless(
            Command::new("/bin/sh").args(["-c", "while :; do printf flood; done"]),
            Duration::from_secs(2),
            1024,
            || start.elapsed() > Duration::from_millis(20),
        )
        .unwrap();
        assert!(!result.completed());
        assert!(result.cancelled || result.output_limit_exceeded);
        assert!(start.elapsed() < Duration::from_secs(1));
    }
}
