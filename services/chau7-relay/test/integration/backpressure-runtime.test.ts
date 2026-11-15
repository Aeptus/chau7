import { expect, it } from 'vitest';

// session.ts sheds grid frames and closes slow receivers from a socket's
// `bufferedAmount`. The Workers runtime does not expose that property, so the
// relay reads 0 and its backpressure never engages. This test records that
// fact; if it starts failing, the runtime gained the property and the limits
// in src/backpressure.js became live and need a real load test.
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
