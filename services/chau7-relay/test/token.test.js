import assert from 'node:assert/strict';
import test from 'node:test';
import {
  mintToken,
  verifyToken,
  parseToken,
  base64urlToBytes,
  bytesToBase64url,
  TOKEN_TTL_SECONDS,
  TOKEN_FUTURE_SKEW_SECONDS
} from '../src/token.js';

const HMAC_KEY = 'unit-test-hmac-key-0001';
const DEVICE = '11111111-2222-3333-4444-555555555555';
const NOW = 1_700_000_000;

test('round-trips base64url', () => {
  const bytes = new Uint8Array([0, 1, 2, 250, 251, 252, 253, 254, 255]);
  assert.deepEqual(base64urlToBytes(bytesToBase64url(bytes)), bytes);
});

test('rejects invalid base64url', () => {
  assert.throws(() => base64urlToBytes('not+valid/base64'));
  assert.throws(() => base64urlToBytes('has=padding'));
});

test('accepts a freshly minted, correctly-scoped token', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  const result = await verifyToken(
    token,
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  assert.equal(result.ok, true);
  assert.ok(result.nonce);
  assert.equal(result.expiresAt, (NOW + TOKEN_TTL_SECONDS) * 1000);
});

test('rejects a token used for the wrong scope', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  const result = await verifyToken(
    token,
    { deviceId: DEVICE, role: 'mac', scope: 'push', secret: HMAC_KEY },
    NOW
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'scope_mismatch');
});

test('rejects a token used for the wrong role', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'ios', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  const result = await verifyToken(
    token,
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'bad_signature');
});

test('rejects a token used for a different device', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  const result = await verifyToken(
    token,
    { deviceId: 'other-device', role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'bad_signature');
});

test('rejects a token signed with the wrong secret', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  const result = await verifyToken(
    token,
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: 'wrong-secret' },
    NOW
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'bad_signature');
});

test('rejects an expired token', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  const later = NOW + TOKEN_TTL_SECONDS + 1;
  const result = await verifyToken(
    token,
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    later
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'expired');
});

test('rejects a token from too far in the future', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW + TOKEN_FUTURE_SKEW_SECONDS + 5
  );
  const result = await verifyToken(
    token,
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'future');
});

test('accepts a token within clock skew', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW + TOKEN_FUTURE_SKEW_SECONDS - 1
  );
  const result = await verifyToken(
    token,
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  assert.equal(result.ok, true);
});

test('rejects malformed tokens', async () => {
  for (const bad of ['', 'garbage', 'v1.1.a.connect.sig', 'v2.x.n.connect.sig', 'v2.1.n.connect']) {
    const result = await verifyToken(
      bad,
      { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
      NOW
    );
    assert.equal(result.ok, false, `expected rejection for: ${bad}`);
  }
});

test('rejects a tampered signature', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  const tampered = token.slice(0, -2) + (token.endsWith('A') ? 'BB' : 'AA');
  const result = await verifyToken(
    tampered,
    { deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY },
    NOW
  );
  assert.equal(result.ok, false);
});

test('parseToken extracts structure or returns null', async () => {
  const token = await mintToken(
    { deviceId: DEVICE, role: 'mac', scope: 'pending', secret: HMAC_KEY },
    NOW
  );
  const parsed = parseToken(token);
  assert.equal(parsed.ts, NOW);
  assert.equal(parsed.scope, 'pending');
  assert.ok(parsed.nonce);
  assert.equal(parseToken('nope'), null);
});

test('nonces differ between mints', async () => {
  const a = parseToken(
    await mintToken({ deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY }, NOW)
  );
  const b = parseToken(
    await mintToken({ deviceId: DEVICE, role: 'mac', scope: 'connect', secret: HMAC_KEY }, NOW)
  );
  assert.notEqual(a.nonce, b.nonce);
});
