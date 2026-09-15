import assert from 'node:assert/strict';
import test from 'node:test';
import {
  shouldRemoveRegistration,
  parseApnsReason,
  buildApnsPayload,
  apnsCollapseID,
  REMOVABLE_REASONS,
  resolveAPNSToken,
  isAPNSTokenUsable,
  APNS_TOKEN_TTL_MS,
  APNS_PROVIDER_UPDATE_BACKOFF_MS,
  nextAPNSProviderBackoffUntil
} from '../src/apns.js';

test('410 always removes the registration', () => {
  assert.equal(shouldRemoveRegistration(410, undefined), true);
  assert.equal(shouldRemoveRegistration(410, 'Unregistered'), true);
});

test('400 removes only for token-invalid reasons', () => {
  assert.equal(shouldRemoveRegistration(400, 'BadDeviceToken'), true);
  assert.equal(shouldRemoveRegistration(400, 'DeviceTokenNotForTopic'), true);
  for (const reason of REMOVABLE_REASONS) {
    assert.equal(shouldRemoveRegistration(400, reason), true);
  }
});

test('400 does NOT remove for transient/caller errors (the DoS fix)', () => {
  assert.equal(shouldRemoveRegistration(400, 'PayloadTooLarge'), false);
  assert.equal(shouldRemoveRegistration(400, 'BadMessageId'), false);
  assert.equal(shouldRemoveRegistration(400, undefined), false);
});

test('other statuses never remove', () => {
  assert.equal(shouldRemoveRegistration(429, 'TooManyRequests'), false);
  assert.equal(shouldRemoveRegistration(403, 'BadCertificate'), false);
  assert.equal(shouldRemoveRegistration(500, 'InternalServerError'), false);
  assert.equal(shouldRemoveRegistration(200, undefined), false);
});

test('parseApnsReason extracts the reason field', () => {
  assert.equal(parseApnsReason('{"reason":"BadDeviceToken"}'), 'BadDeviceToken');
  assert.equal(parseApnsReason(''), undefined);
  assert.equal(parseApnsReason('not json'), undefined);
  assert.equal(parseApnsReason('{"foo":"bar"}'), undefined);
});

test('buildApnsPayload is an alert push without the silent-push flag', () => {
  const payload = buildApnsPayload({
    kind: 'approval',
    title: 'Approve?',
    body: 'Run tests',
    request_id: 'r1'
  });
  assert.equal(payload.aps.alert.title, 'Approve?');
  assert.equal(payload.aps.alert.body, 'Run tests');
  assert.equal(payload.aps['interruption-level'], 'time-sensitive');
  assert.equal('content-available' in payload.aps, false);
  assert.equal(payload.request_id, 'r1');
  assert.equal(payload.open_approvals, true);
});

test('approval pushes carry the iOS approval category for lock-screen actions', () => {
  const payload = buildApnsPayload({
    kind: 'approval',
    title: 'Approval needed',
    body: 'git push --force',
    request_id: 'req-1'
  });
  assert.equal(payload.aps.category, 'MCP_APPROVAL');
});

test('interactive prompts carry the prompt category; other kinds carry none', () => {
  const prompt = buildApnsPayload({
    kind: 'interactive_prompt',
    title: 't',
    body: 'b',
    prompt_id: 'p1'
  });
  assert.equal(prompt.aps.category, 'INTERACTIVE_PROMPT');
  const finished = buildApnsPayload({ kind: 'task_finished', title: 't', body: 'b' });
  assert.equal(finished.aps.category, undefined);
});

test('collapse id prefers request over prompt over identity, capped at 64 bytes', () => {
  assert.equal(apnsCollapseID({ request_id: 'r', prompt_id: 'p' }), 'r');
  assert.equal(apnsCollapseID({ prompt_id: 'p' }), 'p');
  assert.equal(apnsCollapseID({ identity_key: 'x'.repeat(100) }), 'x'.repeat(64));
  assert.equal(apnsCollapseID({}), undefined);
});

// --- APNs provider token caching -------------------------------------------
// The bug: the token lived only in Durable Object memory. DOs are evicted when
// idle and pushes arrive in sparse bursts, so the refresh interval never
// elapsed in memory — APNs saw a mint per burst and replied
// TooManyProviderTokenUpdates / 502, dropping the notification.

test('a live in-memory token is reused without touching storage or minting', async () => {
  let reads = 0;
  let mints = 0;
  const now = 1_000_000;

  const result = await resolveAPNSToken({
    memory: { token: 'live', expiresAt: now + 60_000 },
    readStored: async () => {
      reads++;
      return undefined;
    },
    writeStored: async () => {},
    mint: async () => {
      mints++;
      return 'fresh';
    },
    now
  });

  assert.equal(result.token, 'live');
  assert.equal(result.source, 'memory');
  assert.equal(reads, 0);
  assert.equal(mints, 0);
});

test('after eviction the persisted token is reused instead of minting', async () => {
  let mints = 0;
  const now = 1_000_000;

  // memory undefined models a freshly constructed DO after eviction.
  const result = await resolveAPNSToken({
    memory: undefined,
    readStored: async () => ({ token: 'persisted', expiresAt: now + 60_000 }),
    writeStored: async () => {
      throw new Error('must not rewrite a still-valid token');
    },
    mint: async () => {
      mints++;
      return 'fresh';
    },
    now
  });

  assert.equal(result.token, 'persisted');
  assert.equal(result.source, 'storage');
  assert.equal(mints, 0, 'evicted instance must not mint a new provider token');
});

test('an expired persisted token is refreshed and written back', async () => {
  const now = 1_000_000;
  let written;

  const result = await resolveAPNSToken({
    memory: { token: 'stale-memory', expiresAt: now - 1 },
    readStored: async () => ({ token: 'stale-stored', expiresAt: now - 1 }),
    writeStored: async (entry) => {
      written = entry;
    },
    mint: async () => 'fresh',
    now
  });

  assert.equal(result.token, 'fresh');
  assert.equal(result.source, 'minted');
  assert.equal(written.token, 'fresh');
  assert.equal(written.expiresAt, now + APNS_TOKEN_TTL_MS);
});

test('the token is persisted before it is handed back', async () => {
  const now = 1_000_000;
  const order = [];

  await resolveAPNSToken({
    memory: undefined,
    readStored: async () => undefined,
    writeStored: async () => order.push('write'),
    mint: async () => {
      order.push('mint');
      return 'fresh';
    },
    now
  });

  assert.deepEqual(order, ['mint', 'write'], 'persist must happen before returning');
});

test('the refresh interval stays inside the APNs one-hour token lifetime', () => {
  assert.ok(APNS_TOKEN_TTL_MS < 60 * 60 * 1000, 'token would outlive APNs validity');
  assert.ok(
    APNS_TOKEN_TTL_MS > 20 * 60 * 1000,
    'refreshing faster than 20min trips APNs rate limits'
  );
});

test('isAPNSTokenUsable rejects missing and malformed entries', () => {
  const now = 1_000_000;
  assert.equal(isAPNSTokenUsable(undefined, now), false);
  assert.equal(isAPNSTokenUsable({ token: 'x' }, now), false);
  assert.equal(isAPNSTokenUsable({ token: 'x', expiresAt: now - 1 }, now), false);
  assert.equal(isAPNSTokenUsable({ token: 'x', expiresAt: now + 1 }, now), true);
});

test('provider-token backoff lasts at least 20 minutes and never regresses', () => {
  const now = 1_000_000;
  const minimum = now + APNS_PROVIDER_UPDATE_BACKOFF_MS;
  assert.equal(nextAPNSProviderBackoffUntil(undefined, now), minimum);
  assert.equal(nextAPNSProviderBackoffUntil(minimum - 1, now), minimum);
  assert.equal(nextAPNSProviderBackoffUntil(minimum + 60_000, now), minimum + 60_000);
});
