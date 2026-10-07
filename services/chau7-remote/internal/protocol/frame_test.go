package protocol

import (
	"errors"
	"math"
	"testing"
)

func TestPayloadLengthChecksBeforeNarrowing(t *testing.T) {
	for _, tc := range []struct {
		name             string
		length, overhead int
		want             uint32
		invalid          bool
	}{
		{name: "empty"},
		{name: "encryption overhead", length: 100, overhead: 16, want: 116},
		{name: "negative length", length: -1, invalid: true},
		{name: "negative overhead", overhead: -1, invalid: true},
		{name: "integer overflow", length: math.MaxInt, overhead: math.MaxInt, invalid: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := PayloadLength(tc.length, tc.overhead)
			if tc.invalid {
				if !errors.Is(err, ErrInvalidLength) {
					t.Fatalf("got %d, %v; want invalid length", got, err)
				}
				return
			}
			if err != nil || got != tc.want {
				t.Fatalf("got %d, %v; want %d", got, err, tc.want)
			}
		})
	}
	if uint64(math.MaxInt) > math.MaxUint32 {
		maximum := uint64(math.MaxUint32)
		if got, err := PayloadLength(int(maximum)-16, 16); err != nil || got != math.MaxUint32 {
			t.Fatalf("valid maximum = %d, %v", got, err)
		}
		if _, err := PayloadLength(int(maximum), 1); !errors.Is(err, ErrInvalidLength) {
			t.Fatalf("overflow accepted: %v", err)
		}
	}
}

func TestFrameRoundTripPreservesHeaderAndPayload(t *testing.T) {
	original := &Frame{Version: 1, Type: TypeOutput, TabID: 42, Seq: 7, Payload: []byte("terminal output")}
	decoded, err := DecodeFrame(original.Encode())
	if err != nil {
		t.Fatal(err)
	}
	if decoded.TabID != original.TabID || decoded.Seq != original.Seq || string(decoded.Payload) != string(original.Payload) {
		t.Fatalf("round trip changed frame: %#v", decoded)
	}
}
