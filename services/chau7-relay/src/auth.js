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
  const secret = await deriveRoleCredential(
    root.secret,
    parsed.keyId,
    expected.deviceId,
    expected.role
  );
  return verifyToken(token, { ...expected, keyId: parsed.keyId, secret }, nowSeconds);
}
