import { expect, it } from 'vitest';

// Workers versions differ in whether they expose bufferedAmount. The relay
// uses phone acknowledgements for backpressure in both cases: a local send
// queue cannot prove that the phone has received and processed the bytes.
it('accepts Workers WebSockets with or without bufferedAmount', () => {
  const pair = new WebSocketPair();
  const server = pair[1];
  server.accept();
  const chunk = new Uint8Array(512 * 1024);
  for (let i = 0; i < 16; i++) server.send(chunk);

  const bufferedAmount = (server as unknown as { bufferedAmount?: number }).bufferedAmount;
  if (bufferedAmount !== undefined) {
    expect(Number.isFinite(bufferedAmount)).toBe(true);
    expect(bufferedAmount).toBeGreaterThanOrEqual(0);
  }
});
