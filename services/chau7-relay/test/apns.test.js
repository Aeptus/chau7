import assert from 'node:assert/strict';
import test from 'node:test';
import {
  shouldRemoveRegistration,
  parseApnsReason,
  buildApnsPayload,
  REMOVABLE_REASONS
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
