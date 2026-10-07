import test from 'node:test';
import assert from 'node:assert/strict';
import { bytesToBase64url, mintToken } from '../src/token.js';
import {
  deriveRoleCredential,
  isStrongRelayCredential,
  resolveAuthMode,
  verifyCredentialToken,
  isCredentialAdmissionAllowed
} from '../src/auth.js';
const now = 1_000_000;
const root = bytesToBase64url(Uint8Array.from({ length: 32 }, (_, i) => i + 1));
const current = { id: 'current', secret: root };
const environment = (keys = { current }) => ({ RELAY_AUTH_KEYS: JSON.stringify(keys) });
async function token(deviceId = 'device-A', role = 'mac', keyId = current.id, secret) {
  secret ??= await deriveRoleCredential(root, keyId, deviceId, role);
  return mintToken({ deviceId, role, keyId, secret, scope: 'pending' }, now);
}
const expected = { deviceId: 'device-A', role: 'mac', scope: 'pending' };

test('only canonical 256-bit values are accepted as credential material', () => {
  assert.equal(isStrongRelayCredential(root), true);
  for (const value of [
    '',
    'secret',
    'CHANGE_ME_IN_PRODUCTION',
    root + '=',
    root.slice(1),
    null,
    42
  ]) {
    assert.equal(isStrongRelayCredential(value), false);
  }
});
test('legacy global secrets and malformed keyrings fail closed', () => {
  for (const env of [
    undefined,
    { RELAY_SECRET: root },
    environment({ current: { id: 'x', secret: 'weak' } }),
    environment({ current: { id: 'bad.id', secret: root } }),
    { RELAY_AUTH_KEYS: '{' }
  ]) {
    assert.equal(resolveAuthMode(env, now).mode, 'misconfigured');
  }
});
test('open access requires the explicit development environment and cannot override malformed credentials', () => {
  assert.equal(resolveAuthMode({ RELAY_ALLOW_UNAUTHENTICATED: 'true' }, now).mode, 'misconfigured');
  assert.equal(
    resolveAuthMode({ ENVIRONMENT: 'production', RELAY_ALLOW_UNAUTHENTICATED: 'true' }, now).mode,
    'misconfigured'
  );
  assert.equal(
    resolveAuthMode({ ENVIRONMENT: 'development', RELAY_ALLOW_UNAUTHENTICATED: 'true' }, now).mode,
    'open'
  );
  assert.equal(
    resolveAuthMode(
      {
        ENVIRONMENT: 'development',
        RELAY_ALLOW_UNAUTHENTICATED: 'true',
        RELAY_AUTH_KEYS: 'invalid'
      },
      now
    ).mode,
    'misconfigured'
  );
});
test('accepts the current provisioned device and role credential', async () => {
  assert.equal((await verifyCredentialToken(await token(), expected, environment(), now)).ok, true);
});
test('device A credential cannot mint a token claiming device B', async () => {
  const secretA = await deriveRoleCredential(root, current.id, 'device-A', 'mac');
  const forged = await token('device-B', 'mac', current.id, secretA);
  assert.equal(
    (await verifyCredentialToken(forged, { ...expected, deviceId: 'device-B' }, environment(), now))
      .ok,
    false
  );
});
test('mac credential cannot mint an iOS role token', async () => {
  const mac = await deriveRoleCredential(root, current.id, 'device-A', 'mac');
  assert.equal(
    (
      await verifyCredentialToken(
        await token('device-A', 'ios', current.id, mac),
        { ...expected, role: 'ios' },
        environment(),
        now
      )
    ).ok,
    false
  );
});
test('key ID is included in both credential derivation and token authentication', async () => {
  const old = await token();
  assert.equal(
    (
      await verifyCredentialToken(
        old.replace('v3.current.', 'v3.other.'),
        expected,
        environment({ current: { id: 'other', secret: root } }),
        now
      )
    ).ok,
    false
  );
});
test('global v2 tokens are never admitted even when their HMAC is valid', async () => {
  const v2 = await mintToken({ ...expected, secret: root }, now);
  assert.equal((await verifyCredentialToken(v2, expected, environment(), now)).ok, false);
});
test('previous key reconnects only inside its bounded grace interval', async () => {
  const env = environment({
    current: { id: 'new', secret: root },
    previous: { ...current, grace_started_at: now - 10, accept_until: now + 60 }
  });
  assert.equal((await verifyCredentialToken(await token(), expected, env, now)).ok, true);
  assert.equal((await verifyCredentialToken(await token(), expected, env, now + 60)).ok, false);
});
test('invalid or unbounded grace fails the whole keyring closed', () => {
  for (const previous of [
    { ...current, grace_started_at: now, accept_until: now + 86401 },
    { ...current, grace_started_at: now + 1, accept_until: now + 60 },
    { ...current, grace_started_at: now, accept_until: now },
    { ...current, grace_started_at: now, accept_until: 'forever' }
  ]) {
    assert.equal(
      resolveAuthMode(environment({ current: { id: 'new', secret: root }, previous }), now).mode,
      'misconfigured'
    );
  }
});
test('revocation blocks current and previous credentials and existing socket metadata', async () => {
  const env = {
    ...environment({
      current: { id: 'new', secret: root },
      previous: { ...current, grace_started_at: now - 1, accept_until: now + 60 }
    }),
    RELAY_REVOKED_DEVICES: '["device-A"]'
  };
  for (const keyId of ['new', 'current']) {
    assert.equal(
      (await verifyCredentialToken(await token('device-A', 'mac', keyId), expected, env, now)).ok,
      false
    );
    assert.equal(
      isCredentialAdmissionAllowed(resolveAuthMode(env, now), 'device-A', keyId, 'mac', now),
      false
    );
  }
});
test('malformed revocation configuration fails closed instead of silently disabling it', () => {
  for (const value of ['{}', '[null]', '["bad:id"]', 'invalid'])
    assert.equal(
      resolveAuthMode({ ...environment(), RELAY_REVOKED_DEVICES: value }, now).mode,
      'misconfigured'
    );
});

// Public deterministic fixture shared with Go and Swift; never production keys.
test('v3 role derivation and token signatures match the shared language vector', async () => {
  const { readFile } = await import('node:fs/promises');
  const vector = JSON.parse(
    await readFile(
      new URL('../../chau7-remote/docs/fixtures/relay_credentials_v3.json', import.meta.url),
      'utf8'
    )
  );
  // Raw bytes are public known-answer vectors, not provisioned credentials.
  vector.root = Buffer.from(vector.root_bytes_hex, 'hex').toString('base64url');
  for (const role of ['mac', 'ios']) {
    vector[`${role}_secret`] = Buffer.from(vector[`${role}_bytes_hex`], 'hex').toString(
      'base64url'
    );
    const secret = await deriveRoleCredential(vector.root, vector.key_id, vector.device_id, role);
    assert.equal(secret, vector[`${role}_secret`]);
    const verified = await verifyCredentialToken(
      vector[`${role}_token`],
      { deviceId: vector.device_id, role, scope: vector.scope },
      { RELAY_AUTH_KEYS: JSON.stringify({ current: { id: vector.key_id, secret: vector.root } }) },
      Number(vector.timestamp)
    );
    assert.equal(verified.ok, true);
  }
});
