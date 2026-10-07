package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/chau7/chau7-remote/internal/agent"
)

func TestManagementCommandsUseOwnerOnlyFilesAndNeverPrintSecrets(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "root.json")
	next := filepath.Join(dir, "next.json")
	bundle := filepath.Join(dir, "bundle.json")
	var output bytes.Buffer
	commands := [][]string{
		{"keyring-init", "--key-id", "initial", "--output", root},
		{"credentials-derive", "--keyring", root, "--device-id", "device-a", "--output", bundle},
		{"keyring-rotate", "--keyring", root, "--output", next, "--overlap", "1h"},
	}
	for _, args := range commands {
		if err := runManagementCommand(args, &output); err != nil {
			t.Fatal(err)
		}
	}
	ring, err := agent.LoadRelayKeyring(root, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	credentials, err := agent.LoadRelayCredentials(bundle, "device-a")
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{ring.Current.Secret, credentials.MacSecret, credentials.IOSSecret} {
		if strings.Contains(output.String(), secret) {
			t.Fatal("management output leaked a secret")
		}
	}
	for _, path := range []string{root, next, bundle} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatal("secret output is not owner-only")
		}
	}
	if err := runManagementCommand(commands[0], &output); err == nil {
		t.Fatal("command overwrote an existing root")
	}
	if err := runManagementCommand([]string{"keyring-rotate", "--keyring", root, "--output", filepath.Join(dir, "bad.json"), "--overlap", "25h"}, &output); err == nil {
		t.Fatal("unbounded rotation accepted")
	}
	if err := runManagementCommand([]string{"unknown"}, &output); err == nil {
		t.Fatal("unknown command accepted")
	}
}
