import { env } from 'cloudflare:workers';
import { runInDurableObject } from 'cloudflare:test';
import { expect, it } from 'vitest';
import worker from '../../src/worker';
import { bytesToBase64url, mintToken } from '../../src/token.js';

const empty = { approvals: [], interactive_prompts: [] };
function stub(device: string) {
  return env.SESSION.get(env.SESSION.idFromName(device));
}
async function token(device: string, role = 'mac', scope = 'pending') {
  return mintToken({ deviceId: device, role, scope, secret: env.RELAY_SECRET });
}
function pending(device: string, bearer: string, method = 'POST') {
  return new Request(`https://relay.test/pending/${device}`, {
    method,
    headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
    ...(method === 'POST' ? { body: JSON.stringify(empty) } : {})
  });
}
async function namedNonce(device: string, nonce: string) {
  const ts = Math.floor(Date.now() / 1000);
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(env.RELAY_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`v2:${device}:mac:pending:${ts}:${nonce}`)
  );
  return `v2.${ts}.${nonce}.pending.${bytesToBase64url(signature)}`;
}

it('round-trips pending state through authenticated routes and real storage', async () => {
  const device = crypto.randomUUID();
  const bearer = await token(device);
  expect((await worker.fetch(pending(device, bearer), env)).status).toBe(200);
  expect((await worker.fetch(pending(device, bearer), env)).status).toBe(409);
  const stored = await runInDurableObject(stub(device), async (_instance, state) =>
    state.storage.get('pending_state')
  );
  expect(stored).toMatchObject(empty);
  const read = await worker.fetch(pending(device, await token(device, 'ios'), 'GET'), env);
  expect(await read.json()).toMatchObject(empty);
});

it('admits only one concurrent request with the same authenticated nonce', async () => {
  const device = crypto.randomUUID();
  const bearer = await token(device);
  const responses = await Promise.all([
    worker.fetch(pending(device, bearer), env),
    worker.fetch(pending(device, bearer), env)
  ]);
  expect(responses.map((r) => r.status).sort()).toEqual([200, 409]);
});

it.each(['__proto__', 'constructor', 'toString'])(
  'enforces single-use for the accepted nonce %s',
  async (nonce) => {
    const device = crypto.randomUUID();
    const bearer = await namedNonce(device, nonce);
    expect((await worker.fetch(pending(device, bearer), env)).status).toBe(200);
    expect((await worker.fetch(pending(device, bearer), env)).status).toBe(409);
  }
);

it('never evicts an unexpired replay entry to admit another nonce', async () => {
  const device = crypto.randomUUID();
  const retained = await namedNonce(device, 'retained');
  await runInDurableObject(stub(device), async (_instance, state) => {
    const seen = Object.fromEntries(
      Array.from({ length: 1999 }, (_, i) => [`n${i}`, Date.now() + 150_000])
    );
    seen.retained = Date.now() + 120_000;
    await state.storage.put('seen_nonces', seen);
  });
  expect((await worker.fetch(pending(device, await token(device)), env)).status).toBe(429);
  expect((await worker.fetch(pending(device, retained), env)).status).toBe(409);
});

it('prunes expired entries before applying the replay budget', async () => {
  const device = crypto.randomUUID();
  await runInDurableObject(stub(device), async (_instance, state) => {
    await state.storage.put(
      'seen_nonces',
      Object.fromEntries(Array.from({ length: 2000 }, (_, i) => [`n${i}`, Date.now() - 1000]))
    );
  });
  expect((await worker.fetch(pending(device, await token(device)), env)).status).toBe(200);
  expect(
    await runInDurableObject(
      stub(device),
      async (_instance, state) =>
        Object.keys((await state.storage.get('seen_nonces')) as object).length
    )
  ).toBe(1);
});

it('rejects wrong role, scope, device, missing and expired credentials', async () => {
  const device = crypto.randomUUID();
  for (const bearer of [
    await token(device, 'ios'),
    await token(device, 'mac', 'push'),
    await token(crypto.randomUUID())
  ]) {
    expect((await worker.fetch(pending(device, bearer), env)).status).toBe(403);
  }
  expect((await worker.fetch(pending(device, await token(device), 'GET'), env)).status).toBe(403);
  expect(
    (await worker.fetch(new Request(`https://relay.test/pending/${device}`), env)).status
  ).toBe(401);
  const expired = await mintToken(
    { deviceId: device, role: 'mac', scope: 'pending', secret: env.RELAY_SECRET },
    Date.now() / 1000 - 121
  );
  expect((await worker.fetch(pending(device, expired), env)).status).toBe(403);
  expect(
    (await worker.fetch(pending(device, await token(device)), { ...env, RELAY_SECRET: undefined }))
      .status
  ).toBe(503);
});

it('persists and revokes a registration whose id is an object property name', async () => {
  const device = crypto.randomUUID();
  const register = async (authorized: boolean) =>
    worker.fetch(
      new Request(`https://relay.test/push/register/${device}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${await token(device, 'mac', 'push')}` },
        body: JSON.stringify({
          paired_device_id: '__proto__',
          notifications_authorized: authorized,
          push_token: 'test-token',
          push_topic: 'test.topic',
          push_environment: 'development'
        })
      }),
      env
    );
  expect((await register(true)).status).toBe(204);
  const stored = (await runInDurableObject(stub(device), async (_instance, state) =>
    state.storage.get('push_registrations')
  )) as object;
  expect(Object.hasOwn(stored, '__proto__')).toBe(true);
  expect((await register(false)).status).toBe(204);
  const revoked = (await runInDurableObject(stub(device), async (_instance, state) =>
    state.storage.get('push_registrations')
  )) as object;
  expect(revoked).toBeUndefined();
});

it('relays opaque WebSocket data and replaces only the reconnecting role', async () => {
  const device = crypto.randomUUID();
  const connect = async (role: string) => {
    const response = await worker.fetch(
      new Request(`https://relay.test/connect/${device}?role=${role}`, {
        headers: {
          Upgrade: 'websocket',
          Authorization: `Bearer ${await token(device, role, 'connect')}`
        }
      }),
      env
    );
    expect(response.status).toBe(101);
    const socket = response.webSocket!;
    socket.accept();
    return socket;
  };
  const mac = await connect('mac');
  const ios = await connect('ios');
  try {
    const message = new Promise<MessageEvent>((resolve) =>
      ios.addEventListener('message', resolve, { once: true })
    );
    mac.send('opaque encrypted payload');
    expect((await message).data).toBe('opaque encrypted payload');
    const closed = new Promise<CloseEvent>((resolve) =>
      mac.addEventListener('close', resolve, { once: true })
    );
    const nextMac = await connect('mac');
    try {
      expect((await closed).reason).toBe('Replaced by new connection');
      const nextMessage = new Promise<MessageEvent>((resolve) =>
        ios.addEventListener('message', resolve, { once: true })
      );
      nextMac.send('reconnected payload');
      expect((await nextMessage).data).toBe('reconnected payload');
    } finally {
      nextMac.close();
    }
  } finally {
    mac.close();
    ios.close();
  }
});

it('enforces single-use tokens on pending reads as well as writes', async () => {
  const device = crypto.randomUUID();
  const bearer = await token(device, 'ios');
  expect((await worker.fetch(pending(device, bearer, 'GET'), env)).status).toBe(200);
  expect((await worker.fetch(pending(device, bearer, 'GET'), env)).status).toBe(409);
});
