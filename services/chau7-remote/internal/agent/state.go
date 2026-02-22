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
)

type State struct {
	DeviceID      string `json:"device_id"`
	MacPrivateKey string `json:"mac_private_key"`
	MacPublicKey  string `json:"mac_public_key"`
	IOSPublicKey  string `json:"ios_public_key,omitempty"`
	IOSName       string `json:"ios_name,omitempty"`
	KeyEncrypted  bool   `json:"key_encrypted,omitempty"`
	RelaySecret   string `json:"relay_secret,omitempty"`
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
	if state.KeyEncrypted && state.MacPrivateKey != "" {
		uuid, err := machineUUID()
		if err != nil {
			// Different machine or ioreg unavailable — clear keys, require re-pairing
			state.MacPrivateKey = ""
			state.MacPublicKey = ""
			state.KeyEncrypted = false
			return &state, nil
		}
		wk := deriveWrappingKey(uuid)
		plainB64, err := unwrapKey(state.MacPrivateKey, wk)
		if err != nil {
			// Key was encrypted on a different machine — clear keys
			state.MacPrivateKey = ""
			state.MacPublicKey = ""
			state.KeyEncrypted = false
			return &state, nil
		}
		state.MacPrivateKey = string(plainB64)
		state.KeyEncrypted = false // Mark as decrypted for in-memory use
	}
	return &state, nil
}

func SaveState(path string, state *State) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
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
	return os.WriteFile(path, data, 0o600)
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
