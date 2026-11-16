import { base64urlToBytes, bytesToBase64url, parseToken, verifyToken, ROLES } from './token.js';

export const MAX_ROTATION_OVERLAP_SECONDS = 24 * 60 * 60;
const DEVICE_ID = /^[A-Za-z0-9_-]{1,128}$/;
const KEY_ID = /^[A-Za-z0-9_-]{1,32}$/;

/** Canonical 256-bit credentials; reject weak text, padding and alternate encodings. */
export function isStrongRelayCredential(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(value)) return false;
  try {
    const bytes = base64urlToBytes(value);
    return bytes.length === 32 && bytesToBase64url(bytes) === value;
  } catch {
    return false;
  }
}

function validRoot(value) {
  return (
    value &&
    typeof value === 'object' &&
    typeof value.id === 'string' &&
    KEY_ID.test(value.id) &&
    isStrongRelayCredential(value.secret)
  );
}

/** A malformed explicit configuration never falls back to development access. */
export function resolveAuthMode(env, nowSeconds = Math.floor(Date.now() / 1000)) {
  try {
    if (typeof env?.RELAY_AUTH_KEYS !== 'string' || !env.RELAY_AUTH_KEYS.trim()) {
      if (
        env?.ENVIRONMENT === 'development' &&
        env?.RELAY_ALLOW_UNAUTHENTICATED === 'true' &&
        env?.RELAY_AUTH_KEYS === undefined
      ) {
        return { mode: 'open' };
      }
      return { mode: 'misconfigured' };
    }
    if (env.RELAY_AUTH_KEYS.length > 4096) return { mode: 'misconfigured' };
    const keys = JSON.parse(env.RELAY_AUTH_KEYS);
    if (!validRoot(keys.current)) return { mode: 'misconfigured' };
    const previous = keys.previous;
    if (
      previous !== undefined &&
      (!validRoot(previous) ||
        previous.id === keys.current.id ||
        !Number.isSafeInteger(previous.grace_started_at) ||
        !Number.isSafeInteger(previous.accept_until) ||
        previous.grace_started_at < 0 ||
        previous.grace_started_at > nowSeconds ||
        previous.accept_until <= previous.grace_started_at ||
        previous.accept_until - previous.grace_started_at > MAX_ROTATION_OVERLAP_SECONDS)
    )
      return { mode: 'misconfigured' };
    const revoked =
      env.RELAY_REVOKED_DEVICES === undefined ? [] : JSON.parse(env.RELAY_REVOKED_DEVICES);
    if (
      !Array.isArray(revoked) ||
      revoked.length > 256 ||
      revoked.some((id) => typeof id !== 'string' || !DEVICE_ID.test(id))
    ) {
      return { mode: 'misconfigured' };
    }
    return { mode: 'enforce', current: keys.current, previous, revoked: new Set(revoked) };
  } catch {
    return { mode: 'misconfigured' };
  }
}

/** Root material stays in the Worker/operator keyring. Each derived credential covers one device/role. */
export async function deriveRoleCredential(rootSecret, keyId, deviceId, role) {
  if (
    !isStrongRelayCredential(rootSecret) ||
    typeof keyId !== 'string' ||
    !KEY_ID.test(keyId) ||
    typeof deviceId !== 'string' ||
    !DEVICE_ID.test(deviceId) ||
    !ROLES.includes(role)
  ) {
    throw new Error('Invalid relay credential parameters');
  }
  const root = await crypto.subtle.importKey(
    'raw',
    base64urlToBytes(rootSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const derived = await crypto.subtle.sign(
    'HMAC',
    root,
    new TextEncoder().encode(`chau7-v3:${keyId}:${deviceId}:${role}`)
  );
  return bytesToBase64url(derived);
}

/** A pairing-window label: `p` + the unix second the window closes. */
const PAIR_LABEL = /^p(\d{1,12})$/;
/** The Mac shows a pairing QR for ten minutes; allow for its clock running ahead. */
export const MAX_PAIR_WINDOW_SECONDS = 20 * 60;
export const MAX_PHONES = 64;

/**
 * The credential the Mac mints for one phone, or for one pairing window. It is
 * keyed by the Mac role credential, which no phone holds, so one phone cannot
 * derive another's and a revoked phone cannot mint itself a new one.
 */
export async function derivePhoneCredential(macSecret, phoneId) {
  if (!isStrongRelayCredential(macSecret) || !KEY_ID.test(phoneId ?? '')) {
    throw new Error('Invalid phone credential parameters');
  }
  const key = await crypto.subtle.importKey(
    'raw',
    base64urlToBytes(macSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const derived = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`chau7-v4:phone:${phoneId}`)
  );
  return bytesToBase64url(derived);
}

/** Seconds a pairing-window label is still good for; 0 when closed or not a label. */
export function pairWindowRemaining(phoneId, nowSeconds) {
  const match = PAIR_LABEL.exec(phoneId ?? '');
  if (!match) return 0;
  const remaining = Number(match[1]) - nowSeconds;
  return remaining > 0 && remaining <= MAX_PAIR_WINDOW_SECONDS ? remaining : 0;
}

export function isPairLabel(phoneId) {
  return PAIR_LABEL.test(phoneId ?? '');
}

/**
 * The Mac's list of phones it trusts. `locked` turns on once a phone has been
 * removed from it; from then on the credential all phones share is refused,
 * because the removed phone still holds it.
 * @typedef {{ phones: string[], locked: boolean }} PhonePolicy
 */

/** @returns {PhonePolicy | null} null when the list is malformed. */
export function nextPhonePolicy(stored, phones) {
  if (
    !Array.isArray(phones) ||
    phones.length > MAX_PHONES ||
    phones.some((id) => typeof id !== 'string' || !KEY_ID.test(id) || isPairLabel(id))
  ) {
    return null;
  }
  const next = [...new Set(phones)];
  const removed = (stored?.phones ?? []).some((id) => !next.includes(id));
  return { phones: next, locked: Boolean(stored?.locked) || removed };
}

/**
 * Whether an iOS credential may use this Mac's namespace. `phoneId` is
 * undefined for the shared (v3) credential. Signature and pairing-window
 * expiry are checked before this, where the token is verified.
 */
export function isPhoneAdmitted(policy, phoneId) {
  if (phoneId === undefined) return !policy?.locked;
  if (isPairLabel(phoneId)) return true;
  return Boolean(policy?.phones.includes(phoneId));
}

export function isCredentialAdmissionAllowed(
  policy,
  deviceId,
  keyId,
  role,
  nowSeconds = Math.floor(Date.now() / 1000)
) {
  if (typeof deviceId !== 'string' || !DEVICE_ID.test(deviceId) || !ROLES.includes(role))
    return false;
  if (policy.mode === 'open') return keyId === 'development';
  if (policy.mode !== 'enforce' || policy.revoked.has(deviceId)) return false;
  return (
    keyId === policy.current.id ||
    (keyId === policy.previous?.id && nowSeconds < policy.previous.accept_until)
  );
}

/** @returns {Promise<{ok: true, nonce: string, expiresAt: number} | {ok: false, reason: string}>} */
export async function verifyCredentialToken(
  token,
  expected,
  env,
  nowSeconds = Math.floor(Date.now() / 1000)
) {
  const policy = resolveAuthMode(env, nowSeconds);
  if (policy.mode !== 'enforce') return { ok: false, reason: 'misconfigured' };
  const parsed = parseToken(token);
  if (
    !parsed?.keyId ||
    !isCredentialAdmissionAllowed(
      policy,
      expected.deviceId,
      parsed.keyId,
      expected.role,
      nowSeconds
    )
  ) {
    return { ok: false, reason: 'credential_denied' };
  }
  const root = parsed.keyId === policy.current.id ? policy.current : policy.previous;
  if (parsed.phoneId !== undefined) {
    if (expected.role !== 'ios') return { ok: false, reason: 'credential_denied' };
    if (isPairLabel(parsed.phoneId) && pairWindowRemaining(parsed.phoneId, nowSeconds) === 0) {
      return { ok: false, reason: 'pair_window_closed' };
    }
    const macSecret = await deriveRoleCredential(
      root.secret,
      parsed.keyId,
      expected.deviceId,
      'mac'
    );
    const secret = await derivePhoneCredential(macSecret, parsed.phoneId);
    return verifyToken(
      token,
      { ...expected, keyId: parsed.keyId, phoneId: parsed.phoneId, secret },
      nowSeconds
    );
  }
  const secret = await deriveRoleCredential(
    root.secret,
    parsed.keyId,
    expected.deviceId,
    expected.role
  );
  return verifyToken(token, { ...expected, keyId: parsed.keyId, secret }, nowSeconds);
}
