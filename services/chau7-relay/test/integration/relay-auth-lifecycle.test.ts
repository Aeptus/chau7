import { env } from 'cloudflare:workers';
import { runInDurableObject } from 'cloudflare:test';
import { afterEach, expect, it } from 'vitest';
import worker from '../../src/worker';
import { deriveRoleCredential } from '../../src/auth.js';
import { bytesToBase64url, mintToken } from '../../src/token.js';

const initialKeys = env.RELAY_AUTH_KEYS;
const openedSockets: WebSocket[] = [];
// Test bindings are shared by the runtime isolate; storage isolation alone
// does not reset simulated deployment changes. Restore even on assertion failure.
afterEach(() => {
  for (const socket of openedSockets.splice(0)) socket.close();
  env.RELAY_AUTH_KEYS = initialKeys;
  delete env.RELAY_REVOKED_DEVICES;
});

const current = () => JSON.parse(env.RELAY_AUTH_KEYS).current;
const next = () => ({ id: 'next-key', secret: bytesToBase64url(new Uint8Array(32).fill(2)) });
type Root = { id: string; secret: string };
async function bearer(device: string, role: string, root: Root = current(), scope = 'connect') {
  return mintToken({
    deviceId: device,
    role,
    scope,
    keyId: root.id,
    secret: await deriveRoleCredential(root.secret, root.id, device, role)
  });
}
function connectRequest(device: string, role: string, token: string) {
  return new Request(`https://relay.test/connect/${device}?role=${role}`, {
    headers: { Upgrade: 'websocket', Authorization: `Bearer ${token}` }
  });
}
async function connect(device: string, role: string, root: Root = current(), policy = env) {
  const response = await worker.fetch(
    connectRequest(device, role, await bearer(device, role, root)),
    policy
  );
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  socket.accept();
  openedSockets.push(socket);
  return socket;
}
function stub(device: string) {
  return env.SESSION.get(env.SESSION.idFromName(device));
}
// Change only this real DO's ephemeral test bindings, representing a deployment
// policy transition. Public routes, attached sockets and forwarding remain real.
async function policyForSession(device: string, keys: string, revoked?: string) {
  await runInDurableObject(stub(device), async (instance) => {
    const bindings = (
      instance as unknown as { env: { RELAY_AUTH_KEYS: string; RELAY_REVOKED_DEVICES?: string } }
    ).env;
    bindings.RELAY_AUTH_KEYS = keys;
    if (revoked === undefined) delete bindings.RELAY_REVOKED_DEVICES;
    else bindings.RELAY_REVOKED_DEVICES = revoked;
  });
}
function closeEvent(socket: WebSocket) {
  return new Promise<CloseEvent>((resolve) =>
    socket.addEventListener('close', resolve, { once: true })
  );
}

it('a device credential cannot forge another device or the other role at real admission', async () => {
  const source = crypto.randomUUID();
  const target = crypto.randomUUID();
  const root = current();
  const secret = await deriveRoleCredential(root.secret, root.id, source, 'ios');
  for (const [device, role] of [
    [target, 'ios'],
    [source, 'mac']
  ]) {
    const forged = await mintToken({
      deviceId: device,
      role,
      scope: 'connect',
      keyId: root.id,
      secret
    });
    expect((await worker.fetch(connectRequest(device, role, forged), env)).status).toBe(403);
  }
});

it('real admission rejects unknown key IDs, legacy tokens and revoked devices', async () => {
  const device = crypto.randomUUID();
  const root = current();
  const secret = await deriveRoleCredential(root.secret, root.id, device, 'mac');
  for (const keyId of [undefined, 'unknown-key']) {
    const token = await mintToken({
      deviceId: device,
      role: 'mac',
      scope: 'connect',
      secret,
      keyId
    });
    expect((await worker.fetch(connectRequest(device, 'mac', token), env)).status).toBe(403);
  }
  const token = await bearer(device, 'mac');
  expect(
    (
      await worker.fetch(connectRequest(device, 'mac', token), {
        ...env,
        RELAY_REVOKED_DEVICES: JSON.stringify([device])
      })
    ).status
  ).toBe(403);
});

it('previous key reconnects work only inside a bounded grace period', async () => {
  const original = env.RELAY_AUTH_KEYS;
  const device = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1000);
  const previous = { ...current(), grace_started_at: now - 10, accept_until: now + 60 };
  const keys = JSON.stringify({ current: next(), previous });
  const policy = { ...env, RELAY_AUTH_KEYS: keys };
  await policyForSession(device, keys);
  const socket = await connect(device, 'ios', previous, policy);
  socket.close();
  const expired = { ...previous, accept_until: now - 1 };
  expect(
    (
      await worker.fetch(connectRequest(device, 'ios', await bearer(device, 'ios', previous)), {
        ...env,
        RELAY_AUTH_KEYS: JSON.stringify({ current: next(), previous: expired })
      })
    ).status
  ).toBe(403);
  const unbounded = { ...previous, accept_until: previous.grace_started_at + 86401 };
  expect(
    (
      await worker.fetch(connectRequest(device, 'ios', await bearer(device, 'ios', previous)), {
        ...env,
        RELAY_AUTH_KEYS: JSON.stringify({ current: next(), previous: unbounded })
      })
    ).status
  ).toBe(503);
  await policyForSession(device, original);
});

it('an existing revoked sender closes before any opaque payload is forwarded', async () => {
  const device = crypto.randomUUID();
  const keys = env.RELAY_AUTH_KEYS;
  const mac = await connect(device, 'mac');
  const ios = await connect(device, 'ios');
  let received = 0;
  ios.addEventListener('message', () => {
    received++;
  });
  try {
    await policyForSession(device, keys, JSON.stringify([device]));
    const closed = closeEvent(mac);
    mac.send('must not be delivered');
    expect((await closed).code).toBe(1008);
    expect(received).toBe(0);
  } finally {
    mac.close();
    ios.close();
    await policyForSession(device, keys);
  }
});

it('an existing expired-key receiver closes before delivery from a current-key sender', async () => {
  const device = crypto.randomUUID();
  const original = env.RELAY_AUTH_KEYS;
  const now = Math.floor(Date.now() / 1000);
  const previous = { ...current(), grace_started_at: now - 10, accept_until: now + 60 };
  const keys = JSON.stringify({ current: next(), previous });
  const policy = { ...env, RELAY_AUTH_KEYS: keys };
  await policyForSession(device, keys);
  const ios = await connect(device, 'ios', previous, policy);
  const mac = await connect(device, 'mac', next(), policy);
  let received = 0;
  ios.addEventListener('message', () => {
    received++;
  });
  try {
    await policyForSession(
      device,
      JSON.stringify({ current: next(), previous: { ...previous, accept_until: now - 1 } })
    );
    const closed = closeEvent(ios);
    mac.send('must not reach expired receiver');
    expect((await closed).code).toBe(1008);
    expect(received).toBe(0);
  } finally {
    mac.close();
    ios.close();
    await policyForSession(device, original);
  }
});

it('legacy hibernation attachments fail closed instead of surviving a v3 migration', async () => {
  const device = crypto.randomUUID();
  const mac = await connect(device, 'mac');
  const ios = await connect(device, 'ios');
  try {
    await runInDurableObject(stub(device), async (_instance, state) => {
      for (const socket of state.getWebSockets('mac')) socket.serializeAttachment({ role: 'mac' });
    });
    const closed = closeEvent(mac);
    mac.send('legacy metadata must not authorize forwarding');
    expect((await closed).code).toBe(1008);
  } finally {
    mac.close();
    ios.close();
  }
});
