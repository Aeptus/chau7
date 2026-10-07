import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import worker from '../../src/worker';
import { mintToken } from '../../src/token.js';
import { deriveRoleCredential } from '../../src/auth.js';
import fixture from '../../../chau7-remote/docs/fixtures/pending_state.json';

async function request(device: string, body?: unknown) {
  const method = body === undefined ? 'GET' : 'POST';
  const role = method === 'GET' ? 'ios' : 'mac';
  const root = JSON.parse(env.RELAY_AUTH_KEYS).current;
  const bearer = await mintToken({
    deviceId: device,
    role,
    scope: 'pending',
    secret: await deriveRoleCredential(root.secret, root.id, device, role),
    keyId: root.id
  });
  return worker.fetch(
    new Request(`https://relay.test/pending/${device}`, {
      method,
      headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    }),
    env
  );
}

it('preserves the shared canonical fixture through authenticated sanitize/store/read', async () => {
  const device = crypto.randomUUID();
  expect((await request(device, fixture)).status).toBe(200);
  const response = await request(device);
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject(fixture);
});

it('rejects invalid ordering metadata without overwriting the last valid snapshot', async () => {
  const device = crypto.randomUUID();
  expect((await request(device, fixture)).status).toBe(200);
  for (const metadata of [
    { session_epoch: '', state_version: 43 },
    { session_epoch: 'x'.repeat(129), state_version: 43 },
    { session_epoch: 'epoch', state_version: -1 },
    { session_epoch: 'epoch', state_version: 1.5 },
    { session_epoch: 'epoch', state_version: Number.MAX_SAFE_INTEGER + 1 },
    { session_epoch: 'epoch', state_version: '43' },
    { session_epoch: 'epoch' },
    { state_version: 43 }
  ]) {
    const response = await request(device, { approvals: [], interactive_prompts: [], ...metadata });
    expect(response.status).toBe(400);
    await response.text();
  }
  expect(await (await request(device)).json()).toMatchObject(fixture);
});

it('accepts legacy snapshots and exact integer ordering boundaries', async () => {
  const device = crypto.randomUUID();
  expect((await request(device, { approvals: [], interactive_prompts: [] })).status).toBe(200);
  for (const state_version of [0, Number.MAX_SAFE_INTEGER]) {
    const response = await request(device, {
      approvals: [],
      interactive_prompts: [],
      session_epoch: 'epoch-1',
      state_version
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ session_epoch: 'epoch-1', state_version });
  }
});
