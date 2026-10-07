package protocol

import (
	"encoding/binary"
	"errors"
	"math"
)

const (
	HeaderSize       = 20
	FlagEncrypted    = 0x01
	FlagOutputTiming = 0x02
)

const (
	TypeHello                     = 0x01
	TypePairRequest               = 0x02
	TypePairAccept                = 0x03
	TypePairReject                = 0x04
	TypeSessionReady              = 0x05
	TypeTabList                   = 0x10
	TypeTabSwitch                 = 0x11
	TypeActivityState             = 0x12
	TypeActivityCleared           = 0x13
	TypeCachedTabList             = 0x14
	TypeInteractivePromptList     = 0x15
	TypeOutput                    = 0x20
	TypeInput                     = 0x21
	TypeSnapshot                  = 0x22
	TypeTerminalGridSnapshot      = 0x23
	TypeKeyInput                  = 0x24
	TypeCheckpointRequest         = 0x25
	TypeInteractivePromptResponse = 0x26
	TypePaneInput                 = 0x27
	// TypeTerminalSize announces a tab's live PTY dimensions so the client can
	// size its own emulator to the source width. A rendering concern, so it is
	// its own tab-scoped frame rather than a field on the tab inventory.
	TypeTerminalSize      = 0x28
	TypePing              = 0x30
	TypePong              = 0x31
	TypePairingInfo       = 0x40
	TypeSessionStatus     = 0x41
	TypeRemoteTelemetry   = 0x42
	TypeClientState       = 0x43
	TypeRelayStatus       = 0x44
	TypeApprovalRequest   = 0x50
	TypeApprovalResponse  = 0x51
	TypeNotificationEvent = 0x52
	TypeError             = 0x7F
)

var (
	ErrInsufficientData = errors.New("insufficient data")
	ErrInvalidLength    = errors.New("invalid length")
)

type Frame struct {
	Version  uint8
	Type     uint8
	Flags    uint8
	Reserved uint8
	TabID    uint32
	Seq      uint64
	Payload  []byte
}

func (f *Frame) Encode() []byte {
	payloadLen, err := PayloadLength(len(f.Payload), 0)
	if err != nil {
		return nil
	}
	data := make([]byte, HeaderSize+len(f.Payload))
	data[0] = f.Version
	data[1] = f.Type
	data[2] = f.Flags
	data[3] = f.Reserved
	binary.LittleEndian.PutUint32(data[4:8], f.TabID)
	binary.LittleEndian.PutUint64(data[8:16], f.Seq)
	binary.LittleEndian.PutUint32(data[16:20], payloadLen)
	copy(data[HeaderSize:], f.Payload)
	return data
}

func (f *Frame) HeaderBytes(payloadLen uint32) []byte {
	data := make([]byte, HeaderSize)
	data[0] = f.Version
	data[1] = f.Type
	data[2] = f.Flags
	data[3] = f.Reserved
	binary.LittleEndian.PutUint32(data[4:8], f.TabID)
	binary.LittleEndian.PutUint64(data[8:16], f.Seq)
	binary.LittleEndian.PutUint32(data[16:20], payloadLen)
	return data
}

var ErrUnsupportedVersion = errors.New("unsupported protocol version")

func DecodeFrame(data []byte) (*Frame, error) {
	if len(data) < HeaderSize {
		return nil, ErrInsufficientData
	}
	if data[0] != 1 {
		return nil, ErrUnsupportedVersion
	}
	payloadLen := int(binary.LittleEndian.Uint32(data[16:20]))
	if payloadLen < 0 || len(data) < HeaderSize+payloadLen {
		return nil, ErrInvalidLength
	}
	frame := &Frame{
		Version:  data[0],
		Type:     data[1],
		Flags:    data[2],
		Reserved: data[3],
		TabID:    binary.LittleEndian.Uint32(data[4:8]),
		Seq:      binary.LittleEndian.Uint64(data[8:16]),
		Payload:  data[HeaderSize : HeaderSize+payloadLen],
	}
	return frame, nil
}

// PayloadLength checks the wire length before narrowing or adding encryption overhead.
// Keeping this independent of a buffer also makes overflow boundaries testable.
func PayloadLength(length, overhead int) (uint32, error) {
	if length < 0 || overhead < 0 {
		return 0, ErrInvalidLength
	}
	total := uint64(length) + uint64(overhead)
	if total > math.MaxUint32 || total > uint64(math.MaxInt-HeaderSize) {
		return 0, ErrInvalidLength
	}
	return uint32(total), nil
}
