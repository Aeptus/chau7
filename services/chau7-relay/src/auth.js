/** Placeholder values that are rejected at runtime to prevent misconfigured deployments. */
const RELAY_SECRET_PLACEHOLDERS = new Set(['CHANGE_ME_IN_PRODUCTION']);

export function isRelaySecretConfigured(secret) {
  if (typeof secret !== 'string') {
    return false;
  }

  const normalized = secret.trim();
  return normalized.length > 0 && !RELAY_SECRET_PLACEHOLDERS.has(normalized);
}

/**
 * Resolve the relay's authentication posture. Fails CLOSED by default:
 *
 *   - 'enforce'      RELAY_SECRET is configured → every request must carry a
 *                    valid token.
 *   - 'open'         RELAY_SECRET is absent AND `RELAY_ALLOW_UNAUTHENTICATED`
 *                    is exactly "true" → unauthenticated access is permitted.
 *                    This is an explicit, opt-in rollout escape hatch and the
 *                    caller is expected to log a warning on use.
 *   - 'misconfigured' RELAY_SECRET is absent and open mode was not requested →
 *                    reject all authenticated routes with 503. A forgotten or
 *                    placeholder secret therefore denies access rather than
 *                    silently running wide open.
 *
 * @returns {{mode: 'enforce'|'open'|'misconfigured', secret: string|undefined}}
 */
export function resolveAuthMode(env) {
  const secret = env?.RELAY_SECRET;
  if (isRelaySecretConfigured(secret)) {
    return { mode: 'enforce', secret: secret.trim() };
  }
  if (env?.RELAY_ALLOW_UNAUTHENTICATED === 'true') {
    return { mode: 'open', secret: undefined };
  }
  return { mode: 'misconfigured', secret: undefined };
}
