package agent

import (
	"bufio"
	"context"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
	"nhooyr.io/websocket"

	"chau7-remote/internal/protocol"
)

const (
	defaultRelayURL = "wss://relay.example.com/connect"
	pairingTTL      = 10 * time.Minute
	maxFrameSize    = 5 * 1024 * 1024
)

type Agent struct {
	socketPath   string
	relayBaseURL string
	macName      string
	statePath    string

	state *State

	pairingCode    string
	pairingExpires time.Time

	ipcMu   sync.Mutex
	ipcConn *net.UnixConn

	wsMu   sync.Mutex
	wsConn *websocket.Conn

	sessionMu    sync.Mutex
	crypto       *cryptoSession
	macNonce     []byte
	iosNonce     []byte
	sessionReady bool
	sendSeq      uint64
}

type HelloPayload struct {
	DeviceID  string `json:"device_id"`
	Role      string `json:"role"`
	Nonce     string `json:"nonce"`
	PubKeyFP  string `json:"pub_key_fp"`
	AppVersion string `json:"app_version"`
}

type PairRequestPayload struct {
	DeviceID    string `json:"device_id"`
	PairingCode string `json:"pairing_code"`
	IOSPub      string `json:"ios_pub"`
	IOSName     string `json:"ios_name"`
}

type PairAcceptPayload struct {
	DeviceID string `json:"device_id"`
	MacPub   string `json:"mac_pub"`
	MacName  string `json:"mac_name"`
}

type PairRejectPayload struct {
	Reason string `json:"reason"`
}

type SessionReadyPayload struct {
	SessionID string `json:"session_id"`
}

type TabSwitchPayload struct {
	TabID uint32 `json:"tab_id"`
}

type PairingInfoPayload struct {
	RelayURL    string `json:"relay_url"`
	DeviceID    string `json:"device_id"`
	MacPub      string `json:"mac_pub"`
	PairingCode string `json:"pairing_code"`
	ExpiresAt   string `json:"expires_at"`
}

type cryptoSession struct {
	aead        cipher.AEAD
	noncePrefix [4]byte
}

func NewAgent(socketPath, relayBaseURL, macName, statePath string) (*Agent, error) {
	if relayBaseURL == "" {
		relayBaseURL = defaultRelayURL
	}
	if macName == "" {
		macName = "Mac"
	}
	if socketPath == "" {
		socketPath = defaultSocketPath()
	}
	if statePath == "" {
		statePath = defaultStatePath()
	}
	state, err := LoadState(statePath)
	if err != nil {
		return nil, err
	}
	agent := &Agent{
		socketPath:   socketPath,
		relayBaseURL: relayBaseURL,
		macName:      macName,
		statePath:    statePath,
		state:        state,
		sendSeq:      1,
	}
	if err := agent.ensureIdentity(); err != nil {
		return nil, err
	}
	agent.refreshPairingCode()
	return agent, nil
}

func (a *Agent) Run(ctx context.Context) error {
	go a.ipcLoop(ctx)
	go a.relayLoop(ctx)
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if time.Now().After(a.pairingExpires) {
				a.refreshPairingCode()
				a.sendPairingInfo()
			}
		}
	}
}

func (a *Agent) ensureIdentity() error {
	if err := a.state.EnsureDeviceID(); err != nil {
		return err
	}
	if a.state.MacPrivateKey == "" || a.state.MacPublicKey == "" {
		priv, pub, err := generateKeyPair()
		if err != nil {
			return err
		}
		a.state.MacPrivateKey = base64.StdEncoding.EncodeToString(priv)
		a.state.MacPublicKey = base64.StdEncoding.EncodeToString(pub)
	}
	return SaveState(a.statePath, a.state)
}

func generateKeyPair() ([]byte, []byte, error) {
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		return nil, nil, err
	}
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return nil, nil, err
	}
	return priv, pub, nil
}

func (a *Agent) ipcLoop(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}
		conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: a.socketPath, Net: "unix"})
		if err != nil {
			time.Sleep(1 * time.Second)
			continue
		}
		a.ipcMu.Lock()
		a.ipcConn = conn
		a.ipcMu.Unlock()
		a.sendPairingInfo()
		a.readIPC(ctx, conn)
		a.ipcMu.Lock()
		a.ipcConn = nil
		a.ipcMu.Unlock()
		time.Sleep(1 * time.Second)
	}
}

func (a *Agent) readIPC(ctx context.Context, conn *net.UnixConn) {
	reader := bufio.NewReader(conn)
	for {
		if ctx.Err() != nil {
			return
		}
		frame, err := readIPCFrame(reader)
		if err != nil {
			return
		}
		a.handleIPCFrame(frame)
	}
}

func (a *Agent) relayLoop(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}
		url := a.relayConnectURL()
		conn, _, err := websocket.Dial(ctx, url, nil)
		if err != nil {
			time.Sleep(2 * time.Second)
			continue
		}
		a.wsMu.Lock()
		a.wsConn = conn
		a.wsMu.Unlock()
		a.resetSession()
		if a.state.IOSPublicKey != "" {
			_ = a.sendHello()
		}
		a.readRelay(ctx, conn)
		a.wsMu.Lock()
		a.wsConn = nil
		a.wsMu.Unlock()
		time.Sleep(2 * time.Second)
	}
}

func (a *Agent) readRelay(ctx context.Context, conn *websocket.Conn) {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		frame, err := protocol.DecodeFrame(data)
		if err != nil {
			continue
		}
		a.handleRelayFrame(frame)
	}
}

func (a *Agent) handleIPCFrame(frame *protocol.Frame) {
	switch frame.Type {
	case protocol.TypeTabList, protocol.TypeOutput, protocol.TypeSnapshot:
		a.sendEncryptedToRelay(frame)
	case protocol.TypePing:
		a.sendEncryptedToRelay(&protocol.Frame{
			Version: 1,
			Type:    protocol.TypePong,
			TabID:   frame.TabID,
			Seq:     a.nextSeq(),
			Payload: frame.Payload,
		})
	}
}

func (a *Agent) handleRelayFrame(frame *protocol.Frame) {
	if frame.Flags&protocol.FlagEncrypted != 0 {
		payload, err := a.decryptPayload(frame)
		if err != nil {
			return
		}
		frame.Payload = payload
		frame.Flags &^= protocol.FlagEncrypted
	}

	switch frame.Type {
	case protocol.TypeHello:
		a.handleHello(frame.Payload)
	case protocol.TypePairRequest:
		a.handlePairRequest(frame.Payload)
	case protocol.TypeSessionReady:
		a.sessionReady = true
		a.sendSessionStatus("ready")
	case protocol.TypeTabSwitch, protocol.TypeInput:
		a.sendToIPC(frame)
	case protocol.TypePing:
		a.sendEncryptedToRelay(&protocol.Frame{
			Version: 1,
			Type:    protocol.TypePong,
			TabID:   frame.TabID,
			Seq:     a.nextSeq(),
			Payload: frame.Payload,
		})
	}
}

func (a *Agent) handlePairRequest(payload []byte) {
	var request PairRequestPayload
	if err := json.Unmarshal(payload, &request); err != nil {
		return
	}
	if request.PairingCode != a.pairingCode || time.Now().After(a.pairingExpires) {
		a.sendPairReject("invalid_code")
		return
	}

	a.state.IOSPublicKey = request.IOSPub
	a.state.IOSName = request.IOSName
	_ = SaveState(a.statePath, a.state)

	accept := PairAcceptPayload{
		DeviceID: a.state.DeviceID,
		MacPub:   a.state.MacPublicKey,
		MacName:  a.macName,
	}
	data, _ := json.Marshal(accept)
	a.sendToRelay(&protocol.Frame{
		Version: 1,
		Type:    protocol.TypePairAccept,
		Seq:     a.nextSeq(),
		Payload: data,
	})
	_ = a.sendHello()
}

func (a *Agent) handleHello(payload []byte) {
	var hello HelloPayload
	if err := json.Unmarshal(payload, &hello); err != nil {
		return
	}
	nonce, err := base64.StdEncoding.DecodeString(hello.Nonce)
	if err != nil {
		return
	}
	a.sessionMu.Lock()
	a.iosNonce = nonce
	a.sessionMu.Unlock()
	a.establishSession()
}

func (a *Agent) sendHello() error {
	macNonce := make([]byte, 16)
	if _, err := rand.Read(macNonce); err != nil {
		return err
	}
	fp := fingerprint(a.state.MacPublicKey)
	payload := HelloPayload{
		DeviceID:  a.state.DeviceID,
		Role:      "mac",
		Nonce:     base64.StdEncoding.EncodeToString(macNonce),
		PubKeyFP:  fp,
		AppVersion: "0.1.0",
	}
	data, _ := json.Marshal(payload)

	a.sessionMu.Lock()
	a.macNonce = macNonce
	a.sessionMu.Unlock()

	a.sendToRelay(&protocol.Frame{
		Version: 1,
		Type:    protocol.TypeHello,
		Seq:     a.nextSeq(),
		Payload: data,
	})
	return nil
}

func (a *Agent) establishSession() {
	a.sessionMu.Lock()
	defer a.sessionMu.Unlock()

	if a.crypto != nil {
		return
	}
	if len(a.macNonce) == 0 || len(a.iosNonce) == 0 {
		return
	}
	iosPub, err := a.state.IOSPublicKeyBytes()
	if err != nil {
		return
	}
	macPriv, err := a.state.MacPrivateKeyBytes()
	if err != nil {
		return
	}
	shared, err := curve25519.X25519(macPriv, iosPub)
	if err != nil {
		return
	}
	crypto, err := newCryptoSession(shared, a.macNonce, a.iosNonce)
	if err != nil {
		return
	}
	a.crypto = crypto
	a.sessionReady = true

	sessionID := make([]byte, 8)
	_, _ = rand.Read(sessionID)
	ready := SessionReadyPayload{
		SessionID: base64.StdEncoding.EncodeToString(sessionID),
	}
	data, _ := json.Marshal(ready)
	frame := &protocol.Frame{
		Version: 1,
		Type:    protocol.TypeSessionReady,
		Seq:     a.nextSeq(),
		Payload: data,
	}
	a.sendEncryptedToRelay(frame)
	a.sendSessionStatus("ready")
}

func (a *Agent) resetSession() {
	a.sessionMu.Lock()
	defer a.sessionMu.Unlock()
	a.crypto = nil
	a.macNonce = nil
	a.iosNonce = nil
	a.sessionReady = false
}

func newCryptoSession(shared, nonceMac, nonceIOS []byte) (*cryptoSession, error) {
	salt := append([]byte{}, nonceMac...)
	salt = append(salt, nonceIOS...)
	key := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, shared, salt, nil), key); err != nil {
		return nil, err
	}
	prefix := make([]byte, 4)
	if _, err := io.ReadFull(hkdf.New(sha256.New, shared, nil, []byte("nonce")), prefix); err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	var noncePrefix [4]byte
	copy(noncePrefix[:], prefix)
	return &cryptoSession{
		aead:        aead,
		noncePrefix: noncePrefix,
	}, nil
}

func (a *Agent) decryptPayload(frame *protocol.Frame) ([]byte, error) {
	a.sessionMu.Lock()
	crypto := a.crypto
	a.sessionMu.Unlock()
	if crypto == nil {
		return nil, errors.New("missing session")
	}
	nonce := makeNonce(crypto.noncePrefix, frame.Seq)
	header := frame.HeaderBytes(uint32(len(frame.Payload)))
	plaintext, err := crypto.aead.Open(nil, nonce, frame.Payload, header)
	if err != nil {
		return nil, err
	}
	return plaintext, nil
}

func (a *Agent) sendEncryptedToRelay(frame *protocol.Frame) {
	a.sessionMu.Lock()
	crypto := a.crypto
	a.sessionMu.Unlock()
	if crypto == nil {
		return
	}
	nonce := makeNonce(crypto.noncePrefix, frame.Seq)
	payloadLen := uint32(len(frame.Payload) + crypto.aead.Overhead())
	frame.Flags |= protocol.FlagEncrypted
	header := frame.HeaderBytes(payloadLen)
	ciphertext := crypto.aead.Seal(nil, nonce, frame.Payload, header)
	frame.Payload = ciphertext
	a.sendToRelay(frame)
}

func makeNonce(prefix [4]byte, seq uint64) []byte {
	nonce := make([]byte, 12)
	copy(nonce[:4], prefix[:])
	binary.LittleEndian.PutUint64(nonce[4:], seq)
	return nonce
}

func (a *Agent) sendPairReject(reason string) {
	payload, _ := json.Marshal(PairRejectPayload{Reason: reason})
	a.sendToRelay(&protocol.Frame{
		Version: 1,
		Type:    protocol.TypePairReject,
		Seq:     a.nextSeq(),
		Payload: payload,
	})
}

func (a *Agent) sendSessionStatus(status string) {
	payload, _ := json.Marshal(map[string]string{"status": status})
	a.sendToIPC(&protocol.Frame{
		Version: 1,
		Type:    protocol.TypeSessionStatus,
		Seq:     a.nextSeq(),
		Payload: payload,
	})
}

func (a *Agent) sendPairingInfo() {
	info := PairingInfoPayload{
		RelayURL:    a.relayBaseURL,
		DeviceID:    a.state.DeviceID,
		MacPub:      a.state.MacPublicKey,
		PairingCode: a.pairingCode,
		ExpiresAt:   a.pairingExpires.UTC().Format(time.RFC3339),
	}
	data, _ := json.Marshal(info)
	a.sendToIPC(&protocol.Frame{
		Version: 1,
		Type:    protocol.TypePairingInfo,
		Seq:     a.nextSeq(),
		Payload: data,
	})
}

func (a *Agent) sendToRelay(frame *protocol.Frame) {
	a.wsMu.Lock()
	conn := a.wsConn
	a.wsMu.Unlock()
	if conn == nil {
		return
	}
	data := frame.Encode()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = conn.Write(ctx, websocket.MessageBinary, data)
}

func (a *Agent) sendToIPC(frame *protocol.Frame) {
	a.ipcMu.Lock()
	conn := a.ipcConn
	a.ipcMu.Unlock()
	if conn == nil {
		return
	}
	_ = writeIPCFrame(conn, frame)
}

func (a *Agent) relayConnectURL() string {
	base := strings.TrimSuffix(a.relayBaseURL, "/")
	return fmt.Sprintf("%s/%s?role=mac", base, a.state.DeviceID)
}

func (a *Agent) refreshPairingCode() {
	a.pairingCode = newPairingCode()
	a.pairingExpires = time.Now().Add(pairingTTL)
}

func newPairingCode() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	code := binary.LittleEndian.Uint32(b) % 1000000
	return fmt.Sprintf("%06d", code)
}

func fingerprint(pubKey string) string {
	data, err := base64.StdEncoding.DecodeString(pubKey)
	if err != nil {
		return ""
	}
	hash := sha256.Sum256(data)
	return base64.StdEncoding.EncodeToString(hash[:8])
}

func readIPCFrame(reader *bufio.Reader) (*protocol.Frame, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(reader, lenBuf[:]); err != nil {
		return nil, err
	}
	length := binary.LittleEndian.Uint32(lenBuf[:])
	if length == 0 || length > maxFrameSize {
		return nil, errors.New("invalid ipc frame length")
	}
	buf := make([]byte, length)
	if _, err := io.ReadFull(reader, buf); err != nil {
		return nil, err
	}
	return protocol.DecodeFrame(buf)
}

func writeIPCFrame(conn *net.UnixConn, frame *protocol.Frame) error {
	payload := frame.Encode()
	if len(payload) > maxFrameSize {
		return errors.New("frame too large")
	}
	var lenBuf [4]byte
	binary.LittleEndian.PutUint32(lenBuf[:], uint32(len(payload)))
	if _, err := conn.Write(lenBuf[:]); err != nil {
		return err
	}
	_, err := conn.Write(payload)
	return err
}

func defaultSocketPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library/Application Support/Chau7/remote.sock")
}

func defaultStatePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".chau7/remote/state.json")
}
