/** Placeholder values that are rejected at runtime to prevent misconfigured deployments. */
const RELAY_SECRET_PLACEHOLDERS = new Set(['CHANGE_ME_IN_PRODUCTION']);

export function isRelaySecretConfigured(secret) {
  if (typeof secret !== 'string') {
    return false;
  }

  const normalized = secret.trim();
  return normalized.length > 0 && !RELAY_SECRET_PLACEHOLDERS.has(normalized);
}
