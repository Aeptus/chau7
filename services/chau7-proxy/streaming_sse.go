package main

import "bytes"

// sseLineBuffer borrows complete lines from each upstream read. Only a line
// split across reads is copied. Large completed lines release their scratch
// storage so one provider event cannot pin it for the remaining stream.
// Consumers must not retain a borrowed line after returning.
type sseLineBuffer struct {
	pending []byte
}

func (b *sseLineBuffer) consume(chunk []byte, line func([]byte)) {
	for len(chunk) > 0 {
		newline := bytes.IndexByte(chunk, '\n')
		if newline < 0 {
			b.pending = append(b.pending, chunk...)
			return
		}
		if len(b.pending) == 0 {
			line(chunk[:newline])
		} else {
			b.pending = append(b.pending, chunk[:newline]...)
			line(b.pending)
			if cap(b.pending) > 64*1024 {
				b.pending = nil
			} else {
				b.pending = b.pending[:0]
			}
		}
		chunk = chunk[newline+1:]
	}
}

func sseData(line []byte) []byte {
	line = bytes.TrimSpace(line)
	if !bytes.HasPrefix(line, []byte("data:")) {
		return nil
	}
	data := bytes.TrimSpace(line[len("data:"):])
	if bytes.Equal(data, []byte("[DONE]")) {
		return nil
	}
	return data
}

// Usage metadata is projected while forwarding instead of keeping the entire
// response. Memory tracks the longest unfinished line, not total stream bytes.
// Individual events have no new size cap: large Responses completion envelopes
// can include their full output and authoritative usage in the same event.
type streamingMetadataObserver struct {
	provider   Provider
	lines      sseLineBuffer
	totalBytes int
	metadata   ResponseMetadata
}

func (o *streamingMetadataObserver) Write(chunk []byte) (int, error) {
	o.totalBytes += len(chunk)
	o.lines.consume(chunk, o.consumeLine)
	return len(chunk), nil
}

func (o *streamingMetadataObserver) consumeLine(line []byte) {
	if data := sseData(line); len(data) > 0 {
		mergeStreamingData(o.provider, data, &o.metadata)
	}
}

func (o *streamingMetadataObserver) finish() ResponseMetadata {
	if len(o.lines.pending) > 0 {
		o.consumeLine(o.lines.pending)
		o.lines.pending = nil
	}
	return o.metadata
}
