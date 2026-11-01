//! Client teardown uses blocking OS events, with no periodic idle wakeups.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

#[cfg(target_os = "macos")]
pub fn wait_for_client_exit() -> io::Result<()> {
    // SAFETY: getppid and kqueue take no pointers.
    let parent = unsafe { libc::getppid() };
    if parent == 1 {
        return Ok(());
    }
    let raw = unsafe { libc::kqueue() };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: kqueue returned a new descriptor owned by this watcher.
    let queue = unsafe { OwnedFd::from_raw_fd(raw) };
    let changes = [
        libc::kevent {
            ident: parent as libc::uintptr_t,
            filter: libc::EVFILT_PROC,
            flags: libc::EV_ADD | libc::EV_ONESHOT,
            fflags: libc::NOTE_EXIT,
            data: 0,
            udata: std::ptr::null_mut(),
        },
        libc::kevent {
            ident: libc::STDOUT_FILENO as libc::uintptr_t,
            filter: libc::EVFILT_WRITE,
            flags: libc::EV_ADD | libc::EV_CLEAR,
            fflags: 0,
            data: 0,
            udata: std::ptr::null_mut(),
        },
    ];
    // SAFETY: changes is a valid array; no output events or timeout requested.
    let installed = unsafe {
        libc::kevent(
            queue.as_raw_fd(),
            changes.as_ptr(),
            2,
            std::ptr::null_mut(),
            0,
            std::ptr::null(),
        )
    };
    if installed < 0 {
        let error = io::Error::last_os_error();
        // The parent may exit between getppid and registration.
        return if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(())
        } else {
            Err(error)
        };
    }
    loop {
        // SAFETY: kevent is plain C data, zero is a valid initial value.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: event points to one writable record; null timeout blocks.
        let ready = unsafe {
            libc::kevent(
                queue.as_raw_fd(),
                std::ptr::null(),
                0,
                &mut event,
                1,
                std::ptr::null(),
            )
        };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if event.flags & libc::EV_ERROR != 0 {
            return Err(io::Error::from_raw_os_error(event.data as i32));
        }
        if event.filter == libc::EVFILT_PROC || event.flags & libc::EV_EOF != 0 {
            return Ok(());
        }
        // EV_CLEAR consumes initial writability. Subsequent waits block until
        // pipe state changes; there is no clock-driven liveness check.
    }
}

#[cfg(not(target_os = "macos"))]
pub fn wait_for_client_exit() -> io::Result<()> {
    // SAFETY: getppid has no preconditions.
    let parent = unsafe { libc::getppid() };
    if parent == 1 {
        return Ok(());
    }
    #[cfg(target_os = "linux")]
    let parent_fd = {
        // SAFETY: pidfd_open takes a PID and zero flags, returning an owned fd.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, parent, 0) };
        if raw < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return Ok(());
            }
            // Old kernels still signal a closed client response pipe.
            None
        } else {
            Some(unsafe { OwnedFd::from_raw_fd(raw as i32) })
        }
    };
    let mut descriptors = vec![libc::pollfd {
        fd: libc::STDOUT_FILENO,
        events: 0,
        revents: 0,
    }];
    #[cfg(target_os = "linux")]
    if let Some(fd) = &parent_fd {
        descriptors.push(libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
    }
    loop {
        // SAFETY: descriptors owns the specified pollfd array; -1 blocks.
        let ready = unsafe { libc::poll(descriptors.as_mut_ptr(), descriptors.len() as _, -1) };
        if ready >= 0 && descriptors.iter().any(|fd| fd.revents != 0) {
            return Ok(());
        }
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}
