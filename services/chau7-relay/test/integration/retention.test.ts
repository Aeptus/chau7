import { env } from 'cloudflare:workers';
import { runInDurableObject, runDurableObjectAlarm } from 'cloudflare:test';
import { expect, it } from 'vitest';
import worker from '../../src/worker';
import { mintToken } from '../../src/token.js';
import { deriveRoleCredential } from '../../src/auth.js';
import { PENDING_RETENTION_MS, REGISTRATION_RETENTION_MS } from '../../src/session';

const empty = { approvals: [], interactive_prompts: [] };
function stub(device: string) {
  return env.SESSION.get(env.SESSION.idFromName(device));
}
async function request(
  device: string,
  method: string,
  body?: unknown,
  role = method === 'GET' ? 'ios' : 'mac'
) {
  const root = JSON.parse(env.RELAY_AUTH_KEYS).current;
  const token = await mintToken({
    deviceId: device,
    role,
    scope: 'pending',
    secret: await deriveRoleCredential(root.secret, root.id, device, role),
    keyId: root.id
  });
  return new Request(`https://relay.test/pending/${device}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });
}

it('deletes an expired snapshot before returning a stale GET', async () => {
  const device = crypto.randomUUID();
  await runInDurableObject(stub(device), async (_, state) => {
    await state.storage.put('pending_state', {
      approvals: [{ command: 'sensitive' }],
      interactive_prompts: [],
      updated_at: new Date(Date.now() - PENDING_RETENTION_MS - 1).toISOString()
    });
  });
  const response = await worker.fetch(await request(device, 'GET'), env);
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ ...empty, updated_at: new Date(0).toISOString() });
  expect(
    await runInDurableObject(stub(device), async (_, state) => state.storage.get('pending_state'))
  ).toBeUndefined();
});

it('treats legacy missing or malformed retention timestamps as expired', async () => {
  for (const updated_at of [undefined, 'invalid']) {
    const device = crypto.randomUUID();
    await runInDurableObject(stub(device), async (_, state) => {
      await state.storage.put('pending_state', {
        ...empty,
        approvals: [{ command: 'old' }],
        updated_at
      });
    });
    const response = await worker.fetch(await request(device, 'GET'), env);
    expect(await response.json()).toMatchObject(empty);
  }
});

it('runs idle cleanup and retains the next live registration alarm', async () => {
  const device = crypto.randomUUID();
  const future = Date.now() + 20_000;
  await runInDurableObject(stub(device), async (_, state) => {
    await state.storage.put('pending_state', {
      ...empty,
      updated_at: new Date(Date.now() - PENDING_RETENTION_MS - 1).toISOString()
    });
    await state.storage.put('push_registrations', {
      expired: { updatedAt: new Date(Date.now() - REGISTRATION_RETENTION_MS - 1).toISOString() },
      live: { updatedAt: new Date(future - REGISTRATION_RETENTION_MS).toISOString() }
    });
    await state.storage.put('seen_nonces', { old: Date.now() - 2000 });
    await state.storage.setAlarm(Date.now() + 60_000);
  });
  expect(await runDurableObjectAlarm(stub(device))).toBe(true);
  await runInDurableObject(stub(device), async (_, state) => {
    expect(await state.storage.get('pending_state')).toBeUndefined();
    expect(await state.storage.get('seen_nonces')).toBeUndefined();
    expect(Object.keys((await state.storage.get('push_registrations')) as object)).toEqual([
      'live'
    ]);
    expect(await state.storage.getAlarm()).toBe(future);
  });
});

it('preserves replay entries through their final accepted second', async () => {
  const device = crypto.randomUUID();
  await runInDurableObject(stub(device), async (instance, state) => {
    const now = Date.now();
    const originalNow = Date.now;
    Date.now = () => now;
    try {
      await state.storage.put('seen_nonces', { retained: now - 500, expired: now - 2000 });
      // Pin the verification boundary while executing the real cleanup handler;
      // slow storage or CI scheduling must not consume the remaining 500 ms.
      if (!instance.alarm) throw new Error('Expected SessionDO alarm handler');
      await instance.alarm();
      expect(Object.keys((await state.storage.get('seen_nonces')) as object)).toEqual(['retained']);
      expect(await state.storage.getAlarm()).toBe(now + 500);
    } finally {
      Date.now = originalNow;
    }
  });
});

it('deletes pending state explicitly without deleting replay protection', async () => {
  const device = crypto.randomUUID();
  expect((await worker.fetch(await request(device, 'POST', empty), env)).status).toBe(200);
  const deletion = await request(device, 'DELETE');
  expect((await worker.fetch(deletion.clone(), env)).status).toBe(204);
  expect((await worker.fetch(deletion, env)).status).toBe(409);
  await runInDurableObject(stub(device), async (_, state) => {
    expect(await state.storage.get('pending_state')).toBeUndefined();
    expect(Object.keys((await state.storage.get('seen_nonces')) as object)).toHaveLength(2);
  });
});

it('denies deletion by the read-only iOS role', async () => {
  const device = crypto.randomUUID();
  expect((await worker.fetch(await request(device, 'POST', empty), env)).status).toBe(200);
  expect((await worker.fetch(await request(device, 'DELETE', undefined, 'ios'), env)).status).toBe(
    403
  );
  expect(
    await runInDurableObject(stub(device), async (_, state) => state.storage.get('pending_state'))
  ).toMatchObject(empty);
});

it('expires registrations before notifying', async () => {
  const device = crypto.randomUUID();
  await runInDurableObject(stub(device), async (_, state) => {
    await state.storage.put('push_registrations', {
      expired: {
        notificationsAuthorized: true,
        pushToken: 'token',
        pushTopic: 'topic',
        updatedAt: new Date(Date.now() - REGISTRATION_RETENTION_MS - 1).toISOString()
      }
    });
  });
  const root = JSON.parse(env.RELAY_AUTH_KEYS).current;
  const token = await mintToken({
    deviceId: device,
    role: 'mac',
    scope: 'push',
    secret: await deriveRoleCredential(root.secret, root.id, device, 'mac'),
    keyId: root.id
  });
  const response = await worker.fetch(
    new Request(`https://relay.test/push/notify/${device}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ kind: 'approval', title: 'title', body: 'body' })
    }),
    env
  );
  expect(response.status).toBe(204);
  expect(
    await runInDurableObject(stub(device), async (_, state) =>
      state.storage.get('push_registrations')
    )
  ).toBeUndefined();
});

it('removes the alarm after the last retained record expires', async () => {
  const device = crypto.randomUUID();
  await runInDurableObject(stub(device), async (_, state) => {
    await state.storage.put('seen_nonces', { old: Date.now() - 2000 });
    await state.storage.setAlarm(Date.now() + 60_000);
  });
  await runDurableObjectAlarm(stub(device));
  expect(
    await runInDurableObject(stub(device), async (_, state) => state.storage.getAlarm())
  ).toBeNull();
});

it.each(['refresh', 'revoke', 'unchanged'])(
  'applies late APNs feedback only to the failed registration: %s',
  async (action) => {
    const device = crypto.randomUUID();
    await runInDurableObject(stub(device), async (instance, state) => {
      const registration = {
        paired_device_id: 'phone',
        notifications_authorized: true,
        push_token: 'same-token',
        push_topic: 'test.topic',
        push_environment: 'development'
      };
      const pushRequest = async (route: string, body: unknown) => {
        const root = JSON.parse(env.RELAY_AUTH_KEYS).current;
        const token = await mintToken({
          deviceId: device,
          role: 'mac',
          scope: 'push',
          secret: await deriveRoleCredential(root.secret, root.id, device, 'mac'),
          keyId: root.id
        });
        return new Request(`https://relay.test/push/${route}/${device}`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${token}` },
          body: JSON.stringify(body)
        });
      };
      expect((await instance.fetch(await pushRequest('register', registration))).status).toBe(204);
      let release!: () => void;
      let started!: () => void;
      const ready = new Promise<void>((resolve) => {
        started = resolve;
      });
      const finish = new Promise<void>((resolve) => {
        release = resolve;
      });
      const original = Object.getOwnPropertyDescriptor(instance, 'sendAPNSNotification');
      Object.defineProperty(instance, 'sendAPNSNotification', {
        configurable: true,
        value: async () => {
          started();
          await finish;
          return { status: 410, reason: 'Unregistered' };
        }
      });
      try {
        const notification = instance.fetch(
          await pushRequest('notify', { kind: 'approval', title: 'title', body: 'body' })
        );
        await ready;
        if (action !== 'unchanged') {
          expect(
            (
              await instance.fetch(
                await pushRequest('register', {
                  ...registration,
                  notifications_authorized: action === 'refresh'
                })
              )
            ).status
          ).toBe(204);
        }
        release();
        expect((await notification).status).toBe(502);
        const saved = await state.storage.get<Record<string, unknown>>('push_registrations');
        if (action === 'refresh') expect(saved?.phone).toMatchObject({ pushToken: 'same-token' });
        else expect(saved).toBeUndefined();
      } finally {
        release();
        if (original) Object.defineProperty(instance, 'sendAPNSNotification', original);
        else Reflect.deleteProperty(instance, 'sendAPNSNotification');
      }
    });
  }
);
