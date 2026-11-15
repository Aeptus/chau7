import { expect, it } from 'vitest';

// The Workers runtime does not expose a socket's `bufferedAmount`, so the relay
// cannot see its own send queue. session.ts therefore measures a phone falling
// behind from the phone's acknowledgements (RELAY_ACK, src/backpressure.js).
// This test records the runtime fact; if it starts failing, the runtime gained
// the property and the relay could measure its queue directly.
it('the Workers runtime does not report bytes queued on a WebSocket', () => {
  const pair = new WebSocketPair();
  const server = pair[1];
  server.accept();
  // The other end is never accepted or read, so these 8 MiB can only queue.
  const chunk = new Uint8Array(512 * 1024);
  for (let i = 0; i < 16; i++) server.send(chunk);

  expect('bufferedAmount' in server).toBe(false);
  expect((server as unknown as { bufferedAmount?: number }).bufferedAmount).toBeUndefined();
});
