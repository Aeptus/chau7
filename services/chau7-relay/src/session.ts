/**
 * SessionDO — Durable Object managing a single paired device session.
 *
 * Responsibilities:
 *   - WebSocket relay: bridges macOS <-> iOS connections (one socket per role),
 *     using the Hibernatable WebSockets API so an idle session does not pin the
 *     DO in memory or accrue duration billing, and survives DO eviction.
 *   - Push registration: stores APNs tokens per paired iOS device.
 *   - Push notifications: sends APNs alerts when iOS is offline.
 *   - Pending state: stores the approvals/prompts snapshot for offline iOS.
 *
 * The Worker performs token authentication before any request reaches this DO;
 * the DO additionally enforces single-use nonces (replay defense), per-route
 * rate limits, and strict payload validation.
 */
import {
  readJsonBody,
  sanitizePendingState,
  validatePushNotify,
  validatePushRegister
} from './validation.js';
import { buildApnsPayload, parseApnsReason, shouldRemoveRegistration } from './apns.js';
import { RateLimiter } from './ratelimit.js';
import { parseToken, TOKEN_TTL_SECONDS } from './token.js';

interface PushRegistration {
  pairedDeviceId: string;
  deviceName?: string;
  pushToken: string;
  pushTopic: string;
  pushEnvironment: 'development' | 'production';
  notificationsAuthorized: boolean;
  updatedAt: string;
}

interface PushNotifyPayload {
  kind: string;
  title: string;
  body: string;
  request_id?: string;
  prompt_id?: string;
  open_approvals?: boolean;
}

interface PendingStatePayload {
  approvals: unknown[];
  interactive_prompts: unknown[];
  updated_at?: string;
}

interface Env {
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
}

const REGISTRATIONS_KEY = 'push_registrations';
const PENDING_STATE_KEY = 'pending_state';
const SEEN_NONCES_KEY = 'seen_nonces';

/** Reject relayed frames larger than this (matches the platform WS message limit). */
const MAX_FRAME_BYTES = 1024 * 1024;
/** Drop frames to a peer whose send buffer already exceeds this (slow receiver). */
const BACKPRESSURE_SOFT_BYTES = 4 * 1024 * 1024;
/** Close a peer whose send buffer is hopelessly backed up. */
const BACKPRESSURE_HARD_BYTES = 16 * 1024 * 1024;
/** Upper bound on retained nonces; bounded anyway by TTL + rate limits. */
const MAX_SEEN_NONCES = 2000;

type Role = 'mac' | 'ios';

export class SessionDO {
  private readonly state: DurableObjectState;
  private readonly env: Env;
  private readonly rateLimiter = new RateLimiter();
  /// Cached APNs provider JWT — identical across all registrations in this DO,
  /// valid up to 1h; refreshed at 50min to avoid TooManyProviderTokenUpdates.
  private cachedAPNSToken?: { token: string; expiresAt: number };
  /// Cached signing key so the P-256 import happens once per JWT refresh, not per notify.
  private cachedSigningKey?: CryptoKey;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);

    const route = parts[0];
    if (!this.rateLimiter.allow(route === 'push' ? 'push' : route, Date.now())) {
      return new Response('Too Many Requests', { status: 429, headers: { 'Retry-After': '1' } });
    }

    if (route === 'connect') {
      return this.handleConnect(request, url);
    }
    if (route === 'push' && parts.length === 3) {
      if (request.method !== 'POST') {
        return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'POST' } });
      }
      const operation = parts[1];
      if (operation === 'register') {
        return this.handlePushRegister(request);
      }
      if (operation === 'notify') {
        return this.handlePushNotify(request);
      }
    }
    if (route === 'pending' && parts.length === 2) {
      if (request.method === 'GET') {
        return this.handlePendingState();
      }
      if (request.method === 'POST') {
        return this.handlePendingSync(request);
      }
      return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'GET, POST' } });
    }
    return new Response('Not Found', { status: 404 });
  }

  // --- WebSocket relay (Hibernatable WebSockets API) ------------------------

  private async handleConnect(request: Request, url: URL): Promise<Response> {
    if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('Expected WebSocket', { status: 426 });
    }
    const role = url.searchParams.get('role');
    if (role !== 'mac' && role !== 'ios') {
      return new Response('Missing role', { status: 400 });
    }
    if (!(await this.consumeNonce(request))) {
      return new Response('Token already used', { status: 409 });
    }

    // Replace any existing socket for this role.
    for (const existing of this.state.getWebSockets(role)) {
      try {
        existing.close(1000, 'Replaced by new connection');
      } catch {
        // Ignore close errors.
      }
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    // Tag with the role so the message handler can locate the peer after the DO
    // hibernates and is re-instantiated with no in-memory socket references.
    this.state.acceptWebSocket(server, [role]);

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: ArrayBuffer | string): Promise<void> {
    const tags = this.state.getTags(ws);
    const role: Role | undefined = tags.includes('mac')
      ? 'mac'
      : tags.includes('ios')
        ? 'ios'
        : undefined;
    if (!role) {
      return;
    }

    const size = typeof message === 'string' ? message.length : message.byteLength;
    if (size > MAX_FRAME_BYTES) {
      try {
        ws.close(1009, 'Frame too large');
      } catch {
        // Ignore close errors.
      }
      return;
    }

    const peerRole: Role = role === 'mac' ? 'ios' : 'mac';
    for (const peer of this.state.getWebSockets(peerRole)) {
      const buffered = (peer as { bufferedAmount?: number }).bufferedAmount ?? 0;
      if (buffered > BACKPRESSURE_HARD_BYTES) {
        // Receiver is hopelessly behind; shed it rather than grow memory.
        try {
          peer.close(1013, 'Receiver overloaded');
        } catch {
          // Ignore close errors.
        }
        continue;
      }
      if (buffered > BACKPRESSURE_SOFT_BYTES) {
        // Drop this frame; the encrypted transport above the relay recovers.
        continue;
      }
      try {
        peer.send(message);
      } catch {
        // Ignore send errors; the close/error handler will clean up.
      }
    }
  }

  async webSocketClose(
    ws: WebSocket,
    code: number,
    _reason: string,
    _wasClean: boolean
  ): Promise<void> {
    // Hibernatable sockets are removed from getWebSockets() automatically once
    // closed; explicitly closing the server side completes the handshake.
    try {
      ws.close(code <= 1000 || code >= 4000 ? code : 1000, 'closing');
    } catch {
      // Already closed.
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    try {
      ws.close(1011, 'WebSocket error');
    } catch {
      // Ignore close errors.
    }
  }

  // --- Replay defense -------------------------------------------------------

  /**
   * Enforce single-use of a token's nonce. The Worker has already verified the
   * token's signature/scope/expiry; here we only guarantee it is not reused.
   * Returns false if the nonce was already seen (replay). When no token is
   * present (open/unauthenticated mode), there is nothing to enforce.
   */
  private async consumeNonce(request: Request): Promise<boolean> {
    const header = request.headers.get('Authorization') ?? '';
    if (!header.startsWith('Bearer ')) {
      return true;
    }
    const parsed = parseToken(header.slice('Bearer '.length).trim());
    if (!parsed) {
      return true;
    }
    const now = Date.now();
    const expiresAt = (parsed.ts + TOKEN_TTL_SECONDS) * 1000;
    const seen = (await this.state.storage.get<Record<string, number>>(SEEN_NONCES_KEY)) ?? {};

    if (seen[parsed.nonce] && seen[parsed.nonce] > now) {
      return false;
    }

    // Prune expired entries, then bound the map size defensively.
    for (const [nonce, exp] of Object.entries(seen)) {
      if (exp <= now) {
        delete seen[nonce];
      }
    }
    seen[parsed.nonce] = expiresAt;
    const keys = Object.keys(seen);
    if (keys.length > MAX_SEEN_NONCES) {
      keys
        .sort((a, b) => seen[a] - seen[b])
        .slice(0, keys.length - MAX_SEEN_NONCES)
        .forEach((nonce) => delete seen[nonce]);
    }
    await this.state.storage.put(SEEN_NONCES_KEY, seen);
    return true;
  }

  // --- Push registration ----------------------------------------------------

  private async handlePushRegister(request: Request): Promise<Response> {
    if (!(await this.consumeNonce(request))) {
      return new Response('Token already used', { status: 409 });
    }
    const parsed = await readJsonBody(request);
    if (!parsed.ok) {
      return new Response(parsed.message, { status: parsed.status });
    }
    const validation = validatePushRegister(parsed.value);
    if (!validation.ok) {
      return new Response(validation.message, { status: 400 });
    }
    const payload = validation.value;

    const registrations = await this.loadRegistrations();
    if (
      !payload.notifications_authorized ||
      !payload.push_token ||
      !payload.push_topic ||
      !payload.push_environment
    ) {
      delete registrations[payload.paired_device_id];
      await this.saveRegistrations(registrations);
      return new Response(null, { status: 204 });
    }

    registrations[payload.paired_device_id] = {
      pairedDeviceId: payload.paired_device_id,
      deviceName: payload.device_name,
      pushToken: payload.push_token,
      pushTopic: payload.push_topic,
      pushEnvironment: payload.push_environment,
      notificationsAuthorized: true,
      updatedAt: new Date().toISOString()
    };
    await this.saveRegistrations(registrations);
    return new Response(null, { status: 204 });
  }

  private async handlePushNotify(request: Request): Promise<Response> {
    if (!(await this.consumeNonce(request))) {
      return new Response('Token already used', { status: 409 });
    }
    const parsed = await readJsonBody(request);
    if (!parsed.ok) {
      return new Response(parsed.message, { status: parsed.status });
    }
    const validation = validatePushNotify(parsed.value);
    if (!validation.ok) {
      return new Response(validation.message, { status: 400 });
    }
    const payload = validation.value as PushNotifyPayload;

    const registrations = Object.values(await this.loadRegistrations()).filter(
      (registration) =>
        registration.notificationsAuthorized && registration.pushToken && registration.pushTopic
    );
    if (registrations.length === 0) {
      return new Response(null, { status: 204 });
    }

    // Send concurrently, but collect dead registrations and remove them in a
    // single read-modify-write afterwards to avoid lost-update races.
    const outcomes = await Promise.all(
      registrations.map(async (registration) => {
        const { status, reason } = await this.sendAPNSNotification(registration, payload);
        return shouldRemoveRegistration(status, reason) ? registration.pairedDeviceId : null;
      })
    );
    const dead = outcomes.filter((id): id is string => id !== null);
    if (dead.length > 0) {
      const next = await this.loadRegistrations();
      for (const id of dead) {
        delete next[id];
      }
      await this.saveRegistrations(next);
    }

    return new Response(null, { status: 204 });
  }

  private async loadRegistrations(): Promise<Record<string, PushRegistration>> {
    return (
      (await this.state.storage.get<Record<string, PushRegistration>>(REGISTRATIONS_KEY)) ?? {}
    );
  }

  private async saveRegistrations(registrations: Record<string, PushRegistration>): Promise<void> {
    await this.state.storage.put(REGISTRATIONS_KEY, registrations);
  }

  // --- Pending state --------------------------------------------------------

  private async loadPendingState(): Promise<PendingStatePayload> {
    return (
      (await this.state.storage.get<PendingStatePayload>(PENDING_STATE_KEY)) ?? {
        approvals: [],
        interactive_prompts: [],
        updated_at: new Date(0).toISOString()
      }
    );
  }

  private async handlePendingState(): Promise<Response> {
    const state = await this.loadPendingState();
    return Response.json(state);
  }

  private async handlePendingSync(request: Request): Promise<Response> {
    if (!(await this.consumeNonce(request))) {
      return new Response('Token already used', { status: 409 });
    }
    const parsed = await readJsonBody(request);
    if (!parsed.ok) {
      return new Response(parsed.message, { status: parsed.status });
    }
    const sanitized = sanitizePendingState(parsed.value);
    const nextState: PendingStatePayload = {
      ...sanitized,
      updated_at: new Date().toISOString()
    };
    await this.state.storage.put(PENDING_STATE_KEY, nextState);
    return Response.json(nextState);
  }

  // --- APNs -----------------------------------------------------------------

  private async sendAPNSNotification(
    registration: PushRegistration,
    payload: PushNotifyPayload
  ): Promise<{ status: number; reason?: string }> {
    const { APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY } = this.env;
    if (!APNS_TEAM_ID || !APNS_KEY_ID || !APNS_PRIVATE_KEY) {
      return { status: 204 };
    }

    const host =
      registration.pushEnvironment === 'production'
        ? 'https://api.push.apple.com'
        : 'https://api.sandbox.push.apple.com';
    const authToken = await this.getAPNSToken(APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY);
    const body = buildApnsPayload(payload);

    const response = await fetch(`${host}/3/device/${registration.pushToken}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${authToken}`,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-topic': registration.pushTopic,
        'content-type': 'application/json'
      },
      body: JSON.stringify(body)
    });

    let reason: string | undefined;
    if (response.status >= 400) {
      let text = '';
      try {
        text = await response.text();
      } catch {
        // APNs body unavailable; status alone is still logged below.
      }
      reason = parseApnsReason(text);
      console.warn(
        `APNs push failed: status=${response.status} device=${registration.pairedDeviceId} reason=${reason ?? text}`
      );
    }
    return { status: response.status, reason };
  }

  /// Returns a cached APNs provider JWT, minting a fresh one only when the
  /// cache is empty or near expiry. The signing inputs (team/key) are identical
  /// for every registration in this DO, so this collapses the per-registration,
  /// per-notify ECDSA signing into one signature per ~50 minutes.
  private async getAPNSToken(teamID: string, keyID: string, privateKey: string): Promise<string> {
    const now = Date.now();
    if (this.cachedAPNSToken && this.cachedAPNSToken.expiresAt > now) {
      return this.cachedAPNSToken.token;
    }
    const token = await this.createAPNSToken(teamID, keyID, privateKey);
    this.cachedAPNSToken = { token, expiresAt: now + 50 * 60 * 1000 };
    return token;
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
      .replace(/-----BEGIN PRIVATE KEY-----/g, '')
      .replace(/-----END PRIVATE KEY-----/g, '')
      .replace(/\s+/g, '');
    const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
    return bytes.buffer;
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
