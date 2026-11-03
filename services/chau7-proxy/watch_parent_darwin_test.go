package main

import (
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestNativeProcessExitWaitsForOwnedProcess(t *testing.T) {
	cmd := exec.Command("/bin/sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	registered := make(chan struct{})
	done := make(chan bool, 1)
	go func() { done <- waitForProcessExit(cmd.Process.Pid, func() bool { close(registered); return true }) }()
	select {
	case <-registered:
	case <-time.After(10 * time.Second):
		t.Fatal("native process watch did not register")
	}
	select {
	case <-done:
		t.Fatal("watch returned while owned process was alive")
	default:
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	select {
	case native := <-done:
		if !native {
			t.Fatal("native exit event unavailable")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("native process watch did not wake on exit")
	}
}

func TestNativeProcessExitChecksOwnershipAfterRegistration(t *testing.T) {
	done := make(chan bool, 1)
	go func() { done <- waitForProcessExit(os.Getpid(), func() bool { return false }) }()
	select {
	case exited := <-done:
		if !exited {
			t.Fatal("ownership loss must exit instead of polling a reused PID")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("ownership loss did not wake watcher")
	}
}

func TestNativeProcessExitRejectsInvalidPIDs(t *testing.T) {
	for _, pid := range []int{-1, 0, 1, 1 << 40} {
		if waitForProcessExit(pid, func() bool { t.Fatal("invalid PID reached ownership check"); return true }) {
			t.Fatalf("invalid PID %d must use the portable fallback", pid)
		}
	}
}
