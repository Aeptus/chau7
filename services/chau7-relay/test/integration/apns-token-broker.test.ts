import { env } from 'cloudflare:workers';
import { evictDurableObject, runInDurableObject } from 'cloudflare:test';
import { afterEach, expect, it, vi } from 'vitest';
import { APNSTokenBrokerDO } from '../../src/apns-token-broker';

function broker() {
  return env.APNS_TOKEN_BROKER.get(env.APNS_TOKEN_BROKER.idFromName(crypto.randomUUID()));
}
function request(path = 'token') {
  return new Request(`https://broker.test/${path}`, { method: 'POST' });
}
afterEach(() => vi.restoreAllMocks());

it('mints a valid test-only provider JWT and reuses persistent storage after eviction', async () => {
  const stub = broker();
  const first = (await (await stub.fetch(request())).json()) as { token: string; source: string };
  expect(first.source).toBe('minted');
  const [header, claims, signature] = first.token.split('.');
  const decode = (s: string) =>
    Uint8Array.from(
      atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)),
      (c) => c.charCodeAt(0)
    );
  expect(JSON.parse(new TextDecoder().decode(decode(header)))).toMatchObject({
    alg: 'ES256',
    kid: 'TEST_KEY'
  });
  expect(JSON.parse(new TextDecoder().decode(decode(claims)))).toMatchObject({ iss: 'TEST_TEAM' });
  const pem = env.TEST_APNS_PUBLIC_KEY.replace(/-----[^\n]+-----|\s/g, '');
  const key = await crypto.subtle.importKey(
    'spki',
    Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify']
  );
  expect(
    await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      decode(signature),
      new TextEncoder().encode(`${header}.${claims}`)
    )
  ).toBe(true);
  expect(((await (await stub.fetch(request())).json()) as { source: string }).source).toBe(
    'memory'
  );
  await evictDurableObject(stub);
  const restored = (await (await stub.fetch(request())).json()) as {
    token: string;
    source: string;
  };
  expect(restored).toMatchObject({ token: first.token, source: 'storage' });
});

it('coalesces simultaneous cold requests into one provider-token mint', async () => {
  const stub = broker();
  const sign = crypto.subtle.sign.bind(crypto.subtle);
  const spy = vi.spyOn(crypto.subtle, 'sign').mockImplementation(async (...args) => {
    await new Promise((resolve) => setTimeout(resolve, 10));
    return sign(...args);
  });
  const responses = await Promise.all(Array.from({ length: 6 }, () => stub.fetch(request())));
  const payloads = await Promise.all(responses.map((r) => r.json() as Promise<{ token: string }>));
  expect(new Set(payloads.map((p) => p.token)).size).toBe(1);
  expect(spy).toHaveBeenCalledTimes(1);
});

it('persists provider backoff across eviction and permits reuse after expiry', async () => {
  const stub = broker();
  const ready = await stub.fetch(request());
  expect(ready.status).toBe(200);
  await ready.json();
  const backoff = await stub.fetch(request('provider-update-rate-limited'));
  expect(backoff.status).toBe(200);
  await backoff.json();
  await evictDurableObject(stub);
  const deferred = await stub.fetch(request());
  expect(deferred.status).toBe(503);
  expect(Number(deferred.headers.get('Retry-After'))).toBeGreaterThan(0);
  await deferred.json();
  await runInDurableObject(stub, async (_instance, state) =>
    state.storage.put('provider-token-backoff-until', Date.now() - 1)
  );
  expect((await stub.fetch(request())).status).toBe(200);
});

it('fails closed with missing signing configuration', async () => {
  const response = await runInDurableObject(broker(), async (_instance, state) =>
    new APNSTokenBrokerDO(state, {}).fetch(request())
  );
  expect(response.status).toBe(503);
  expect(await response.json()).toMatchObject({ error: 'apns_not_configured' });
});

it('clears failed in-flight minting so a later request can recover', async () => {
  const stub = broker();
  const sign = crypto.subtle.sign.bind(crypto.subtle);
  const spy = vi
    .spyOn(crypto.subtle, 'sign')
    .mockImplementationOnce(async () => {
      throw new Error('transient signing failure');
    })
    .mockImplementation(sign);
  // Failure recovery is sequential: requests dispatched together are not
  // guaranteed to enter the DO before the failed resolution retires.
  const failed = await stub.fetch(request());
  expect(failed.status).toBe(503);
  await failed.json();
  const recovered = await stub.fetch(request());
  expect(recovered.status).toBe(200);
  await recovered.json();
  expect(spy).toHaveBeenCalledTimes(2);
});
