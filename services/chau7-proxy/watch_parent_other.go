//go:build !darwin

package main

func waitForProcessExit(_ int, _ func() bool) bool { return false }
