package protocol

import (
	"encoding/binary"
	"errors"
)

const (
	HeaderSize   = 20
	FlagEncrypted = 0x01
)

const (
	TypeHello        = 0x01
	TypePairRequest  = 0x02
	TypePairAccept   = 0x03
	TypePairReject   = 0x04
	TypeSessionReady = 0x05
	TypeTabList      = 0x10
	TypeTabSwitch    = 0x11
	TypeOutput       = 0x20
	TypeInput        = 0x21
	TypeSnapshot     = 0x22
	TypePing         = 0x30
	TypePong         = 0x31
	TypePairingInfo  = 0x40
	TypeSessionStatus = 0x41
	TypeError        = 0x7F
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
	payloadLen := uint32(len(f.Payload))
	data := make([]byte, HeaderSize+payloadLen)
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

func DecodeFrame(data []byte) (*Frame, error) {
	if len(data) < HeaderSize {
		return nil, ErrInsufficientData
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
