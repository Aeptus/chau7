/**
 * Relay token primitives. v3 binds a provisioned credential key ID; v2 is
 * retained only for legacy vectors and is rejected by deployed admission.
 *
 * Wire format:  `v3.{key_id}.{ts}.{nonce}.{scope}.{base64url_signature}`
 * Signed message: `v3:{key_id}:{deviceId}:{role}:{scope}:{ts}:{nonce}`
 *
 * The signed message binds the token to a single device, role, and scope, so a
 * token minted for one endpoint cannot be replayed against another. `nonce` is
 * 16 random bytes (base64url, unpadded) and is enforced single-use by the
 * Durable Object, defeating capture-and-replay within the validity window.
 *
 * Transport: tokens travel only in the `Authorization: Bearer` header, never in
 * the URL query string (query strings leak into logs/proxies/Referer).
 *
 * Pure module — no Worker globals beyond Web Crypto (`crypto.subtle`), `atob`,
 * and `btoa`, all of which exist in both Workers and Node >= 22, so this file is
 * unit-testable under `node --test`.
 */

export const TOKEN_VERSION = 'v2';

/** Roles a client may claim. */
export const ROLES = Object.freeze(['mac', 'ios']);

/** Endpoint scopes. A token is valid only for the scope it was signed for. */
export const SCOPES = Object.freeze(['connect', 'push', 'pending', 'issues']);

/** Tokens are valid for this many seconds after `iat`. */
export const TOKEN_TTL_SECONDS = 120;

/** Tolerance for clients whose clock runs ahead of the relay. */
export const TOKEN_FUTURE_SKEW_SECONDS = 30;

/** Hard ceilings so a malformed/oversized token is rejected before any crypto. */
const MAX_TOKEN_LENGTH = 1024;
const MAX_NONCE_LENGTH = 64;

const encoder = new TextEncoder();

/** Encode bytes (Uint8Array | ArrayBuffer) as unpadded base64url. */
export function bytesToBase64url(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Decode an unpadded base64url string to bytes. Throws on invalid input. */
export function base64urlToBytes(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error('invalid base64url');
  }
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((value.length + 3) % 4);
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

async function importHmacKey(secret, usage) {
  return crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    [usage]
  );
}

function buildMessage(deviceId, role, scope, ts, nonce, keyId) {
  const prefix = keyId === undefined ? TOKEN_VERSION : `v3:${keyId}`;
  return `${prefix}:${deviceId}:${role}:${scope}:${ts}:${nonce}`;
}

/**
 * Parse a token's structure without verifying its signature.
 * Returns `{ ts, nonce, scope, signature }` or `null` if malformed.
 * The `ts` is validated to be a pure non-negative integer string.
 */
export function parseToken(token) {
  if (typeof token !== 'string' || token.length === 0 || token.length > MAX_TOKEN_LENGTH) {
    return null;
  }
  const parts = token.split('.');
  const isCredentialToken = parts.length === 6 && parts[0] === 'v3';
  if (!isCredentialToken && (parts.length !== 5 || parts[0] !== TOKEN_VERSION)) return null;
  const keyId = isCredentialToken ? parts[1] : undefined;
  if (isCredentialToken && !/^[A-Za-z0-9_-]{1,32}$/.test(keyId)) return null;
  const [version, tsRaw, nonce, scope, signature] = isCredentialToken
    ? [parts[0], ...parts.slice(2)]
    : parts;
  if (!/^\d{1,15}$/.test(tsRaw)) {
    return null;
  }
  if (!nonce || nonce.length > MAX_NONCE_LENGTH || !/^[A-Za-z0-9_-]+$/.test(nonce)) {
    return null;
  }
  if (!SCOPES.includes(scope)) {
    return null;
  }
  if (!signature || !/^[A-Za-z0-9_-]+$/.test(signature)) {
    return null;
  }
  return { ts: Number(tsRaw), nonce, scope, signature, ...(keyId === undefined ? {} : { keyId }) };
}

/**
 * Verify a token against the expected (deviceId, role, scope).
 *
 * `nowSeconds` defaults to the current time; injectable for tests. Returns a
 * discriminated result so the caller can both authorize and (on success)
 * extract the nonce/expiry for single-use enforcement.
 *
 * @returns {Promise<{ok: true, nonce: string, expiresAt: number} | {ok: false, reason: string}>}
 */
export async function verifyToken(
  token,
  { deviceId, role, scope, secret, keyId },
  nowSeconds = Date.now() / 1000
) {
  if (!ROLES.includes(role) || !SCOPES.includes(scope)) {
    return { ok: false, reason: 'bad_params' };
  }
  const parsed = parseToken(token);
  if (!parsed) {
    return { ok: false, reason: 'malformed' };
  }
  if (parsed.keyId !== keyId) return { ok: false, reason: 'key_mismatch' };
  if (parsed.scope !== scope) {
    return { ok: false, reason: 'scope_mismatch' };
  }
  if (parsed.ts > nowSeconds + TOKEN_FUTURE_SKEW_SECONDS) {
    return { ok: false, reason: 'future' };
  }
  if (parsed.ts < nowSeconds - TOKEN_TTL_SECONDS) {
    return { ok: false, reason: 'expired' };
  }

  let signatureBytes;
  try {
    signatureBytes = base64urlToBytes(parsed.signature);
  } catch {
    return { ok: false, reason: 'malformed' };
  }

  const key = await importHmacKey(secret, 'verify');
  const message = buildMessage(deviceId, role, scope, parsed.ts, parsed.nonce, keyId);
  // crypto.subtle.verify is constant-time over the raw HMAC bytes.
  const valid = await crypto.subtle.verify('HMAC', key, signatureBytes, encoder.encode(message));
  if (!valid) {
    return { ok: false, reason: 'bad_signature' };
  }
  return {
    ok: true,
    nonce: parsed.nonce,
    expiresAt: (parsed.ts + TOKEN_TTL_SECONDS) * 1000
  };
}

/**
 * Mint a token. The relay never calls this in production (clients mint), but it
 * keeps the wire format in one place and lets tests exercise verify() honestly.
 */
export async function mintToken(
  { deviceId, role, scope, secret, keyId },
  nowSeconds = Date.now() / 1000
) {
  const ts = Math.floor(nowSeconds);
  const nonceBytes = crypto.getRandomValues(new Uint8Array(16));
  const nonce = bytesToBase64url(nonceBytes);
  const key = await importHmacKey(secret, 'sign');
  const message = buildMessage(deviceId, role, scope, ts, nonce, keyId);
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
  const prefix = keyId === undefined ? TOKEN_VERSION : `v3.${keyId}`;
  return `${prefix}.${ts}.${nonce}.${scope}.${bytesToBase64url(signature)}`;
}
