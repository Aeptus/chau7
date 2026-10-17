import { env } from 'cloudflare:workers';
import { afterEach, expect, it } from 'vitest';
import worker from '../../src/worker';
import { deriveRoleCredential } from '../../src/auth.js';
import { mintToken } from '../../src/token.js';
import {
  TYPE_VIEWER_DECISION,
  TYPE_VIEWER_JOIN,
  TYPE_VIEWER_OUTPUT,
  TYPE_VIEWER_SHARE,
  decodeFrame,
  encodeFrame,
  jsonFrame,
  toBytes
} from '../../src/viewer.js';

const openedSockets: WebSocket[] = [];
afterEach(() => {
  for (const socket of openedSockets.splice(0)) socket.close();
});

const decoder = new TextDecoder();

async function connectMac(device: string) {
  const root = JSON.parse(env.RELAY_AUTH_KEYS).current;
  const token = await mintToken({
    deviceId: device,
    role: 'mac',
    scope: 'connect',
    keyId: root.id,
    secret: await deriveRoleCredential(root.secret, root.id, device, 'mac')
  });
  const response = await worker.fetch(
    new Request(`https://relay.test/connect/${device}?role=mac`, {
      headers: { Upgrade: 'websocket', Authorization: `Bearer ${token}` }
    }),
    env
  );
  expect(response.status).toBe(101);
  return accept(response);
}

function accept(response: Response) {
  const socket = response.webSocket!;
  socket.accept();
  openedSockets.push(socket);
  const frames: { type: number; json: Record<string, unknown> | null; bytes: Uint8Array }[] = [];
  const waiters: (() => void)[] = [];
  socket.addEventListener('message', (event) => {
    const bytes = toBytes(event.data)!;
    const frame = decodeFrame(bytes)!;
    let json: Record<string, unknown> | null = null;
    try {
      json = JSON.parse(decoder.decode(frame.payload));
    } catch {
      json = null;
    }
    frames.push({ type: frame.type, json, bytes });
    waiters.splice(0).forEach((wake) => wake());
  });
  const next = async (count: number) => {
    const deadline = Date.now() + 5000;
    while (frames.length < count && Date.now() < deadline) {
      await new Promise<void>((resolve) => {
        waiters.push(resolve);
        setTimeout(resolve, 100);
      });
    }
    return frames[count - 1];
  };
  return { socket, frames, next };
}

function viewRequest(code: string, ip = '203.0.113.7') {
  return new Request(`https://relay.test/view/${code}`, {
    headers: { Upgrade: 'websocket', 'CF-Connecting-IP': ip }
  });
}

it('routes a viewer to the sharing Mac without exposing anything to the phone', async () => {
  const device = crypto.randomUUID();
  const code = crypto.randomUUID().replace(/-/g, '').slice(0, 8);
  expect((await worker.fetch(viewRequest(code), env)).status).toBe(404);

  const mac = await connectMac(device);
  mac.socket.send(jsonFrame(TYPE_VIEWER_SHARE, { share_code: code, max_viewers: 5 }));
  // The share is registered asynchronously by the Mac's DO.
  let response = await worker.fetch(viewRequest(code), env);
  for (let i = 0; i < 20 && response.status === 404; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    response = await worker.fetch(viewRequest(code), env);
  }
  expect(response.status).toBe(101);
  const viewer = accept(response);
  viewer.socket.send(
    jsonFrame(TYPE_VIEWER_JOIN, { viewer_id: 'v1', name: 'Reviewer', share_code: 'ignored' })
  );
  const join = await mac.next(1);
  expect(join.type).toBe(TYPE_VIEWER_JOIN);
  expect(join.json).toEqual({ viewer_id: 'v1', name: 'Reviewer', share_code: code });

  mac.socket.send(jsonFrame(TYPE_VIEWER_DECISION, { viewer_id: 'v1', approved: true }));
  expect((await viewer.next(1)).json).toMatchObject({ viewer_id: 'v1', approved: true });

  const id = new TextEncoder().encode('v1');
  const inner = encodeFrame(0x20, 'hello');
  const payload = new Uint8Array(1 + id.length + inner.length);
  payload[0] = id.length;
  payload.set(id, 1);
  payload.set(inner, 1 + id.length);
  mac.socket.send(encodeFrame(TYPE_VIEWER_OUTPUT, payload));
  expect((await viewer.next(2)).type).toBe(TYPE_VIEWER_OUTPUT);
});

it('rejects malformed share codes and an unknown code', async () => {
  expect((await worker.fetch(viewRequest('short'), env)).status).toBe(400);
  expect((await worker.fetch(viewRequest('zzzzzzz9', '203.0.113.8'), env)).status).toBe(404);
  const plain = new Request('https://relay.test/view/abcd1234');
  expect((await worker.fetch(plain, env)).status).toBe(426);
});

it('limits share code attempts per client IP', async () => {
  const ip = `198.51.100.${Math.floor(Math.random() * 200)}`;
  const statuses: number[] = [];
  for (let i = 0; i < 32; i += 1) {
    statuses.push((await worker.fetch(viewRequest('qqqqqqq1', ip), env)).status);
  }
  expect(statuses.slice(0, 30).every((status) => status === 404)).toBe(true);
  expect(statuses.slice(30)).toEqual([429, 429]);
});
