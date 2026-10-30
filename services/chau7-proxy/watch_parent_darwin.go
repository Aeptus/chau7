package main

import "golang.org/x/sys/unix"

// waitForProcessExit waits without polling. False requests the portable fallback.
func waitForProcessExit(pid int, stillOwned func() bool) bool {
	if pid <= 1 || pid > 1<<31-1 {
		return false
	}
	ident := uint64(pid)
	fd, err := unix.Kqueue()
	if err != nil {
		return false
	}
	unix.CloseOnExec(fd)
	defer func() { _ = unix.Close(fd) }()
	change := unix.Kevent_t{
		Ident: ident, Filter: unix.EVFILT_PROC,
		Flags:  unix.EV_ADD | unix.EV_ENABLE | unix.EV_ONESHOT,
		Fflags: unix.NOTE_EXIT,
	}
	if _, err = unix.Kevent(fd, []unix.Kevent_t{change}, nil, nil); err != nil {
		return err == unix.ESRCH
	}
	// Close the exit/PID-reuse race between the caller's parent check and
	// registering the event. Only a process that remains our parent is owned.
	if !stillOwned() {
		return true
	}
	var events [1]unix.Kevent_t
	for {
		n, err := unix.Kevent(fd, nil, events[:], nil)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return false
		}
		if n > 0 {
			event := events[0]
			if event.Flags&unix.EV_ERROR != 0 {
				return false
			}
			if event.Filter == unix.EVFILT_PROC && event.Ident == ident && event.Fflags&unix.NOTE_EXIT != 0 {
				return true
			}
		}
	}
}
