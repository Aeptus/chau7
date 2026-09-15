/**
 * Owns the single APNs provider JWT shared by every paired-device SessionDO.
 * APNs rate-limits provider-token updates per signing key, not per device.
 */
import { nextAPNSProviderBackoffUntil, resolveAPNSToken } from './apns.js';

interface Env {
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
}

interface CachedAPNSToken {
  token: string;
  expiresAt: number;
}

const TOKEN_STORAGE_KEY = 'provider-token';
const BACKOFF_STORAGE_KEY = 'provider-token-backoff-until';

export class APNSTokenBrokerDO {
  private cachedToken?: CachedAPNSToken;
  private cachedSigningKey?: CryptoKey;

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env
  ) {}

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (request.method === 'POST' && path === '/token') {
      return this.handleTokenRequest();
    }
    if (request.method === 'POST' && path === '/provider-update-rate-limited') {
      return this.handleProviderUpdateRateLimit();
    }
    return new Response('Not Found', { status: 404 });
  }

  private async handleTokenRequest(): Promise<Response> {
    const { APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY } = this.env;
    if (!APNS_TEAM_ID || !APNS_KEY_ID || !APNS_PRIVATE_KEY) {
      return Response.json({ error: 'apns_not_configured' }, { status: 503 });
    }

    const now = Date.now();
    const backoffUntil = (await this.state.storage.get<number>(BACKOFF_STORAGE_KEY)) ?? 0;
    if (backoffUntil > now) {
      const retryAfterSeconds = Math.max(1, Math.ceil((backoffUntil - now) / 1000));
      return Response.json(
        { error: 'provider_token_backoff', retry_after_seconds: retryAfterSeconds },
        { status: 503, headers: { 'Retry-After': String(retryAfterSeconds) } }
      );
    }

    const { token, entry, source } = await resolveAPNSToken({
      memory: this.cachedToken,
      readStored: () => this.state.storage.get<CachedAPNSToken>(TOKEN_STORAGE_KEY),
      writeStored: (value: CachedAPNSToken) => this.state.storage.put(TOKEN_STORAGE_KEY, value),
      mint: () => this.createAPNSToken(APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY),
      now
    });
    this.cachedToken = entry;
    return Response.json({ token, source, expires_at: entry.expiresAt, key_id: APNS_KEY_ID });
  }

  private async handleProviderUpdateRateLimit(): Promise<Response> {
    const now = Date.now();
    const existing = (await this.state.storage.get<number>(BACKOFF_STORAGE_KEY)) ?? 0;
    const backoffUntil = nextAPNSProviderBackoffUntil(existing, now);
    await this.state.storage.put(BACKOFF_STORAGE_KEY, backoffUntil);
    console.warn(
      `APNs provider-token refresh backoff armed: until=${new Date(backoffUntil).toISOString()}`
    );
    return Response.json({ backoff_until: backoffUntil });
  }

  private async createAPNSToken(
    teamID: string,
    keyID: string,
    privateKey: string
  ): Promise<string> {
    const header = this.base64url(JSON.stringify({ alg: 'ES256', kid: keyID, typ: 'JWT' }));
    const claims = this.base64url(
      JSON.stringify({ iss: teamID, iat: Math.floor(Date.now() / 1000) })
    );
    const signingInput = `${header}.${claims}`;
    if (!this.cachedSigningKey) {
      this.cachedSigningKey = await crypto.subtle.importKey(
        'pkcs8',
        this.pemToArrayBuffer(privateKey),
        { name: 'ECDSA', namedCurve: 'P-256' },
        false,
        ['sign']
      );
    }
    const signature = await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      this.cachedSigningKey,
      new TextEncoder().encode(signingInput)
    );
    return `${signingInput}.${this.base64url(signature)}`;
  }

  private pemToArrayBuffer(pem: string): ArrayBuffer {
    const normalized = pem.replace(/\\n/g, '\n');
    const base64 = normalized
      .split('\n')
      .filter((line) => !line.trim().startsWith('-----'))
      .join('')
      .replace(/\s+/g, '');
    return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0)).buffer;
  }

  private base64url(value: string | ArrayBuffer): string {
    const bytes =
      typeof value === 'string' ? new TextEncoder().encode(value) : new Uint8Array(value);
    let binary = '';
    for (const byte of bytes) {
      binary += String.fromCharCode(byte);
    }
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
}
