import test from 'node:test';
import assert from 'node:assert/strict';
import { bytesToBase64url, mintToken, parseToken, verifyToken } from '../src/token.js';
import {
  derivePhoneCredential,
  deriveRoleCredential,
  isPhoneAdmitted,
  nextPhonePolicy,
  pairWindowRemaining,
  verifyCredentialToken
} from '../src/auth.js';
import { ReceiveWindow, relayAckTotal, RELAY_ACK_FRAME_TYPE } from '../src/backpressure.js';

const now = 1_000_000;
const root = bytesToBase64url(Uint8Array.from({ length: 32 }, (_, i) => i + 1));
const env = { RELAY_AUTH_KEYS: JSON.stringify({ current: { id: 'current', secret: root } }) };
const expected = { deviceId: 'device-A', role: 'ios', scope: 'connect' };

async function phoneToken(phoneId, { deviceId = 'device-A', role = 'ios', secret } = {}) {
  const macSecret = await deriveRoleCredential(root, 'current', deviceId, 'mac');
  secret ??= await derivePhoneCredential(macSecret, phoneId);
  return mintToken({ deviceId, role, keyId: 'current', phoneId, secret, scope: 'connect' }, now);
}

test('a per-phone token verifies and carries its phone id', async () => {
  const token = await phoneToken('dPhoneOne');
  assert.equal(parseToken(token).phoneId, 'dPhoneOne');
  assert.equal((await verifyCredentialToken(token, expected, env, now)).ok, true);
});

test("one phone's credential does not sign for another phone or another Mac", async () => {
  const macSecret = await deriveRoleCredential(root, 'current', 'device-A', 'mac');
  const mine = await derivePhoneCredential(macSecret, 'dPhoneOne');
  const forged = await phoneToken('dPhoneTwo', { secret: mine });
  assert.equal((await verifyCredentialToken(forged, expected, env, now)).ok, false);
  const elsewhere = await phoneToken('dPhoneOne', { deviceId: 'device-B', secret: mine });
  const result = await verifyCredentialToken(
    elsewhere,
    { ...expected, deviceId: 'device-B' },
    env,
    now
  );
  assert.equal(result.ok, false);
});

test('the shared iOS credential cannot mint a per-phone token', async () => {
  const shared = await deriveRoleCredential(root, 'current', 'device-A', 'ios');
  const forged = await phoneToken('dPhoneOne', { secret: shared });
  assert.equal((await verifyCredentialToken(forged, expected, env, now)).ok, false);
});

test('a per-phone token is refused for the Mac role', async () => {
  const token = await phoneToken('dPhoneOne', { role: 'mac' });
  const result = await verifyCredentialToken(token, { ...expected, role: 'mac' }, env, now);
  assert.deepEqual(result, { ok: false, reason: 'credential_denied' });
});

test('a pairing-window credential stops working when the window closes', async () => {
  const open = await phoneToken(`p${now + 600}`);
  assert.equal((await verifyCredentialToken(open, expected, env, now)).ok, true);
  const closed = await phoneToken(`p${now - 1}`);
  assert.deepEqual(await verifyCredentialToken(closed, expected, env, now), {
    ok: false,
    reason: 'pair_window_closed'
  });
  // A window far in the future is not a window; it is a permanent credential.
  assert.equal(pairWindowRemaining(`p${now + 86_400}`, now), 0);
});

test('the shared credential is refused once a phone has been removed', () => {
  assert.equal(isPhoneAdmitted(undefined, undefined), true);
  const first = nextPhonePolicy(undefined, ['dA', 'dB']);
  assert.deepEqual(first, { phones: ['dA', 'dB'], locked: false });
  assert.equal(isPhoneAdmitted(first, undefined), true);
  assert.equal(isPhoneAdmitted(first, 'dC'), false);

  const added = nextPhonePolicy(first, ['dA', 'dB', 'dC']);
  assert.equal(added.locked, false);

  const removed = nextPhonePolicy(added, ['dA', 'dC']);
  assert.equal(removed.locked, true);
  assert.equal(isPhoneAdmitted(removed, undefined), false);
  assert.equal(isPhoneAdmitted(removed, 'dB'), false);
  assert.equal(isPhoneAdmitted(removed, 'dA'), true);
  assert.equal(isPhoneAdmitted(removed, `p${now + 60}`), true);

  // Adding the phone back does not reopen the shared credential.
  assert.equal(nextPhonePolicy(removed, ['dA', 'dB', 'dC']).locked, true);
});

test('a malformed phone list is rejected', () => {
  for (const phones of [undefined, 'dA', [1], ['bad.id'], [`p${now}`], Array(65).fill('dA')]) {
    assert.equal(nextPhonePolicy(undefined, phones), null);
  }
});

function ackFrame(total, type = RELAY_ACK_FRAME_TYPE, extra = 0) {
  const buffer = new ArrayBuffer(28 + extra);
  const view = new DataView(buffer);
  view.setUint8(1, type);
  view.setBigUint64(20, BigInt(total), true);
  return buffer;
}

test('only a well-formed acknowledgement frame is read as one', () => {
  assert.equal(relayAckTotal(ackFrame(70_000)), 70_000);
  assert.equal(relayAckTotal(ackFrame(70_000, 0x20)), null);
  assert.equal(relayAckTotal(ackFrame(70_000, RELAY_ACK_FRAME_TYPE, 1)), null);
  assert.equal(relayAckTotal('ack'), null);
});

test('a phone that never acknowledges is never counted as behind', () => {
  const window = new ReceiveWindow();
  window.recordSend(50_000_000);
  assert.equal(window.outstanding, 0);
});

test('outstanding bytes are what was sent since the last acknowledgement', () => {
  const window = new ReceiveWindow();
  window.recordSend(1000);
  window.recordAck(1000);
  assert.equal(window.outstanding, 0);
  window.recordSend(5000);
  assert.equal(window.outstanding, 5000);
  window.recordAck(4000);
  assert.equal(window.outstanding, 2000);
});

test('the window re-bases on a total it cannot match after waking', () => {
  // The relay woke with fresh counters; the phone's total covers earlier bytes.
  const window = new ReceiveWindow();
  window.recordSend(300);
  window.recordAck(9_000_000);
  assert.equal(window.outstanding, 0);
  window.recordSend(700);
  window.recordAck(9_000_200);
  assert.equal(window.outstanding, 500);
  // A total that goes backwards (the phone reconnected) re-bases too.
  window.recordAck(10);
  assert.equal(window.outstanding, 0);
});

// The Mac helper (relay_phones_test.go) asserts the same derivation and the
// iPhone app (RelayTokenTests) signs the same token: all three must agree.
test('the phone credential and its token match the shared vectors', async () => {
  const macCredential = bytesToBase64url(new Uint8Array(32).fill(0x2a));
  const expected = '8Yon2Jg2hJkLfWpBFnytJ0CCn9V14ZTubWeV265o2Hw';
  assert.equal(await derivePhoneCredential(macCredential, 'dPhoneOne'), expected);

  const standIn = bytesToBase64url(new Uint8Array(32).fill(2));
  const token =
    'v4.current.dPhoneOne.1000000.bm9uY2U.connect.PLf8PmGtfT8Qy01hk7xIoqXTz72NKSF9qsdWXe3H1YU';
  const result = await verifyToken(
    token,
    {
      deviceId: 'device-123',
      role: 'ios',
      scope: 'connect',
      keyId: 'current',
      phoneId: 'dPhoneOne',
      secret: standIn
    },
    now
  );
  assert.equal(result.ok, true);
});
