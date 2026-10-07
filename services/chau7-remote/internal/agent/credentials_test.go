package agent

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func testRelayCredentials(t *testing.T, deviceID string) *RelayCredentials {
	t.Helper()
	root := RelayKeyring{Current: RelayRootKey{ID: "test-key", Secret: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))}}
	credentials, err := DeriveRelayCredentials(root, deviceID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return &credentials
}
func testRelayIdentity(t *testing.T) (string, *State) {
	t.Helper()
	private, public, err := generateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	state := &State{DeviceID: "test-device", MacPrivateKey: base64.StdEncoding.EncodeToString(private), MacPublicKey: base64.StdEncoding.EncodeToString(public)}
	path := filepath.Join(t.TempDir(), "state.json")
	// Existing plaintext legacy identity fixture; provisioning must not rewrite it.
	if err := WritePrivateRelayJSON(path, state, false); err != nil {
		t.Fatal(err)
	}
	return path, state
}
func TestRelayCredentialsAreDeviceAndRoleScoped(t *testing.T) {
	a, b := testRelayCredentials(t, "device-a"), testRelayCredentials(t, "device-b")
	if a.MacSecret == b.MacSecret || a.IOSSecret == b.IOSSecret || a.MacSecret == a.IOSSecret {
		t.Fatal("credentials crossed a device or role boundary")
	}
	if err := a.Validate("device-b"); err == nil {
		t.Fatal("foreign credentials accepted")
	}
	a.IOSSecret = a.MacSecret
	if err := a.Validate("device-a"); err == nil {
		t.Fatal("shared role key accepted")
	}
}
func TestRelayStartupFailsClosedWithoutProvisioningOrIdentity(t *testing.T) {
	t.Setenv("CHAU7_REMOTE_CREDENTIALS", "")
	path, _ := testRelayIdentity(t)
	before, err := os.ReadFile(path) // #nosec G304 -- path comes from testRelayIdentity and is owned by t.TempDir(), never external input
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewAgent("", "", "", path); err == nil || !strings.Contains(err.Error(), "provision") {
		t.Fatalf("expected provisioning guidance, got %v", err)
	}
	after, _ := os.ReadFile(path) // #nosec G304 -- path comes from testRelayIdentity and is owned by t.TempDir(), never external input
	if !bytes.Equal(before, after) {
		t.Fatal("startup rewrote the existing identity")
	}
	missing := filepath.Join(t.TempDir(), "missing.json")
	if _, err := NewAgent("", "", "", missing); err == nil {
		t.Fatal("startup created an unprovisioned identity")
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatal("startup silently generated identity state")
	}
}
func TestProvisioningAndRotationPreserveIdentityAndReloadOnReconnect(t *testing.T) {
	t.Setenv("CHAU7_REMOTE_CREDENTIALS", "")
	path, state := testRelayIdentity(t)
	before, _ := os.ReadFile(path) // #nosec G304 -- path comes from testRelayIdentity and is owned by t.TempDir(), never external input
	bundle := filepath.Join(t.TempDir(), "bundle.json")
	credentials := testRelayCredentials(t, state.DeviceID)
	if err := WritePrivateRelayJSON(bundle, credentials, false); err != nil {
		t.Fatal(err)
	}
	if err := ProvisionRelayCredentials(bundle, path); err != nil {
		t.Fatal(err)
	}
	a, err := NewAgent("", "", "", path)
	if err != nil {
		t.Fatal(err)
	}
	first, err := a.relayDialOptions()
	if err != nil {
		t.Fatal(err)
	}
	credentials.KeyID = "rotated-key"
	credentials.MacSecret = base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32))
	if err := WritePrivateRelayJSON(bundle, credentials, true); err != nil {
		t.Fatal(err)
	}
	if err := ProvisionRelayCredentials(bundle, path); err != nil {
		t.Fatal(err)
	}
	next, err := a.relayDialOptions()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(first.HTTPHeader.Get("Authorization"), "v3.test-key.") || !strings.Contains(next.HTTPHeader.Get("Authorization"), "v3.rotated-key.") {
		t.Fatal("reconnect did not reload the rotated credential")
	}
	after, _ := os.ReadFile(path) // #nosec G304 -- path comes from testRelayIdentity and is owned by t.TempDir(), never external input
	if !bytes.Equal(before, after) {
		t.Fatal("provisioning/rotation rewrote private identity or trust")
	}
	if err := os.WriteFile(relayCredentialsPath(path), []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := a.relayDialOptions(); err == nil {
		t.Fatal("invalid replacement fell back to a cached key")
	}
}
func TestRelayCredentialFilesRejectWeakPermissionsSymlinksAndTrailingJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "credentials.json")
	credentials := testRelayCredentials(t, "device-a")
	if err := WritePrivateRelayJSON(path, credentials, false); err != nil {
		t.Fatal(err)
	}
	// #nosec G302 -- deliberately weaken an isolated fixture to verify rejection of public permissions
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadRelayCredentials(path, "device-a"); err == nil {
		t.Fatal("world-readable credentials accepted")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadRelayCredentials(link, "device-a"); err == nil {
		t.Fatal("symlink credentials accepted")
	}
	data, _ := json.Marshal(credentials)
	if err := os.WriteFile(path, append(data, []byte(` {}`)...), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadRelayCredentials(path, "device-a"); err == nil {
		t.Fatal("trailing JSON accepted")
	}
	if err := WritePrivateRelayJSON(path, credentials, false); err == nil {
		t.Fatal("exclusive creation overwrote an existing file")
	}
}
func TestRelayKeyRotationHasBoundedExplicitGrace(t *testing.T) {
	now := time.Unix(1800000000, 0)
	keyring, err := NewRelayKeyring("initial")
	if err != nil {
		t.Fatal(err)
	}
	for _, overlap := range []time.Duration{0, time.Millisecond, 25 * time.Hour} {
		if _, err := RotateRelayKeyring(keyring, overlap, now); err == nil {
			t.Fatal("invalid overlap accepted")
		}
	}
	next, err := RotateRelayKeyring(keyring, time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	if next.Current.Secret == keyring.Current.Secret || next.Previous.ID != "initial" || next.Previous.AcceptUntil != now.Add(time.Hour).Unix() {
		t.Fatal("incorrect key rotation")
	}
	if err := next.Validate(now); err != nil {
		t.Fatal(err)
	}
}

func TestRelayDerivationMatchesSharedCrossLanguageVector(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "docs", "fixtures", "relay_credentials_v3.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vector map[string]string
	if err := json.Unmarshal(data, &vector); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"root", "mac", "ios"} {
		raw, err := hex.DecodeString(vector[field+"_bytes_hex"])
		if err != nil {
			t.Fatal(err)
		}
		key := field
		if field != "root" {
			key += "_secret"
		}
		vector[key] = base64.RawURLEncoding.EncodeToString(raw)
	}
	ring := RelayKeyring{Current: RelayRootKey{ID: vector["key_id"], Secret: vector["root"]}}
	credentials, err := DeriveRelayCredentials(ring, vector["device_id"], time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, role := range []string{"mac", "ios"} {
		if got := signRelayToken(vector["device_id"], role, vector["scope"], vector["key_id"], vector[role+"_secret"], vector["timestamp"], vector["nonce"]); got != vector[role+"_token"] {
			t.Fatal("token signature drifted from cross-language vector")
		}
	}
	if credentials.MacSecret != vector["mac_secret"] || credentials.IOSSecret != vector["ios_secret"] {
		t.Fatal("derivation drifted from cross-language vector")
	}
}

func TestRelayCredentialNamedPipeIsRejectedWithoutWaitingForAWriter(t *testing.T) {
	path := filepath.Join(t.TempDir(), "credentials.json")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	defer func() {
		// Release a pre-fix blocking reader after the timeout; never leave the fixture goroutine stranded.
		writer, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
		if err == nil {
			_ = syscall.Close(writer)
		}
	}()
	rejected := make(chan error, 1)
	go func() { _, err := LoadRelayCredentials(path, "device-a"); rejected <- err }()
	select {
	case err := <-rejected:
		if err == nil {
			t.Fatal("named pipe credentials accepted")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("credential reader waited for a named pipe writer before validating the descriptor")
	}
}
