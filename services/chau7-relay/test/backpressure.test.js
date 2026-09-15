import assert from 'node:assert/strict';
import test from 'node:test';
import {
  BACKPRESSURE_HARD_BYTES,
  BACKPRESSURE_SOFT_BYTES,
  relayBackpressureAction
} from '../src/backpressure.js';

function frame(type) {
  const bytes = new Uint8Array(20);
  bytes[0] = 1;
  bytes[1] = type;
  return bytes.buffer;
}

test('soft backpressure sheds only replaceable grid snapshots', () => {
  const buffered = BACKPRESSURE_SOFT_BYTES + 1;
  assert.equal(relayBackpressureAction(buffered, frame(0x23)), 'drop-grid');
  assert.equal(relayBackpressureAction(buffered, frame(0x20)), 'send');
  assert.equal(relayBackpressureAction(buffered, frame(0x50)), 'send');
});

test('hard backpressure closes regardless of frame type', () => {
  const buffered = BACKPRESSURE_HARD_BYTES + 1;
  assert.equal(relayBackpressureAction(buffered, frame(0x23)), 'close');
  assert.equal(relayBackpressureAction(buffered, frame(0x20)), 'close');
});
