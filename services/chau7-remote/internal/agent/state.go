package agent

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type State struct {
	DeviceID     string `json:"device_id"`
	MacPrivateKey string `json:"mac_private_key"`
	MacPublicKey  string `json:"mac_public_key"`
	IOSPublicKey  string `json:"ios_public_key,omitempty"`
	IOSName       string `json:"ios_name,omitempty"`
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
	return &state, nil
}

func SaveState(path string, state *State) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(state, "", "  ")
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
