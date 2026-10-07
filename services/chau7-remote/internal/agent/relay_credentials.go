package agent

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	"golang.org/x/crypto/curve25519"
)

const MaxRelayRotationOverlap = 24 * time.Hour

var relayKeyIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,32}$`)
var relayDeviceIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

type RelayCredentials struct {
	DeviceID  string `json:"device_id"`
	KeyID     string `json:"key_id"`
	MacSecret string `json:"mac_secret"`
	IOSSecret string `json:"ios_secret"`
}
type RelayRootKey struct {
	ID     string `json:"id"`
	Secret string `json:"secret"`
}
type PreviousRelayRootKey struct {
	RelayRootKey
	GraceStartedAt int64 `json:"grace_started_at"`
	AcceptUntil    int64 `json:"accept_until"`
}
type RelayKeyring struct {
	Current  RelayRootKey          `json:"current"`
	Previous *PreviousRelayRootKey `json:"previous,omitempty"`
}
type RelayIdentityInfo struct {
	DeviceID     string `json:"device_id"`
	MacPublicKey string `json:"mac_public_key"`
}

func strongRelaySecret(value string) bool {
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(value)
	return err == nil && len(decoded) == 32 && base64.RawURLEncoding.EncodeToString(decoded) == value
}
func (credentials RelayCredentials) Validate(deviceID string) error {
	if !relayDeviceIDPattern.MatchString(credentials.DeviceID) || credentials.DeviceID != deviceID {
		return errors.New("credential bundle does not match this remote device identity")
	}
	if !relayKeyIDPattern.MatchString(credentials.KeyID) {
		return errors.New("invalid relay credential key ID")
	}
	if !strongRelaySecret(credentials.MacSecret) || !strongRelaySecret(credentials.IOSSecret) || credentials.MacSecret == credentials.IOSSecret {
		return errors.New("relay credentials must contain distinct canonical 256-bit role keys")
	}
	return nil
}
func (keyring RelayKeyring) Validate(now time.Time) error {
	valid := func(key RelayRootKey) bool {
		return relayKeyIDPattern.MatchString(key.ID) && strongRelaySecret(key.Secret)
	}
	if !valid(keyring.Current) {
		return errors.New("invalid current relay root key")
	}
	if previous := keyring.Previous; previous != nil {
		if !valid(previous.RelayRootKey) || previous.ID == keyring.Current.ID || previous.GraceStartedAt < 0 || previous.GraceStartedAt > now.Unix() || previous.AcceptUntil <= previous.GraceStartedAt || previous.AcceptUntil-previous.GraceStartedAt > int64(MaxRelayRotationOverlap/time.Second) {
			return errors.New("previous relay key requires a distinct ID and at most 24 hours of rotation overlap")
		}
	}
	return nil
}
func DeriveRelayCredentials(keyring RelayKeyring, deviceID string, now time.Time) (RelayCredentials, error) {
	if err := keyring.Validate(now); err != nil {
		return RelayCredentials{}, err
	}
	if !relayDeviceIDPattern.MatchString(deviceID) {
		return RelayCredentials{}, errors.New("invalid remote device ID")
	}
	root, err := base64.RawURLEncoding.Strict().DecodeString(keyring.Current.Secret)
	if err != nil {
		return RelayCredentials{}, errors.New("invalid relay root encoding")
	}
	derive := func(role string) string {
		mac := hmac.New(sha256.New, root)
		_, _ = mac.Write([]byte("chau7-v3:" + keyring.Current.ID + ":" + deviceID + ":" + role))
		return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	}
	return RelayCredentials{DeviceID: deviceID, KeyID: keyring.Current.ID, MacSecret: derive("mac"), IOSSecret: derive("ios")}, nil
}
func NewRelayKeyring(keyID string) (RelayKeyring, error) {
	if keyID == "" {
		randomID := make([]byte, 8)
		if _, err := rand.Read(randomID); err != nil {
			return RelayKeyring{}, err
		}
		keyID = hex.EncodeToString(randomID)
	}
	if !relayKeyIDPattern.MatchString(keyID) {
		return RelayKeyring{}, errors.New("invalid relay root key ID")
	}
	material := make([]byte, 32)
	if _, err := rand.Read(material); err != nil {
		return RelayKeyring{}, err
	}
	return RelayKeyring{Current: RelayRootKey{ID: keyID, Secret: base64.RawURLEncoding.EncodeToString(material)}}, nil
}
func RotateRelayKeyring(previous RelayKeyring, overlap time.Duration, now time.Time) (RelayKeyring, error) {
	if err := previous.Validate(now); err != nil {
		return RelayKeyring{}, err
	}
	if overlap < time.Second || overlap > MaxRelayRotationOverlap || overlap%time.Second != 0 {
		return RelayKeyring{}, errors.New("rotation overlap must be whole seconds between one second and 24 hours")
	}
	next, err := NewRelayKeyring("")
	if err != nil {
		return RelayKeyring{}, err
	}
	next.Previous = &PreviousRelayRootKey{RelayRootKey: previous.Current, GraceStartedAt: now.Unix(), AcceptUntil: now.Add(overlap).Unix()}
	return next, nil
}

// The opened descriptor, not a racy pathname stat, owns the permission check.
func readPrivateRelayJSON(path string, value any) error {
	// #nosec G304 -- operator-selected local key/credential file; no-follow and descriptor ownership/permissions are checked before any bytes are read.
	file, err := os.OpenFile(filepath.Clean(path), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("open owner-only relay configuration: %w", err)
	}
	defer func() { _ = file.Close() }()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	uid := os.Getuid()
	if uid < 0 || !ok || uint64(owner.Uid) != uint64(uid) || !info.Mode().IsRegular() || (info.Mode().Perm() != 0o600 && info.Mode().Perm() != 0o400) || info.Size() > 8192 {
		return errors.New("relay configuration must be a regular owner-only file (0600 or 0400), at most 8 KiB, owned by the current user")
	}
	decoder := json.NewDecoder(io.LimitReader(file, 8193))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return errors.New("invalid relay configuration JSON")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return errors.New("relay configuration contains trailing data")
	}
	return nil
}
func WritePrivateRelayJSON(path string, value any, replace bool) error {
	if path == "" {
		return errors.New("an output file is required; relay secrets are never printed")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".relay-credentials-*")
	if err != nil {
		return err
	}
	name := file.Name()
	defer func() { _ = os.Remove(name) }()
	if err := json.NewEncoder(file).Encode(value); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if !replace {
		return os.Link(name, path)
	}
	return os.Rename(name, path)
}
func LoadRelayKeyring(path string, now time.Time) (RelayKeyring, error) {
	var keyring RelayKeyring
	if err := readPrivateRelayJSON(path, &keyring); err != nil {
		return keyring, err
	}
	return keyring, keyring.Validate(now)
}
func relayCredentialsPath(statePath string) string {
	return filepath.Join(filepath.Dir(statePath), "credentials.json")
}
func LoadRelayCredentials(path, deviceID string) (*RelayCredentials, error) {
	var credentials RelayCredentials
	if err := readPrivateRelayJSON(path, &credentials); err != nil {
		return nil, err
	}
	if err := credentials.Validate(deviceID); err != nil {
		return nil, err
	}
	return &credentials, nil
}
func validateRelayIdentity(state *State) error {
	if !relayDeviceIDPattern.MatchString(state.DeviceID) {
		return errors.New("remote identity is missing; run chau7-remote identity before provisioning")
	}
	private, err := base64.StdEncoding.DecodeString(state.MacPrivateKey)
	if err != nil || len(private) != 32 {
		return errors.New("remote private identity is invalid; preserve the state file and recover its existing key")
	}
	public, err := base64.StdEncoding.DecodeString(state.MacPublicKey)
	if err != nil || len(public) != 32 {
		return errors.New("remote public identity is invalid; preserve the state file")
	}
	expected, err := curve25519.X25519(private, curve25519.Basepoint)
	if err != nil || !hmac.Equal(public, expected) {
		return errors.New("remote identity key pair does not match; preserve the state file")
	}
	return nil
}
func PrepareRelayIdentity(statePath string) (RelayIdentityInfo, error) {
	if statePath == "" {
		statePath = defaultStatePath()
	}
	_, statErr := os.Stat(statePath)
	if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return RelayIdentityInfo{}, statErr
	}
	var state *State
	if errors.Is(statErr, os.ErrNotExist) {
		state = &State{}
		if err := state.EnsureDeviceID(); err != nil {
			return RelayIdentityInfo{}, err
		}
		private, public, err := generateKeyPair()
		if err != nil {
			return RelayIdentityInfo{}, err
		}
		state.MacPrivateKey = base64.StdEncoding.EncodeToString(private)
		state.MacPublicKey = base64.StdEncoding.EncodeToString(public)
		if err := os.MkdirAll(filepath.Dir(statePath), 0o700); err != nil {
			return RelayIdentityInfo{}, err
		}
		staging, err := os.MkdirTemp(filepath.Dir(statePath), ".identity-*")
		if err != nil {
			return RelayIdentityInfo{}, err
		}
		defer func() { _ = os.RemoveAll(staging) }()
		stagedPath := filepath.Join(staging, "state.json")
		if err := SaveState(stagedPath, state); err != nil {
			return RelayIdentityInfo{}, err
		}
		// Exclusive publication cannot replace an identity created concurrently.
		if err := os.Link(stagedPath, statePath); err != nil {
			return RelayIdentityInfo{}, err
		}
	} else {
		var err error
		state, err = LoadState(statePath)
		if err != nil {
			return RelayIdentityInfo{}, err
		}
	}
	if err := validateRelayIdentity(state); err != nil {
		return RelayIdentityInfo{}, err
	}
	return RelayIdentityInfo{DeviceID: state.DeviceID, MacPublicKey: state.MacPublicKey}, nil
}

func ProvisionRelayCredentials(bundlePath, statePath string) error {
	if statePath == "" {
		statePath = defaultStatePath()
	}
	state, err := LoadState(statePath)
	if err != nil {
		return err
	}
	if err := validateRelayIdentity(state); err != nil {
		return err
	}
	credentials, err := LoadRelayCredentials(bundlePath, state.DeviceID)
	if err != nil {
		return err
	}
	// State/private identity is never rewritten by provisioning or rotation.
	return WritePrivateRelayJSON(relayCredentialsPath(statePath), credentials, true)
}
func DefaultRemoteStatePath() string { return defaultStatePath() }
func (a *Agent) currentRelayCredentials() (*RelayCredentials, error) {
	if a.credentialsPath == "" {
		// Explicit in-memory fixtures only. Production NewAgent always sets a path.
		if a.credentials != nil {
			return a.credentials, a.credentials.Validate(a.state.DeviceID)
		}
		return nil, errors.New("remote credentials are unavailable; run chau7-remote provision --bundle <file> --state <state.json>")
	}
	credentials, err := LoadRelayCredentials(a.credentialsPath, a.state.DeviceID)
	if err != nil {
		return nil, fmt.Errorf("remote credentials unavailable; run chau7-remote provision --bundle <file> --state <state.json>: %w", err)
	}
	return credentials, nil
}
func (a *Agent) relayAuthorization(scope string) (string, error) {
	credentials, err := a.currentRelayCredentials()
	if err != nil {
		return "", err
	}
	return "Bearer " + generateRelayToken(a.state.DeviceID, "mac", scope, credentials.KeyID, credentials.MacSecret), nil
}
