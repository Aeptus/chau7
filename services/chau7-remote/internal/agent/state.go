package agent

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type PairedDevice struct {
	ID                      string `json:"id"`
	Name                    string `json:"name,omitempty"`
	IOSPublicKey            string `json:"ios_public_key"`
	PublicKeyFingerprint    string `json:"public_key_fingerprint"`
	PairedAt                string `json:"paired_at,omitempty"`
	LastConnectedAt         string `json:"last_connected_at,omitempty"`
	PushToken               string `json:"push_token,omitempty"`
	PushTopic               string `json:"push_topic,omitempty"`
	PushEnvironment         string `json:"push_environment,omitempty"`
	NotificationsAuthorized bool   `json:"notifications_authorized,omitempty"`
}

type State struct {
	DeviceID      string         `json:"device_id"`
	MacPrivateKey string         `json:"mac_private_key"`
	MacPublicKey  string         `json:"mac_public_key"`
	IOSPublicKey  string         `json:"ios_public_key,omitempty"`
	IOSName       string         `json:"ios_name,omitempty"`
	PairedDevices []PairedDevice `json:"paired_devices,omitempty"`
	KeyEncrypted  bool           `json:"key_encrypted,omitempty"`
	RelaySecret   string         `json:"relay_secret,omitempty"`
}

func machineUUID() (string, error) {
	out, err := exec.Command("ioreg", "-rd1", "-c", "IOPlatformExpertDevice").Output()
	if err != nil {
		return "", fmt.Errorf("ioreg: %w", err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, "IOPlatformUUID") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				uuid := strings.Trim(strings.TrimSpace(parts[1]), "\"")
				if len(uuid) > 0 {
					return uuid, nil
				}
			}
		}
	}
	return "", errors.New("IOPlatformUUID not found")
}

func deriveWrappingKey(uuid string) []byte {
	h := sha256.Sum256([]byte("chau7-key-wrap:" + uuid))
	return h[:]
}

func wrapKey(plainKey []byte, wrappingKey []byte) (string, error) {
	block, err := aes.NewCipher(wrappingKey)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := gcm.Seal(nonce, nonce, plainKey, nil)
	return base64.StdEncoding.EncodeToString(sealed), nil
}

func unwrapKey(encoded string, wrappingKey []byte) ([]byte, error) {
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(wrappingKey)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(data) < gcm.NonceSize() {
		return nil, errors.New("wrapped key too short")
	}
	nonce := data[:gcm.NonceSize()]
	ciphertext := data[gcm.NonceSize():]
	return gcm.Open(nil, nonce, ciphertext, nil)
}

func LoadState(path string) (*State, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &State{}, nil
		}
		return nil, err
	}
	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}
	state.migrateLegacyPairedDevice()
	if state.KeyEncrypted && state.MacPrivateKey != "" {
		uuid, err := machineUUID()
		if err != nil {
			state.MacPrivateKey = ""
			state.MacPublicKey = ""
			state.KeyEncrypted = false
			return &state, nil
		}
		wk := deriveWrappingKey(uuid)
		plainB64, err := unwrapKey(state.MacPrivateKey, wk)
		if err != nil {
			state.MacPrivateKey = ""
			state.MacPublicKey = ""
			state.KeyEncrypted = false
			return &state, nil
		}
		state.MacPrivateKey = string(plainB64)
		state.KeyEncrypted = false
	}
	return &state, nil
}

func SaveState(path string, state *State) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	toSave := *state
	if toSave.MacPrivateKey != "" {
		uuid, err := machineUUID()
		if err == nil {
			wk := deriveWrappingKey(uuid)
			wrapped, err := wrapKey([]byte(toSave.MacPrivateKey), wk)
			if err == nil {
				toSave.MacPrivateKey = wrapped
				toSave.KeyEncrypted = true
			}
		}
	}
	data, err := json.MarshalIndent(&toSave, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".chau7-state-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp state file: %w", err)
	}
	tmpPath := tmp.Name()
	defer func() {
		if tmpPath != "" {
			os.Remove(tmpPath)
		}
	}()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp state file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("fsync temp state file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp state file: %w", err)
	}
	if err := os.Chmod(tmpPath, 0o600); err != nil {
		return fmt.Errorf("chmod temp state file: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("rename temp state file: %w", err)
	}
	tmpPath = ""
	return nil
}

func (s *State) MacPrivateKeyBytes() ([]byte, error) {
	if s.MacPrivateKey == "" {
		return nil, errors.New("missing mac private key")
	}
	return base64.StdEncoding.DecodeString(s.MacPrivateKey)
}

func (s *State) MacPublicKeyBytes() ([]byte, error) {
	if s.MacPublicKey == "" {
		return nil, errors.New("missing mac public key")
	}
	return base64.StdEncoding.DecodeString(s.MacPublicKey)
}

func (s *State) IOSPublicKeyBytes() ([]byte, error) {
	if s.IOSPublicKey == "" {
		return nil, errors.New("missing ios public key")
	}
	return base64.StdEncoding.DecodeString(s.IOSPublicKey)
}

func (s *State) HasPairedDevices() bool {
	return len(s.PairedDevices) > 0 || s.IOSPublicKey != ""
}

func (s *State) FindPairedDeviceByPublicKey(pubKey string) *PairedDevice {
	for i := range s.PairedDevices {
		if s.PairedDevices[i].IOSPublicKey == pubKey {
			return &s.PairedDevices[i]
		}
	}
	return nil
}

func (s *State) FindPairedDeviceByFingerprint(fp string) *PairedDevice {
	for i := range s.PairedDevices {
		if s.PairedDevices[i].PublicKeyFingerprint == fp {
			return &s.PairedDevices[i]
		}
	}
	return nil
}

func (s *State) UpsertPairedDevice(name, pubKey string, now time.Time) (*PairedDevice, error) {
	rawKey, err := base64.StdEncoding.DecodeString(pubKey)
	if err != nil {
		return nil, err
	}
	fp := fingerprintBytes(rawKey)
	timestamp := now.UTC().Format(time.RFC3339)

	if device := s.FindPairedDeviceByPublicKey(pubKey); device != nil {
		device.Name = name
		device.PublicKeyFingerprint = fp
		if device.PairedAt == "" {
			device.PairedAt = timestamp
		}
		s.syncLegacyDevice(*device)
		return device, nil
	}

	device := PairedDevice{
		ID:                   fp,
		Name:                 name,
		IOSPublicKey:         pubKey,
		PublicKeyFingerprint: fp,
		PairedAt:             timestamp,
	}
	s.PairedDevices = append(s.PairedDevices, device)
	s.syncLegacyDevice(device)
	return &s.PairedDevices[len(s.PairedDevices)-1], nil
}

func (s *State) MarkPairedDeviceConnected(deviceID string, now time.Time) *PairedDevice {
	for i := range s.PairedDevices {
		if s.PairedDevices[i].ID == deviceID {
			s.PairedDevices[i].LastConnectedAt = now.UTC().Format(time.RFC3339)
			s.syncLegacyDevice(s.PairedDevices[i])
			return &s.PairedDevices[i]
		}
	}
	return nil
}

func (s *State) UpdatePushRegistration(deviceID, token, topic, environment string, authorized bool) *PairedDevice {
	for i := range s.PairedDevices {
		if s.PairedDevices[i].ID == deviceID {
			if !authorized || token == "" || topic == "" {
				s.PairedDevices[i].PushToken = ""
				s.PairedDevices[i].PushTopic = ""
				s.PairedDevices[i].PushEnvironment = ""
				s.PairedDevices[i].NotificationsAuthorized = false
			} else {
				s.PairedDevices[i].PushToken = token
				s.PairedDevices[i].PushTopic = topic
				s.PairedDevices[i].PushEnvironment = environment
				s.PairedDevices[i].NotificationsAuthorized = true
			}
			return &s.PairedDevices[i]
		}
	}
	return nil
}

func (s *State) RemovePairedDevice(id string) bool {
	for i := range s.PairedDevices {
		if s.PairedDevices[i].ID == id {
			s.PairedDevices = append(s.PairedDevices[:i], s.PairedDevices[i+1:]...)
			s.syncLegacyFromFirstPairedDevice()
			return true
		}
	}
	return false
}

func (s *State) EnsureDeviceID() error {
	if s.DeviceID != "" {
		return nil
	}
	id, err := newUUID()
	if err != nil {
		return err
	}
	s.DeviceID = id
	return nil
}

func newUUID() (string, error) {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	if err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4],
		b[4:6],
		b[6:8],
		b[8:10],
		b[10:16],
	), nil
}

func (s *State) migrateLegacyPairedDevice() {
	if len(s.PairedDevices) > 0 || s.IOSPublicKey == "" {
		return
	}
	rawKey, err := base64.StdEncoding.DecodeString(s.IOSPublicKey)
	if err != nil || len(rawKey) == 0 {
		return
	}
	s.PairedDevices = append(s.PairedDevices, PairedDevice{
		ID:                   fingerprintBytes(rawKey),
		Name:                 s.IOSName,
		IOSPublicKey:         s.IOSPublicKey,
		PublicKeyFingerprint: fingerprintBytes(rawKey),
	})
}

func (s *State) syncLegacyDevice(device PairedDevice) {
	s.IOSPublicKey = device.IOSPublicKey
	s.IOSName = device.Name
}

func (s *State) syncLegacyFromFirstPairedDevice() {
	if len(s.PairedDevices) == 0 {
		s.IOSPublicKey = ""
		s.IOSName = ""
		return
	}
	s.syncLegacyDevice(s.PairedDevices[0])
}

func fingerprintBytes(rawKey []byte) string {
	sum := sha256.Sum256(rawKey)
	return base64.StdEncoding.EncodeToString(sum[:8])
}
