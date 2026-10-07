package agent

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixtureUUID() (string, error) { return "test-machine-identity", nil }

func TestStateWrappedRoundTripPreservesIdentityAndInput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "remote", "state.json")
	original := &State{DeviceID: "device", MacPrivateKey: base64.StdEncoding.EncodeToString([]byte("private-key")), MacPublicKey: "public-key", PairedDevices: []PairedDevice{{ID: "phone", IOSPublicKey: "phone-key"}}}
	if err := saveState(path, original, fixtureUUID); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path) // #nosec G304 -- path is owned by t.TempDir(), never external input
	if err != nil {
		t.Fatal(err)
	}
	var stored State
	if err := json.Unmarshal(data, &stored); err != nil {
		t.Fatal(err)
	}
	if !stored.KeyEncrypted || stored.MacPrivateKey == original.MacPrivateKey {
		t.Fatal("private key was not wrapped")
	}
	if original.KeyEncrypted {
		t.Fatal("save mutated caller state")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("unsafe mode: %v", info.Mode())
	}
	loaded, err := loadState(path, fixtureUUID)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.DeviceID != original.DeviceID || loaded.MacPrivateKey != original.MacPrivateKey || loaded.MacPublicKey != original.MacPublicKey || loaded.KeyEncrypted || len(loaded.PairedDevices) != 1 {
		t.Fatalf("identity changed: %#v", loaded)
	}
}

func TestStateUnwrapFailuresNeverEraseOrReplaceIdentity(t *testing.T) {
	for _, mode := range []string{"wrong-machine", "unavailable-machine", "empty-machine", "tampered", "missing-wrapped-key"} {
		t.Run(mode, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "state.json")
			if err := saveState(path, &State{DeviceID: "keep-device", MacPrivateKey: "keep-private", MacPublicKey: "keep-public"}, fixtureUUID); err != nil {
				t.Fatal(err)
			}
			lookup := func() (string, error) { return "wrong-machine", nil }
			if mode == "empty-machine" {
				lookup = func() (string, error) { return "", nil }
			}
			if mode == "unavailable-machine" {
				lookup = func() (string, error) { return "", errors.New("identity service unavailable") }
			}
			if mode == "tampered" || mode == "missing-wrapped-key" {
				data, _ := os.ReadFile(path) // #nosec G304 -- path is owned by t.TempDir(), never external input
				var stored State
				if err := json.Unmarshal(data, &stored); err != nil {
					t.Fatal(err)
				}
				stored.MacPrivateKey = "invalid-ciphertext"
				if mode == "missing-wrapped-key" {
					stored.MacPrivateKey = ""
				}
				data, _ = json.Marshal(stored)
				if err := os.WriteFile(path, data, 0600); err != nil {
					t.Fatal(err)
				}
				lookup = fixtureUUID
			}
			before, err := os.ReadFile(path) // #nosec G304 -- path is owned by t.TempDir(), never external input
			if err != nil {
				t.Fatal(err)
			}
			state, err := loadState(path, lookup)
			if err == nil || state != nil {
				t.Fatalf("must reject undecryptable identity, got state=%#v err=%v", state, err)
			}
			if !strings.Contains(err.Error(), "state") {
				t.Fatalf("error must explain recovery context: %v", err)
			}
			after, _ := os.ReadFile(path) // #nosec G304 -- path is owned by t.TempDir(), never external input
			if !bytes.Equal(before, after) {
				t.Fatal("failed load changed persisted identity")
			}
		})
	}
}

func TestStateSaveFailsClosedWithoutMachineIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	before := []byte("preserved existing file")
	if err := os.WriteFile(path, before, 0600); err != nil {
		t.Fatal(err)
	}
	state := &State{DeviceID: "device", MacPrivateKey: "private"}
	err := saveState(path, state, func() (string, error) { return "", errors.New("unavailable") })
	if err == nil {
		t.Fatal("must not fall back to plaintext key storage")
	}
	after, _ := os.ReadFile(path) // #nosec G304 -- path is owned by t.TempDir(), never external input
	if !bytes.Equal(before, after) {
		t.Fatal("failed save overwrote existing state")
	}
	if state.KeyEncrypted || state.MacPrivateKey != "private" {
		t.Fatal("failed save mutated caller")
	}
}

func TestStateLoadMissingMalformedAndLegacy(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	missing, err := loadState(path, fixtureUUID)
	if err != nil || missing.DeviceID != "" {
		t.Fatalf("missing state: %#v %v", missing, err)
	}
	if err := os.WriteFile(path, []byte("not json"), 0600); err != nil {
		t.Fatal(err)
	}
	if state, err := loadState(path, fixtureUUID); err == nil || state != nil {
		t.Fatal("malformed state accepted")
	}
	legacy := State{DeviceID: "legacy", MacPrivateKey: "plain-legacy-key", IOSPublicKey: base64.StdEncoding.EncodeToString([]byte("phone")), IOSName: "Phone"}
	data, _ := json.Marshal(legacy)
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadState(path, func() (string, error) { t.Fatal("plaintext legacy read needs no UUID"); return "", nil })
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.PairedDevices) != 1 || loaded.PairedDevices[0].Name != "Phone" || loaded.MacPrivateKey != legacy.MacPrivateKey {
		t.Fatal("legacy migration failed")
	}
	if err := saveState(path, loaded, fixtureUUID); err != nil {
		t.Fatal(err)
	}
	stored, _ := os.ReadFile(path) // #nosec G304 -- path is owned by t.TempDir(), never external input
	var wrapped State
	if err := json.Unmarshal(stored, &wrapped); err != nil {
		t.Fatal(err)
	}
	if !wrapped.KeyEncrypted {
		t.Fatal("legacy key not wrapped on save")
	}
}

func TestStateAtomicRenameFailureCleansTemporaryFile(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "state.json")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := saveState(path, &State{}, fixtureUUID); err == nil {
		t.Fatal("rename over directory must fail")
	}
	files, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].Name() != "state.json" {
		t.Fatalf("temporary files leaked: %v", files)
	}
}

func TestWrappedKeyRejectsMalformedTamperedAndWrongKey(t *testing.T) {
	key := deriveWrappingKey("machine")
	wrapped, err := wrapKey([]byte("private"), key)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := unwrapKey(wrapped, key)
	if err != nil || string(plain) != "private" {
		t.Fatal("wrap round-trip failed")
	}
	for _, bad := range []string{"!invalid!", base64.StdEncoding.EncodeToString([]byte("short")), wrapped[:len(wrapped)-4] + "AAAA"} {
		if _, err := unwrapKey(bad, key); err == nil {
			t.Fatal("invalid ciphertext accepted")
		}
	}
	if _, err := unwrapKey(wrapped, deriveWrappingKey("other")); err == nil {
		t.Fatal("wrong wrapping key accepted")
	}
}

func TestStateSaveRejectsNilOrStillWrappedStateWithoutTouchingDisk(t *testing.T) {
	for _, state := range []*State{nil, {MacPrivateKey: "ciphertext", KeyEncrypted: true}} {
		path := filepath.Join(t.TempDir(), "missing", "state.json")
		if err := saveState(path, state, fixtureUUID); err == nil {
			t.Fatal("invalid state accepted")
		}
		if _, err := os.Stat(filepath.Dir(path)); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("invalid save created a directory")
		}
	}
}
